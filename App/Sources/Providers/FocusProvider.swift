import DispatchKit
import Foundation
import Intents

/// Captures whether a Focus is active (boolean only — per-Focus labels
/// arrive with the Focus Filter extension in Plan 4).
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
        return .focus(FocusState(label: nil, isFocused: isFocused))
    }
}
