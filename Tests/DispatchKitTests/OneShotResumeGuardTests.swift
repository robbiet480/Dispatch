import Foundation
import Testing
@testable import DispatchKit

/// Regression coverage for the build-8 launch crash: CMPedometer's query
/// completion handler fired twice on iOS 27 beta and double-resumed the
/// Motion permission continuation, trapping in libswift_Concurrency. Guarded
/// callback shims must resume exactly once no matter how many times (or on
/// which queue) the framework invokes the handler.
@Suite struct OneShotResumeGuardTests {
    @Test func claimReturnsTrueExactlyOnce() {
        let gate = OneShotResumeGuard()
        #expect(gate.claim())
        #expect(!gate.claim())
        #expect(!gate.claim())
    }

    /// Simulates the crash shape: a framework calling its completion handler
    /// twice. The guarded continuation must not trap and must yield exactly
    /// one result (the first callback's value).
    @Test func doubleInvokedCompletionResumesExactlyOnce() async {
        func flakyQuery(completion: @escaping @Sendable (Int) -> Void) {
            completion(1)
            completion(2) // second invocation, as observed from CMPedometer
        }

        let gate = OneShotResumeGuard()
        let value: Int = await withCheckedContinuation { continuation in
            flakyQuery { result in
                if gate.claim() { continuation.resume(returning: result) }
            }
        }
        #expect(value == 1)
        #expect(!gate.claim())
    }

    /// The real handler can arrive on any queue: hammer claim() from many
    /// concurrent tasks and require exactly one winner.
    @Test func claimIsSingleWinnerUnderConcurrency() async {
        let gate = OneShotResumeGuard()
        let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<100 {
                group.addTask { gate.claim() }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(winners == 1)
    }
}
