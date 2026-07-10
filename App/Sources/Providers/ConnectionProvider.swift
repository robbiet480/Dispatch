import CoreTelephony
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
        return .connection(Self.classify(path).rawValue)
    }

    /// Plan-26 classification: wifi → wired → cellular (satellite, then
    /// generation via CoreTelephony). Non-cellular satisfied paths keep the
    /// pre-plan-26 plain `.cellular` fallback.
    static func classify(_ path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        guard path.usesInterfaceType(.cellular) else { return .cellular } // pre-plan-26 fallback preserved
        // Satellite: iOS 26 ultra-constrained path signal. Verified against the
        // iOS 26.5 SDK swiftinterface: `NWPath.isUltraConstrained`,
        // @available(iOS 26.0, *) — no #available gate needed (deployment
        // target is iOS 26.0).
        if path.isUltraConstrained { return .satellite }
        // Cellular generation via the active data SIM. Simulator/no-SIM
        // reality: `dataServiceIdentifier` is nil there → plain `.cellular`,
        // which is the designed fallback. The CTRadioAccessTechnology*
        // constants' runtime values equal their names (verified 2026-07-10 by
        // dumping the iOS 26.5 simulator runtime's CoreTelephony binary: every
        // constant's CFString literal matches its symbol name), so the kit's
        // pure string table matches the dictionary values directly.
        let info = CTTelephonyNetworkInfo()
        let technology = info.dataServiceIdentifier
            .flatMap { info.serviceCurrentRadioAccessTechnology?[$0] }
        return ConnectionType.cellular(fromRadioAccessTechnology: technology)
    }
}
