import Contacts
import ContactsUI
import DispatchKit
import SwiftData
import SwiftUI

/// Detail/management for one registry person (plan 22): rename (heals),
/// link/unlink a contact (zero-permission system picker, independent of the
/// suggestions toggle), and delete (registry entry only — reports untouched,
/// with the documented resurrection caveat).
struct PersonDetailView: View {
    let person: PersonEntity

    @Environment(\.modelContext) private var modelContext
    @Environment(\.appDefaults) private var appDefaults
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeStore.self) private var themeStore

    @State private var nameDraft = ""
    @State private var showsContactPicker = false
    @State private var showsDeleteConfirmation = false
    @State private var linkedContactID: String?
    @State private var thumbnail: Data?

    private var theme: Theme { themeStore.theme }

    private var linkCache: ContactLinkCache {
        ContactLinkCache(defaults: ContactSuggestions.isTestEnvironment ? appDefaults : nil)
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                nameSection
                if !person.alternateNames.isEmpty {
                    alternatesSection
                }
                contactSection
                deleteSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Plan 27: readable column on iPad; no-op at iPhone widths.
            .readableColumn()
        }
        .navigationTitle(person.text)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            nameDraft = person.text
            linkedContactID = linkCache.contactIdentifier(for: person.uniqueIdentifier)
        }
        .task(id: linkedContactID) {
            await refreshThumbnail()
        }
        .sheet(isPresented: $showsContactPicker) {
            ContactPickerView { contact in
                linkContact(contact)
            }
        }
        .confirmationDialog(
            "Delete \(person.text)?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Person", role: .destructive) { deletePerson() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The documented resurrection caveat: answers are text, so the
            // vocabulary rebuild may resurrect a plain entry.
            Text("Removes this person from the registry only — reports keep their answers. If the name still appears in reports, a plain entry may reappear.")
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            HStack(spacing: 12) {
                avatar
                TextField("Name", text: $nameDraft)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("person-rename-field")
            }
            Button("Rename") { rename() }
                .foregroundStyle(.white)
                .disabled(!canRename)
                .accessibilityIdentifier("person-rename")
        } header: {
            sectionHeader("NAME")
        } footer: {
            Text("Renaming keeps history: past reports keep the old name but count as the same person everywhere.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .listRowBackground(Color.clear)
        }
        .listRowBackground(Color.white.opacity(0.12))
    }

    private var canRename: Bool {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != person.text
    }

    private var alternatesSection: some View {
        Section {
            ForEach(person.alternateNames, id: \.self) { name in
                Text(name)
                    .foregroundStyle(.white.opacity(0.8))
            }
        } header: {
            sectionHeader("ALSO KNOWN AS")
        }
        .listRowBackground(Color.white.opacity(0.12))
    }

    private var contactSection: some View {
        Section {
            if linkedContactID != nil {
                Button("Unlink Contact") { unlinkContact() }
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("person-unlink")
            } else {
                Button("Link to Contact…") { showsContactPicker = true }
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("person-link")
            }
        } header: {
            sectionHeader("CONTACT")
        } footer: {
            Text("Links are per-device and never synced. The photo comes from the linked contact.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .listRowBackground(Color.clear)
        }
        .listRowBackground(Color.white.opacity(0.12))
    }

    private var deleteSection: some View {
        Section {
            Button("Delete Person", role: .destructive) {
                showsDeleteConfirmation = true
            }
            .accessibilityIdentifier("person-delete")
        }
        .listRowBackground(Color.white.opacity(0.12))
    }

    @ViewBuilder
    private var avatar: some View {
        if let thumbnail, let image = UIImage(data: thumbnail) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 40, height: 40)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.8))
    }

    // MARK: - Actions

    /// Rename heals: old name → alternates, consumers refresh through the
    /// same vocabulary rebuild the remote-change pipeline runs.
    private func rename() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        PersonResolver.rename(person, to: trimmed)
        try? modelContext.save()
        try? VocabularyBuilder.rebuild(in: modelContext)
    }

    private func linkContact(_ contact: CNContact) {
        linkCache.link(personID: person.uniqueIdentifier,
                       contactIdentifier: contact.identifier,
                       matchKeys: CNContactSuggestionProvider.matchKeys(for: contact))
        linkedContactID = contact.identifier
    }

    private func unlinkContact() {
        linkCache.unlink(personID: person.uniqueIdentifier)
        linkedContactID = nil
        thumbnail = nil
    }

    /// Delete removes the registry entry only; reports are untouched. The
    /// per-device link goes too. The immediate rebuild (matching the
    /// rename/merge flows) makes the documented resurrection behavior
    /// consistent right away: a still-mentioned name reappears as a plain
    /// entry now, not at some later rebuild.
    private func deletePerson() {
        linkCache.unlink(personID: person.uniqueIdentifier)
        modelContext.delete(person)
        try? modelContext.save()
        try? VocabularyBuilder.rebuild(in: modelContext)
        dismiss()
    }

    private func refreshThumbnail() async {
        guard let linkedContactID else {
            thumbnail = nil
            return
        }
        let provider = ContactSuggestions.makeProvider()
        thumbnail = await provider.thumbnail(
            identifier: linkedContactID,
            matchKeys: linkCache.matchKeys(for: person.uniqueIdentifier))
    }
}

/// Zero-permission system contact picker (CNContactPickerViewController):
/// usable regardless of the contacts-suggestions toggle — the system shows
/// the picker out-of-process and only the picked contact is returned.
private struct ContactPickerView: UIViewControllerRepresentable {
    let onPick: (CNContact) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (CNContact) -> Void

        init(onPick: @escaping (CNContact) -> Void) {
            self.onPick = onPick
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onPick(contact)
        }
    }
}
