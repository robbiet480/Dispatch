import DispatchKit
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

/// Battery level via the platform device object — the sole shared provider
/// with a real platform conditional (plan 19 design §provider-code-motion).
/// Both platforms require enabling battery monitoring before reading:
/// watchOS `WKInterfaceDevice.isBatteryMonitoringEnabled` (watchOS 4+,
/// https://developer.apple.com/documentation/watchkit/wkinterfacedevice/isbatterymonitoringenabled),
/// iOS `UIDevice.isBatteryMonitoringEnabled`
/// (https://developer.apple.com/documentation/uikit/uidevice/isbatterymonitoringenabled).
struct BatteryProvider: SensorProvider {
    let kind = SensorKind.battery

    func capture() async throws -> SensorPayload {
        #if os(watchOS)
        let level = await MainActor.run { () -> Float in
            let device = WKInterfaceDevice.current()
            let previous = device.isBatteryMonitoringEnabled
            device.isBatteryMonitoringEnabled = true
            defer { device.isBatteryMonitoringEnabled = previous }
            return device.batteryLevel
        }
        #else
        let level = await MainActor.run { () -> Float in
            let previous = UIDevice.current.isBatteryMonitoringEnabled
            UIDevice.current.isBatteryMonitoringEnabled = true
            defer { UIDevice.current.isBatteryMonitoringEnabled = previous }
            return UIDevice.current.batteryLevel
        }
        #endif
        guard level >= 0 else {
            throw ProviderError("battery level unavailable")
        }
        return .battery(Double(level))
    }
}

struct ProviderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
