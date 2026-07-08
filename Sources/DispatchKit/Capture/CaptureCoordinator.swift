import Foundation
import os

/// Runs all enabled providers concurrently, each raced against `timeout`.
/// Emits exactly one CaptureEvent per provider; the stream finishes when
/// every provider has resolved. A sensor can time out, throw, or be
/// disabled — none of that stops the others or the report.
public enum CaptureCoordinator {
    public static func capture(
        providers: [any SensorProvider],
        settings: SensorSettings,
        timeout: Duration = .seconds(10)
    ) -> AsyncStream<CaptureEvent> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: CaptureEvent.self) { group in
                    for provider in providers {
                        guard settings.isEnabled(provider.kind) else {
                            continuation.yield(CaptureEvent(kind: provider.kind, outcome: .disabled))
                            continue
                        }
                        group.addTask {
                            await CaptureEvent(kind: provider.kind,
                                               outcome: resolve(provider, timeout: timeout))
                        }
                    }
                    for await event in group {
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One-shot continuation race that ALWAYS resumes within `timeout`. A
    /// `withTaskGroup`-based race can't return until every child finishes, so
    /// a provider suspended in a never-resumed continuation (ignoring
    /// cancellation) would keep the group — and the whole stream — alive
    /// forever. Here the timeout branch resumes the continuation independently.
    ///
    /// After the timeout fires we `cancel()` the provider Task: cooperative
    /// providers unwind and stop, but a non-cooperative (hung) provider Task is
    /// intentionally ABANDONED — it keeps running detached until the process
    /// exits. That leak is the deliberate cost of never hanging the report.
    private static func resolve(_ provider: any SensorProvider, timeout: Duration) async -> SensorOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<SensorOutcome, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            func resumeOnce(_ outcome: SensorOutcome) {
                let shouldResume = resumed.withLock { already -> Bool in
                    if already { return false }
                    already = true
                    return true
                }
                if shouldResume { continuation.resume(returning: outcome) }
            }
            let work = Task {
                let outcome: SensorOutcome
                do {
                    outcome = .captured(try await provider.capture())
                } catch {
                    outcome = .unavailable(reason: String(describing: error))
                }
                resumeOnce(outcome)
            }
            Task {
                try? await Task.sleep(for: timeout)
                work.cancel() // cooperative providers stop; hung ones are abandoned
                resumeOnce(.unavailable(reason: "timed out"))
            }
        }
    }
}
