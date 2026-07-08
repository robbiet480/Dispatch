import DispatchKit
import UIKit

struct BatteryProvider: SensorProvider {
    let kind = SensorKind.battery

    func capture() async throws -> SensorPayload {
        await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        let level = await MainActor.run { UIDevice.current.batteryLevel }
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
