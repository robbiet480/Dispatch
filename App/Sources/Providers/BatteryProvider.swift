import DispatchKit
import UIKit

struct BatteryProvider: SensorProvider {
    let kind = SensorKind.battery

    func capture() async throws -> SensorPayload {
        let level = await MainActor.run { () -> Float in
            let previous = UIDevice.current.isBatteryMonitoringEnabled
            UIDevice.current.isBatteryMonitoringEnabled = true
            defer { UIDevice.current.isBatteryMonitoringEnabled = previous }
            return UIDevice.current.batteryLevel
        }
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
