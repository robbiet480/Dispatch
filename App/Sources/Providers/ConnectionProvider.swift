import DispatchKit
import Network

struct ConnectionProvider: SensorProvider {
    let kind = SensorKind.connection

    func capture() async throws -> SensorPayload {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        let path = await withCheckedContinuation { continuation in
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil
                continuation.resume(returning: path)
            }
            monitor.start(queue: DispatchQueue(label: "connection-probe"))
        }
        guard path.status == .satisfied else { return .connection(ConnectionType.none.rawValue) }
        let type: ConnectionType = path.usesInterfaceType(.wifi) ? .wifi : .cellular
        return .connection(type.rawValue)
    }
}
