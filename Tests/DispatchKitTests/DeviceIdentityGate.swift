import Foundation

@testable import DispatchKit

/// Cross-suite exclusion for tests that inject the process-global
/// `DeviceIdentity.deviceName`.
///
/// `.serialized` only serializes tests WITHIN a suite — suites still run in
/// parallel with each other, so one suite's `defer { deviceName = nil }`
/// could fire between another suite's injection and the code under test
/// reading it (observed on CI in plan 43: the sync-diagnostics privacy pin
/// lost its injected "Robbie's iPhone" mid-test and its provenance assertion
/// failed). Every test that sets `deviceName` must do so through this gate;
/// the lock spans the whole body, and the previous value is restored even on
/// throw.
enum DeviceIdentityGate {
    private static let lock = NSRecursiveLock()

    static func withDeviceName<T>(_ name: String?, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        let previous = DeviceIdentity.deviceName
        DeviceIdentity.deviceName = name
        defer { DeviceIdentity.deviceName = previous }
        return try body()
    }
}
