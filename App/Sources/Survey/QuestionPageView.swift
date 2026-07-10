import DispatchKit
import SwiftData
import SwiftUI

/// A plain (non-`@Observable`) reference box that debounced text fields
/// register a synchronous flush closure into, keyed by field identifier.
/// Deliberately not observable: registering/deregistering must never
/// invalidate the survey's view graph the way writing an answer would.
///
/// Callers that are about to navigate or save call `flushAll()` first,
/// which synchronously pushes any pending local keystroke buffer into the
/// survey model — so a keystroke immediately followed by DONE or a page
/// swipe is never lost, even though propagation is otherwise debounced.
@MainActor
final class PendingFlushRegistry {
    private var flushers: [String: () -> Void] = [:]

    func register(_ identifier: String, flush: @escaping () -> Void) {
        flushers[identifier] = flush
    }

    func unregister(_ identifier: String) {
        flushers.removeValue(forKey: identifier)
    }

    func flushAll() {
        for flush in flushers.values { flush() }
    }
}

struct QuestionPageView: View {
    let page: SurveyPage
    let value: AnswerValue
    let onAnswer: (AnswerValue) -> Void
    let flushRegistry: PendingFlushRegistry
    /// Survey-wide shared focus, keyed by page id (see `SurveyFlowView.
    /// focusedPage`). Each keyboard-driven input binds itself to its own
    /// page id so the parent can hand the keyboard from page to page
    /// without a dismiss/re-present bounce.
    let focus: SwiftUI.FocusState<String?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(page.question.prompt.uppercased())
                .font(.subheadline.weight(.semibold))
                .kerning(1.2)
                .padding(.horizontal)
                .padding(.bottom, 8)
            Divider()
            answerBody
            Spacer()
        }
    }

    @ViewBuilder
    private var answerBody: some View {
        switch page.question.type {
        case .yesNo, .multipleChoice:
            ChoiceListView(choices: page.choices,
                           multiSelect: page.question.type == .multipleChoice && page.allowsMultipleSelection,
                           selected: selectedOptions,
                           onSelect: { onAnswer(.options($0)) })
        case .tokens, .people:
            TokenEntryView(placeholder: page.placeholder ?? "Add…",
                           tokens: currentTokens,
                           isPeople: page.question.type == .people,
                           identifier: "\(page.id)-token-field",
                           onChange: { onAnswer(.tokens($0)) },
                           flushRegistry: flushRegistry,
                           focus: focus,
                           focusID: page.id)
        case .number:
            // Input styles (plan 21): every control writes the same
            // numericResponse string through `onAnswer` that the text field
            // produces. Non-text styles have no keyboard, so they register
            // nothing with the flush registry — values commit on interaction.
            switch page.inputStyle {
            case .textField:
                LocalTextEditorField(
                    initialText: { if case .number(let number) = value { number } else { "" } }(),
                    onChange: { onAnswer($0.isEmpty ? .skipped : .number($0)) },
                    placeholder: page.placeholder ?? "0",
                    identifier: "\(page.id)-number-field",
                    accessibilityIdentifier: "number-field",
                    style: .field(keyboard: .decimalPad),
                    flushRegistry: flushRegistry,
                    focus: focus,
                    focusID: page.id)
            case .slider:
                SliderInput(value: numberBinding, config: page.inputConfig)
            case .stepper:
                StepperInput(value: numberBinding, config: page.inputConfig)
            case .dial:
                DialInput(value: numberBinding, config: page.inputConfig)
            case .tapCounter:
                TapCounterInput(value: numberBinding, config: page.inputConfig)
            case .scale:
                ScaleInput(value: numberBinding, config: page.inputConfig)
            }
        case .note:
            LocalTextEditorField(
                initialText: { if case .note(let note) = value { note } else { "" } }(),
                onChange: { onAnswer($0.isEmpty ? .skipped : .note($0)) },
                placeholder: nil,
                identifier: "\(page.id)-note-editor",
                accessibilityIdentifier: "note-editor",
                style: .editor,
                flushRegistry: flushRegistry,
                focus: focus,
                focusID: page.id)
        case .location:
            LocalTextEditorField(
                initialText: { if case .location(let text) = value { text } else { "" } }(),
                onChange: { onAnswer($0.isEmpty ? .skipped : .location(text: $0)) },
                placeholder: page.placeholder ?? "Where are you?",
                identifier: "\(page.id)-location-field",
                accessibilityIdentifier: "location-field",
                style: .field(keyboard: .default),
                flushRegistry: flushRegistry,
                focus: focus,
                focusID: page.id)
        case .time:
            // Wheel time-of-day input (plan 28). No keyboard, so no flush
            // registration — the answer commits on interaction (Now, the wheel,
            // or the Yesterday chip), matching the non-text number controls.
            TimeInput(
                value: { if case .time(let time) = value { time } else { nil } }(),
                onAnswer: { onAnswer(.time($0)) })
        }
    }

    /// The numericResponse string binding the number input controls share
    /// with the text field: empty = untouched/skipped, anything else is the
    /// formatted number the control wrote on interaction.
    private var numberBinding: Binding<String> {
        Binding(
            get: { if case .number(let number) = value { number } else { "" } },
            set: { onAnswer($0.isEmpty ? .skipped : .number($0)) })
    }

    private var selectedOptions: [String] {
        if case .options(let options) = value { return options }
        return []
    }

    private var currentTokens: [String] {
        if case .tokens(let tokens) = value { return tokens }
        return []
    }
}

/// A text input whose live keystrokes are held in local `@State`, seeded once
/// from the survey's answer value and pushed back out via a debounced call
/// to `onChange`.
///
/// This exists to fix a keyboard-freeze bug: previously each field's
/// `Binding` read/wrote directly through the app-wide `@Observable`
/// `SurveyViewModel`. Because that view model tracks all answers as a single
/// dictionary property, every keystroke invalidated the observable graph,
/// which caused the parent `SurveyFlowView` (and its `TabView`/`ForEach` over
/// *all* survey pages) to re-evaluate its body on every keystroke — freezing
/// the keyboard and even dropping/garbling characters under load. Keeping
/// the live text local means typing only touches this leaf view's state.
///
/// A follow-up fix found that even with local state, calling `onChange`
/// (and therefore `survey.answer(...)`) on every single keystroke still
/// invalidated the observable graph and rebuilt the whole `TabView` on
/// every character — just without the character-dropping. This field now
/// debounces that propagation to the model (~300ms idle) and registers a
/// synchronous flush closure with `flushRegistry` so an ancestor about to
/// navigate or save can force any pending buffer out immediately — a
/// keystroke followed immediately by DONE/swipe never loses text. It also
/// flushes on its own disappearance as a second safety net.
private struct LocalTextEditorField: View {
    enum Style {
        case field(keyboard: UIKeyboardType)
        case editor
    }

    let initialText: String
    let onChange: (String) -> Void
    let placeholder: String?
    /// Unique per-field registry key (page id + field kind). Must be
    /// distinct across pages so registrations from different pages/fields
    /// never collide or clobber each other in the shared registry.
    let identifier: String
    let accessibilityIdentifier: String
    let style: Style
    let flushRegistry: PendingFlushRegistry
    /// Survey-wide shared focus (keyed by page id) + this field's key.
    /// Bound so the parent can focus this field on page arrival and hand
    /// the keyboard over from the previous page without a bounce.
    let focus: SwiftUI.FocusState<String?>.Binding
    let focusID: String

    static let debounceInterval: Duration = .milliseconds(300)

    @State private var text: String = ""
    @State private var hasSeeded = false
    @State private var lastFlushedText: String = ""
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch style {
            case .field(let keyboard):
                TextField(placeholder ?? "", text: $text)
                    .keyboardType(keyboard)
                    .font(.title2)
                    .padding()
            case .editor:
                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .padding(.horizontal)
                    .scrollContentBackground(.hidden)
            }
        }
        .focused(focus, equals: focusID)
        .accessibilityIdentifier(accessibilityIdentifier)
        .onAppear {
            flushRegistry.register(identifier, flush: flush)
            guard !hasSeeded else { return }
            hasSeeded = true
            text = initialText
            lastFlushedText = initialText
        }
        .onChange(of: text) { _, newValue in
            scheduleDebouncedFlush(newValue)
        }
        .onDisappear {
            flush()
            flushRegistry.unregister(identifier)
        }
    }

    /// Cancels any in-flight debounce and schedules a new one. Keystrokes
    /// only ever touch local `@State` here — the observable survey model
    /// isn't written to until the debounce fires or a flush is forced.
    private func scheduleDebouncedFlush(_ newValue: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    /// Pushes the current local text to the model immediately, if it
    /// differs from what was last pushed. Idempotent and safe to call from
    /// multiple triggers (debounce fire, disappear, forced flush via the
    /// registry).
    private func flush() {
        debounceTask?.cancel()
        debounceTask = nil
        guard text != lastFlushedText else { return }
        lastFlushedText = text
        onChange(text)
    }
}

struct ChoiceListView: View {
    let choices: [String]
    let multiSelect: Bool
    let selected: [String]
    let onSelect: ([String]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(choices, id: \.self) { choice in
                Button {
                    toggle(choice)
                } label: {
                    HStack {
                        Text(choice).font(.title3)
                        Spacer()
                        if selected.contains(choice) {
                            Image(systemName: "checkmark")
                        }
                    }
                    .padding()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(selected.isEmpty || selected.contains(choice) ? 1 : 0.5)
                // Expose selection to assistive tech (and UI tests): the
                // checkmark image alone is invisible to both.
                .accessibilityAddTraits(selected.contains(choice) ? .isSelected : [])
                Divider()
            }
        }
    }

    private func toggle(_ choice: String) {
        if multiSelect {
            var next = selected
            if let index = next.firstIndex(of: choice) { next.remove(at: index) } else { next.append(choice) }
            onSelect(next)
        } else {
            onSelect(selected == [choice] ? [] : [choice])
        }
    }
}

struct TokenEntryView: View {
    let placeholder: String
    let tokens: [String]
    /// Whether this page is a people question — selects which vocabulary
    /// entity (`PersonEntity` vs `TokenEntity`) backs autocomplete.
    let isPeople: Bool
    /// Unique per-page registry key (page id + field kind). Must be
    /// distinct across pages so registrations from different token/people
    /// pages never collide or clobber each other in the shared registry.
    let identifier: String
    let onChange: ([String]) -> Void
    let flushRegistry: PendingFlushRegistry
    /// Survey-wide shared focus (keyed by page id) + this field's key.
    /// Parent-driven so the field is focused the moment its page becomes
    /// current — never gated on any local work this view does on appear.
    let focus: SwiftUI.FocusState<String?>.Binding
    let focusID: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.appDefaults) private var appDefaults
    /// Live keystrokes stay in this local `@State`; suggestions are computed
    /// purely from local state per render — never writing to any observable
    /// per keystroke (see `LocalTextEditorField`'s doc comment for the
    /// keyboard-garbling bug that motivates this).
    @State private var draft = ""
    /// Vocabulary candidates, fetched once per appearance — never per keystroke.
    @State private var candidates: [(text: String, usageCount: Int)] = []
    /// People-question candidates: full registry entities so suggestions
    /// resolve alternate names without duplicate chips (plan 22).
    @State private var peopleCandidates: [PersonEntity] = []
    /// Contact matches for the current draft (people questions with the
    /// contacts toggle on). Provider is created per field appearance so the
    /// contact store is fetched at most once per appearance, off-main.
    @State private var contactProvider: (any ContactSuggestionProviding)?
    @State private var contactMatches: [ContactMatch] = []
    @State private var showsContactsOffer = false

    private var contactsEnabled: Bool {
        appDefaults.bool(forKey: ContactSuggestions.enabledKey)
    }

    private var fieldFocused: Bool { focus.wrappedValue == focusID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !tokens.isEmpty {
                FlowingChips(tokens: tokens) { removed in
                    onChange(tokens.filter { $0 != removed })
                }
            }
            TextField(placeholder, text: $draft)
                .font(.title3)
                .focused(focus, equals: focusID)
                .onSubmit(commitDraft)
                .accessibilityIdentifier("token-field")
            if fieldFocused, !suggestions.isEmpty {
                suggestionsRow
            }
            if showsContactsOffer {
                contactsOfferRow
            }
        }
        .padding()
        .task {
            // Deferred one runloop hop: the vocabulary fetch is main-actor
            // SwiftData work, and running it synchronously at appear could
            // gate the first-responder handoff that focuses this field on
            // page arrival. Yielding lets focus/keyboard land first —
            // suggestions can populate a beat later.
            await Task.yield()
            loadCandidates()
            if isPeople {
                showsContactsOffer = !contactsEnabled
                    && !appDefaults.bool(forKey: ContactSuggestions.inlineOfferSeenKey)
                if contactsEnabled {
                    contactProvider = ContactSuggestions.makeProvider()
                }
            }
        }
        .task(id: draft) {
            guard let contactProvider else { return }
            // Empty query = history only; denied/errors → [] from the provider.
            let matches = await contactProvider.matches(prefix: draft)
            if !Task.isCancelled { contactMatches = matches }
        }
        .onAppear {
            flushRegistry.register(identifier, flush: commitDraft)
        }
        .onChange(of: fieldFocused) { _, focused in
            // Reporter parity: losing focus tokenizes the pending text, just
            // like pressing Return.
            if !focused { commitDraft() }
        }
        .onDisappear {
            commitDraft()
            flushRegistry.unregister(identifier)
        }
    }

    /// Tokenizes any pending draft text. Called from Return (`onSubmit`),
    /// focus loss, disappearance, and the forced flush an ancestor runs
    /// before NEXT/DONE/page-swipe — so text typed into the field is never
    /// lost by advancing without pressing Return. Idempotent: an empty
    /// (already-committed) draft is a no-op, and a draft matching the
    /// last-added token is skipped so overlapping triggers can't
    /// double-append.
    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        draft = ""
        guard tokens.last != trimmed else { return }
        onChange(tokens + [trimmed])
    }

    /// History/registry suggestions first, then contact matches (people
    /// questions only), blended and deduped by `PersonSuggestionMerger`.
    private var suggestions: [PersonSuggestion] {
        let history = isPeople
            ? TokenSuggester.suggestPeople(query: draft, people: peopleCandidates, excluding: tokens)
            : TokenSuggester.suggest(query: draft, candidates: candidates, excluding: tokens)
        guard isPeople, !contactMatches.isEmpty else {
            return history.map { PersonSuggestion(text: $0, isContact: false) }
        }
        let excluded = Set(tokens.map(PersonResolver.normalize))
        let eligible = contactMatches.filter {
            !excluded.contains(PersonResolver.normalize($0.displayName))
        }
        return PersonSuggestionMerger.blend(history: history, contacts: eligible)
    }

    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(suggestions, id: \.text) { suggestion in
                    Button {
                        pick(suggestion)
                    } label: {
                        HStack(spacing: 4) {
                            suggestionGlyph(suggestion)
                                .accessibilityHidden(true) // decorative source glyph
                            Text(suggestion.text)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(suggestion.text)
                    .accessibilityHint(suggestion.isContact
                        ? "Adds this contact."
                        : "Adds this recent entry.")
                    .accessibilityIdentifier("token-suggestion-\(suggestion.text)")
                }
            }
        }
        .accessibilityIdentifier("token-suggestions")
    }

    /// Contact chips show the contact's photo when one exists; history chips
    /// keep the "recent" glyph.
    @ViewBuilder
    private func suggestionGlyph(_ suggestion: PersonSuggestion) -> some View {
        if let data = suggestion.thumbnail, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 20, height: 20)
                .clipShape(Circle())
        } else if suggestion.isContact {
            Image(systemName: "person.crop.circle").imageScale(.small)
        } else {
            Image(systemName: "clock.arrow.circlepath").imageScale(.small)
        }
    }

    private func pick(_ suggestion: PersonSuggestion) {
        draft = ""
        if !tokens.contains(suggestion.text) {
            onChange(tokens + [suggestion.text])
        }
        if suggestion.isContact { recordContactPick(suggestion.text) }
    }

    /// Picking a contact suggestion creates the PersonEntity if it's new
    /// (via PersonResolver so alternate names heal to the same person) and
    /// records the per-device contact link.
    ///
    /// Accepted edge case: if the survey is abandoned (or a rebuild runs)
    /// before this answer is filed, the freshly created alias-free entity is
    /// pruned by the next `VocabularyBuilder.rebuild` and its link-cache row
    /// is orphaned. Harmless and device-local: re-picking the contact
    /// recreates both, and orphaned cache rows never sync anywhere.
    private func recordContactPick(_ displayName: String) {
        guard let match = contactMatches.first(where: {
            PersonResolver.normalize($0.displayName) == PersonResolver.normalize(displayName)
        }) else { return }
        let people = (try? modelContext.fetch(FetchDescriptor<PersonEntity>())) ?? []
        let person = PersonResolver.person(matching: displayName, in: people) ?? {
            let created = PersonEntity()
            created.text = displayName
            modelContext.insert(created)
            try? modelContext.save()
            return created
        }()
        guard let contactIdentifier = match.contactIdentifier else { return }
        let cache = ContactLinkCache(
            defaults: ContactSuggestions.isTestEnvironment ? appDefaults : nil)
        cache.link(personID: person.uniqueIdentifier,
                   contactIdentifier: contactIdentifier,
                   matchKeys: match.matchKeys)
    }

    /// One-time inline offer under a people question (spec §Contacts in the
    /// typeahead): enabling makes the single standard requestAccess call;
    /// either choice marks the offer seen so it never reappears.
    private var contactsOfferRow: some View {
        HStack(spacing: 12) {
            Text("Suggest names from your Contacts?")
                .font(.footnote)
                .opacity(0.8)
            Button("Enable") {
                appDefaults.set(true, forKey: ContactSuggestions.inlineOfferSeenKey)
                showsContactsOffer = false
                Task {
                    let provider = ContactSuggestions.makeProvider()
                    _ = await provider.requestAccess()
                    appDefaults.set(true, forKey: ContactSuggestions.enabledKey)
                    contactProvider = provider
                }
            }
            .font(.footnote.weight(.semibold))
            .accessibilityIdentifier("contacts-offer-enable")
            Button("No Thanks") {
                appDefaults.set(true, forKey: ContactSuggestions.inlineOfferSeenKey)
                showsContactsOffer = false
            }
            .font(.footnote)
            .accessibilityIdentifier("contacts-offer-dismiss")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("contacts-inline-offer")
    }

    private func loadCandidates() {
        if isPeople {
            peopleCandidates = (try? modelContext.fetch(FetchDescriptor<PersonEntity>(
                sortBy: [SortDescriptor(\.uniqueIdentifier)]))) ?? []
        } else {
            let fetched = (try? modelContext.fetch(FetchDescriptor<TokenEntity>())) ?? []
            candidates = fetched.map { (text: $0.text, usageCount: $0.usageCount) }
        }
    }
}

struct FlowingChips: View {
    let tokens: [String]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(tokens, id: \.self) { token in
                    Button {
                        onRemove(token)
                    } label: {
                        HStack(spacing: 4) {
                            Text(token)
                            Image(systemName: "xmark.circle.fill").imageScale(.small)
                                .accessibilityHidden(true) // decorative; the action is the button itself
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(token)
                    .accessibilityHint("Removes this entry.")
                }
            }
        }
    }
}
