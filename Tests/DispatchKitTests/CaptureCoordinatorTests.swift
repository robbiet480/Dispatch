import Foundation
import Testing
@testable import DispatchKit

struct StubProvider: SensorProvider {
    let kind: SensorKind
    let delay: Duration
    let result: Result<SensorPayload, Error>

    func capture() async throws -> SensorPayload {
        try await Task.sleep(for: delay)
        return try result.get()
    }
}

struct StubError: Error {}

private func collect(_ stream: AsyncStream<CaptureEvent>) async -> [SensorKind: SensorOutcome] {
    var outcomes: [SensorKind: SensorOutcome] = [:]
    for await event in stream { outcomes[event.kind] = event.outcome }
    return outcomes
}

private func testSettings() -> SensorSettings {
    let name = "capture-test-\(UUID().uuidString)"
    return SensorSettings(defaults: UserDefaults(suiteName: name)!)
}

@Test func capturesAllProvidersConcurrently() async {
    let providers: [any SensorProvider] = [
        StubProvider(kind: .battery, delay: .milliseconds(10), result: .success(.battery(0.5))),
        StubProvider(kind: .audio, delay: .milliseconds(10), result: .success(.audio(AudioSample(avg: -40, peak: -20)))),
    ]
    let start = ContinuousClock.now
    let outcomes = await collect(CaptureCoordinator.capture(
        providers: providers, settings: testSettings(), timeout: .seconds(1)))
    #expect(outcomes.count == 2)
    guard case .captured(.battery(let level)) = outcomes[.battery] else { Issue.record("battery missing"); return }
    #expect(level == 0.5)
    // Concurrent, not serial: two 10ms providers well under 500ms total.
    #expect(ContinuousClock.now - start < .milliseconds(500))
}

@Test func timeoutYieldsUnavailable() async {
    let providers: [any SensorProvider] = [
        StubProvider(kind: .weather, delay: .seconds(5), result: .success(.altitude(1))),
        StubProvider(kind: .battery, delay: .milliseconds(1), result: .success(.battery(1.0))),
    ]
    let outcomes = await collect(CaptureCoordinator.capture(
        providers: providers, settings: testSettings(), timeout: .milliseconds(50)))
    guard case .unavailable = outcomes[.weather] else { Issue.record("expected timeout unavailable"); return }
    guard case .captured = outcomes[.battery] else { Issue.record("fast provider should capture"); return }
}

@Test func errorsYieldUnavailable() async {
    let providers: [any SensorProvider] = [
        StubProvider(kind: .location, delay: .milliseconds(1), result: .failure(StubError())),
    ]
    let outcomes = await collect(CaptureCoordinator.capture(
        providers: providers, settings: testSettings(), timeout: .seconds(1)))
    guard case .unavailable = outcomes[.location] else { Issue.record("expected unavailable"); return }
}

@Test func disabledSensorsSkipCapture() async {
    let settings = testSettings()
    settings.setEnabled(.audio, false)
    let providers: [any SensorProvider] = [
        StubProvider(kind: .audio, delay: .milliseconds(1), result: .success(.audio(AudioSample(avg: -40, peak: -20)))),
    ]
    let outcomes = await collect(CaptureCoordinator.capture(
        providers: providers, settings: settings, timeout: .seconds(1)))
    guard case .disabled = outcomes[.audio] else { Issue.record("expected disabled"); return }
}
