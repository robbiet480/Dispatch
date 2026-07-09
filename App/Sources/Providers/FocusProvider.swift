import DispatchKit
import Foundation
import Intents

/// Captures whether a Focus is active, and — when the Dispatch Focus Filter
/// is active (plan 15) — the user's label for it (e.g. "Work"). The label
/// comes from FocusFilterState in the App Group defaults, written by
/// DispatchFocusFilter.perform(); without a filter the reading falls back
/// to the boolean-only INFocusStatusCenter capture (label nil → rendered
/// as "On"/"Off").
struct FocusProvider: SensorProvider {
    let kind = SensorKind.focus

    func capture() async throws -> SensorPayload {
        let center = INFocusStatusCenter.default
        if center.authorizationStatus == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                center.requestAuthorization { status in continuation.resume(returning: status) }
            }
        }
        guard center.authorizationStatus == .authorized else {
            throw ProviderError("focus status not authorized")
        }
        guard let isFocused = center.focusStatus.isFocused else {
            throw ProviderError("focus status unavailable")
        }
        // Filter state without isFocused would be stale (e.g. the app never
        // saw the deactivation replan) — only label an ACTIVE focus.
        let filterLabel = isFocused
            ? UserDefaults(suiteName: StoreLocation.appGroupID)
                .flatMap(FocusFilterState.read(from:))?.label
            : nil
        return .focus(FocusState(label: filterLabel, isFocused: isFocused))
    }
}
