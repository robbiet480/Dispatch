import DispatchKit
import SwiftData
import SwiftUI

/// Settings → People (plan 22): the person-registry management screen.
/// Lists every person (photo via linked contact, display name, alternate
/// names caption, report count), supports multi-select merge, and navigates
/// to `PersonDetailView` for rename / link / delete.
struct PeopleListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appDefaults) private var appDefaults
    @Environment(ThemeStore.self) private var themeStore
    @Query(sort: \PersonEntity.text) private var people: [PersonEntity]

    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []

    private var theme: Theme { themeStore.theme }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                if people.isEmpty {
                    Text("People you mention in reports appear here.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .listRowBackground(Color.white.opacity(0.12))
                }
                ForEach(people, id: \.uniqueIdentifier) { person in
                    row(for: person)
                        .listRowBackground(Color.white.opacity(0.12))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("people-list")
        }
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button("Merge") { mergeSelection() }
                        .disabled(selectedIDs.count < 2)
                        .accessibilityIdentifier("person-merge")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if people.count > 1 {
                    Button(isSelecting ? "Cancel" : "Select") {
                        isSelecting.toggle()
                        selectedIDs = []
                    }
                    .accessibilityIdentifier("people-select-toggle")
                }
            }
        }
    }

    @ViewBuilder
    private func row(for person: PersonEntity) -> some View {
        if isSelecting {
            Button {
                toggleSelection(person)
            } label: {
                HStack {
                    Image(systemName: selectedIDs.contains(person.uniqueIdentifier)
                        ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.white)
                    PersonRowView(person: person, appDefaults: appDefaults)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("person-row-\(person.text)")
        } else {
            NavigationLink(destination: PersonDetailView(person: person)) {
                PersonRowView(person: person, appDefaults: appDefaults)
            }
            .accessibilityIdentifier("person-row-\(person.text)")
        }
    }

    private func toggleSelection(_ person: PersonEntity) {
        if selectedIDs.contains(person.uniqueIdentifier) {
            selectedIDs.remove(person.uniqueIdentifier)
        } else {
            selectedIDs.insert(person.uniqueIdentifier)
        }
    }

    /// Merges the selection into a deterministic survivor: highest usage
    /// count, ties broken by lowest uniqueIdentifier. Absorbed people's
    /// contact links are dropped (per-device cache rows for deleted persons);
    /// consumers refresh through the same rebuild the remote-change pipeline
    /// runs.
    private func mergeSelection() {
        let selected = people.filter { selectedIDs.contains($0.uniqueIdentifier) }
        guard selected.count >= 2 else { return }
        let survivor = selected.sorted {
            if $0.usageCount != $1.usageCount { return $0.usageCount > $1.usageCount }
            return $0.uniqueIdentifier < $1.uniqueIdentifier
        }[0]
        let cache = ContactLinkCache(
            defaults: ContactSuggestions.isTestEnvironment ? appDefaults : nil)
        for absorbed in selected where absorbed !== survivor {
            cache.unlink(personID: absorbed.uniqueIdentifier)
            try? PersonResolver.merge(absorbed, into: survivor, context: modelContext)
        }
        try? VocabularyBuilder.rebuild(in: modelContext)
        isSelecting = false
        selectedIDs = []
    }
}

/// One list row: live-fetched contact photo (linked contact only), display
/// name, alternate-names caption, report count.
struct PersonRowView: View {
    let person: PersonEntity
    let appDefaults: UserDefaults

    @State private var thumbnail: Data?

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(person.text)
                    .foregroundStyle(.white)
                if !person.alternateNames.isEmpty {
                    Text("Also: \(person.alternateNames.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            Text("\(person.usageCount)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityLabel("\(person.usageCount) reports")
        }
        .task(id: person.uniqueIdentifier) {
            let cache = ContactLinkCache(
                defaults: ContactSuggestions.isTestEnvironment ? appDefaults : nil)
            guard let identifier = cache.contactIdentifier(for: person.uniqueIdentifier) else {
                thumbnail = nil
                return
            }
            let provider = ContactSuggestions.makeProvider()
            thumbnail = await provider.thumbnail(
                identifier: identifier,
                matchKeys: cache.matchKeys(for: person.uniqueIdentifier))
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let thumbnail, let image = UIImage(data: thumbnail) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 32, height: 32)
        }
    }
}
