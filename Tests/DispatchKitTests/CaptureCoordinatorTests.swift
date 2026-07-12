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

struct HangingProvider: SensorProvider {
    let kind: SensorKind
    func capture() async throws -> SensorPayload {
        await withCheckedContinuation { (_: CheckedContinuation<Never, Never>) in }
    }
}

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
    // Delays are deliberately LARGE so the assertion measures concurrency,
    // not scheduler overhead: serial execution needs ≥ 2.0s, concurrent
    // ≈ 1.0s + overhead. A loaded CI runner once added ~0.9s of pure
    // overhead to a 10ms-delay version of this test and flaked its 500ms
    // bound; with 1s delays that same overhead still passes, while a true
    // serialization regression overshoots the bound by a full second.
    let providers: [any SensorProvider] = [
        StubProvider(kind: .battery, delay: .seconds(1), result: .success(.battery(0.5))),
        StubProvider(kind: .audio, delay: .seconds(1), result: .success(.audio(AudioSample(avg: -40, peak: -20)))),
    ]
    let start = ContinuousClock.now
    let outcomes = await collect(CaptureCoordinator.capture(
        providers: providers, settings: testSettings(), timeout: .seconds(5)))
    #expect(outcomes.count == 2)
    guard case .captured(.battery(let level)) = outcomes[.battery] else { Issue.record("battery missing"); return }
    #expect(level == 0.5)
    #expect(ContinuousClock.now - start < .milliseconds(1900))
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

@Test func hungProviderStillTimesOutAndStreamFinishes() async {
    let providers: [any SensorProvider] = [
        HangingProvider(kind: .weather),
        StubProvider(kind: .battery, delay: .milliseconds(1), result: .success(.battery(1.0))),
    ]
    let start = ContinuousClock.now
    let outcomes = await collect(CaptureCoordinator.capture(
        providers: providers, settings: testSettings(), timeout: .milliseconds(100)))
    #expect(outcomes.count == 2)
    guard case .unavailable = outcomes[.weather] else { Issue.record("expected timeout"); return }
    #expect(ContinuousClock.now - start < .seconds(5)) // stream finished, not hung
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
