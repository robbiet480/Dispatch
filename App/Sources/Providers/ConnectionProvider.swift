import DispatchKit
import Foundation
import Network
import os

struct ConnectionProvider: SensorProvider {
    let kind = SensorKind.connection
    private static let queue = DispatchQueue(label: "connection-probe")

    func capture() async throws -> SensorPayload {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        let path = await withCheckedContinuation { continuation in
            // NWPathMonitor may fire pathUpdateHandler more than once; a
            // one-shot flag guards the continuation against double-resume.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                let shouldResume = resumed.withLock { already -> Bool in
                    if already { return false }
                    already = true
                    return true
                }
                if shouldResume { continuation.resume(returning: path) }
            }
            monitor.start(queue: Self.queue)
        }
        guard path.status == .satisfied else { return .connection(ConnectionType.none.rawValue) }
        let type: ConnectionType = path.usesInterfaceType(.wifi) ? .wifi : .cellular
        return .connection(type.rawValue)
    }
}
