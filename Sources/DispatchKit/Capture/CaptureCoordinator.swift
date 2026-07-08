import Foundation

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

    private static func resolve(_ provider: any SensorProvider, timeout: Duration) async -> SensorOutcome {
        await withTaskGroup(of: SensorOutcome.self) { group in
            group.addTask {
                do {
                    return .captured(try await provider.capture())
                } catch {
                    return .unavailable(reason: String(describing: error))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .unavailable(reason: "timed out")
            }
            let first = await group.next() ?? .unavailable(reason: "no result")
            group.cancelAll()
            return first
        }
    }
}
