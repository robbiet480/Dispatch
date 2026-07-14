import DispatchKit
import SwiftUI

/// Settings → About: version, the CloudKit container the app syncs through,
/// the lineage blurb, and the repository link.
struct AboutSettingsPane: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: versionText)
                LabeledContent("Sync container", value: SyncPolicy.containerIdentifier)
                Link("View on GitHub", destination: Self.repositoryURL)
                    .accessibilityIdentifier("github-link")
            } header: {
                Text("About")
            } footer: {
                Text("Dispatch carries the torch of Reporter — the self-tracking app by Nicholas Felton — as an open-source app for iPhone, Apple Watch, and Mac.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500)
    }

    private static let repositoryURL = URL(string: "https://github.com/robbiet480/Dispatch")!

    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
