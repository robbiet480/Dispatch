import Foundation
import os

/// Device provenance for reports (plan 19): which device filed a report.
///
/// `model` is the raw hardware identifier (e.g. "iPhone17,1" / "Watch7,4")
/// read via POSIX `uname(3)`'s `utsname.machine` — unentitled on both iOS
/// and watchOS (no framework, capability, or profile impact).
///
/// `deviceName` is injected by each platform target at launch (the kit is
/// Foundation-only; `UIDevice.current.name` lives in UIKit and
/// `WKInterfaceDevice.current().name` in WatchKit). Reality, doc-cited:
/// since iOS 16 / watchOS 9 those APIs return the GENERIC device name
/// ("iPhone", "Apple Watch") unless the app holds
/// `com.apple.developer.device-information.user-assigned-device-name`
/// (https://developer.apple.com/documentation/uikit/uidevice/name,
/// https://developer.apple.com/documentation/watchkit/wkinterfacedevice/name).
/// The entitlement is requested (2026-07-10, approval pending); the callers
/// read the name APIs UNCONDITIONALLY — generic names are accepted and
/// expected until the grant, which upgrades the value in place with no code
/// or schema change.
public enum DeviceIdentity {
    /// The raw hardware model identifier via `utsname.machine`, nil only if
    /// `uname(3)` fails (it doesn't in practice).
    public static var model: String? {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return nil }
        return withUnsafeBytes(of: &systemInfo.machine) { rawBuffer in
            let data = Data(rawBuffer.prefix(while: { $0 != 0 }))
            return String(data: data, encoding: .utf8)
        }
    }

    private static let nameState = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The device name, injected once at launch by the platform target
    /// (UIDevice/WKInterfaceDevice); nil until injected (e.g. in kit tests
    /// that don't simulate a platform).
    public static var deviceName: String? {
        get { nameState.withLock { $0 } }
        set { nameState.withLock { $0 = newValue } }
    }
}
