import AppIntents
import DispatchKit
import Foundation
import os
import SwiftData

private let focusLog = Logger(subsystem: "io.robbie.Dispatch", category: "focusfilter")

/// A PromptGroup as an AppEntity so the Focus-filter configuration UI
/// (Settings → Focus → [mode] → Focus Filters → Dispatch) can offer a
/// multi-select of the user's groups. The options are read from the SHARED
/// App Group store READ-ONLY (`allowsSave: false`, no cloudKitDatabase) —
/// the widget SharedStoreReader pattern — because the system may query them
/// from a background-launched process while the foreground app has the
/// store open.
struct PromptGroupEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Prompt Group"
    static let defaultQuery = PromptGroupQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PromptGroupQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PromptGroupEntity] {
        Self.allGroups().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PromptGroupEntity] {
        Self.allGroups()
    }

    /// All prompt groups (sortOrder order), titled by name. Read-only open
    /// of the shared store; missing store (fresh install pre-launch, legacy
    /// fallback) → no options rather than an error in the Settings UI.
    static func allGroups() -> [PromptGroupEntity] {
        guard let storeURL = StoreLocation.appGroupURL(),
              FileManager.default.fileExists(atPath: storeURL.path) else {
            focusLog.info("prompt group options: no shared store")
            return []
        }
        do {
            let schema = Schema(DispatchStore.allModels)
            let config = ModelConfiguration(
                schema: schema, url: storeURL, allowsSave: false, cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<PromptGroup>(
                sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.uniqueIdentifier)])
            let groups = try context.fetch(descriptor)
            return groups.map { group in
                let trimmed = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return PromptGroupEntity(
                    id: group.uniqueIdentifier,
                    name: trimmed.isEmpty ? "Untitled group" : trimmed
                )
            }
        } catch {
            focusLog.error("prompt group options read failed: \(error, privacy: .public)")
            return []
        }
    }
}

/// Dispatch's Focus Filter (plan 15): the user attaches it to a Focus mode
/// in Settings → Focus → [mode] → Focus Filters (Apple provides no in-app
/// enrollment). While that Focus is active, replans schedule only the
/// selected prompt groups (plus the ungrouped/global schedule unless
/// paused), and reports capture `focusName` as the Focus sensor's label.
///
/// Lifecycle (verified against Apple's "Defining your app's Focus filter"
/// article + the AppIntents swiftinterface, and empirically probed on the
/// iOS 26.5 simulator via `--probe-focus-filter` — the simulator's Settings
/// app has NO Focus pane, confirmed by XCUITest hierarchy dump, so
/// system-delivered activation could not be observed end-to-end there):
///
/// - ACTIVATION: the system calls `perform()` with the user's configured
///   @Parameter values. The intent lives in the app target (no App Intents
///   extension), so perform() runs IN THE APP PROCESS — Apple's doc offers
///   an extension only as an alternative "to handle Focus filters while
///   the app is in the background"; without one the system launches the
///   app in the background, which runs DispatchApp.init and therefore
///   registers `replanInApp` before any perform() can fire.
/// - DEACTIVATION (Focus off or switched): there is NO separate callback.
///   Apple's doc: "When you turn off the modified Focus, the system
///   provides the app's SetFocusFilterIntent conforming object with the
///   ... default parameters" — i.e. perform() is called again with every
///   parameter reset to its default (optionals nil, Bools to their
///   declared defaults). An all-defaults delivery therefore means "stop
///   filtering", which is also the correct reading of a filter the user
///   added but never configured.
/// - `Self.current` (headers: `get async throws`, with
///   SetFocusFilterIntentError.notFound as the documented failure) was
///   OBSERVED on the iOS 26.5 simulator to NOT throw with no Focus
///   active — it returned an instance with every parameter at its
///   default (displayName nil), indistinguishable from a deactivation
///   delivery. It is therefore NOT used to discriminate activation from
///   deactivation: perform() decides from the delivered parameters
///   alone, exactly as Apple's sample project does.
struct DispatchFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Prompt Groups"
    static let description = IntentDescription(
        "Limit which Dispatch prompt groups can send notifications while this Focus is on."
    )

    /// The label captured into reports (e.g. "Work"). Apple exposes no API
    /// for the actual Focus mode's name, so the user names it here.
    @Parameter(title: "Focus Name")
    var displayName: String?

    /// Groups allowed to fire while this Focus is active. Unconfigured
    /// (nil) is distinct from an explicitly empty selection.
    @Parameter(title: "Prompt Groups")
    var allowedGroups: [PromptGroupEntity]?

    @Parameter(title: "Pause Ungrouped Prompts", default: false)
    var pauseGlobalPrompts: Bool

    var displayRepresentation: DisplayRepresentation {
        let title = displayName?.isEmpty == false ? displayName! : "Dispatch"
        let groupCount = allowedGroups?.count ?? 0
        let subtitle = "\(groupCount) group\(groupCount == 1 ? "" : "s")"
            + (pauseGlobalPrompts ? ", other prompts paused" : "")
        return DisplayRepresentation(
            title: "\(title)", subtitle: "\(subtitle)"
        )
    }

    /// Set by DispatchApp at launch (same pattern as
    /// StartReportControlIntent.startReportInApp): perform() runs in the
    /// APP process — the system launches the app in the background when
    /// needed — so this hook is available to trigger an immediate replan.
    @MainActor static var replanInApp: (@MainActor () -> Void)?

    func perform() async throws -> some IntentResult {
        focusLog.info("""
        focus filter perform(): process=\(ProcessInfo.processInfo.processName, privacy: .public) \
        pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) \
        displayName=\(displayName ?? "<nil>", privacy: .public) \
        groups=\(allowedGroups?.map(\.id).joined(separator: ",") ?? "<nil>", privacy: .public) \
        pauseGlobal=\(pauseGlobalPrompts, privacy: .public)
        """)

        guard let defaults = UserDefaults(suiteName: StoreLocation.appGroupID) else {
            focusLog.error("focus filter: app group defaults unavailable")
            return .result()
        }

        if let state = Self.state(from: self) {
            state.write(to: defaults)
            focusLog.info("focus filter state written: \(state.label, privacy: .public)")
        } else {
            // All parameters at their defaults ⇒ deactivation delivery
            // (see the lifecycle comment above) or a never-configured
            // filter; either way, stop filtering.
            FocusFilterState.clear(in: defaults)
            focusLog.info("focus filter state cleared")
        }

        await MainActor.run {
            Self.replanInApp?()
        }
        return .result()
    }

    /// Maps a delivered intent instance to the persisted state; nil means
    /// "no filtering" (deactivation's all-defaults delivery, or a filter
    /// the user added without configuring anything — indistinguishable by
    /// design, and correctly identical in effect).
    static func state(from intent: DispatchFocusFilter) -> FocusFilterState? {
        let label = intent.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLabel = label?.isEmpty == false
        let isConfigured = hasLabel || intent.allowedGroups != nil || intent.pauseGlobalPrompts
        guard isConfigured else { return nil }
        return FocusFilterState(
            label: hasLabel ? label! : "Focus",
            allowedGroupIDs: intent.allowedGroups?.map(\.id) ?? [],
            pauseGlobal: intent.pauseGlobalPrompts
        )
    }
}
