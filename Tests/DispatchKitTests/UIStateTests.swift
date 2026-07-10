import Foundation
import Testing
@testable import DispatchKit

private func freshSuite() -> UserDefaults {
    UserDefaults(suiteName: "ui-test-\(UUID().uuidString)")!
}

@Test func themeDefaultsToTomatoAndPersists() {
    let defaults = freshSuite()
    let store = ThemeStore(defaults: defaults)
    #expect(store.theme == .tomato)
    store.theme = .teal
    #expect(ThemeStore(defaults: defaults).theme == .teal)
}

@Test func themeColorsAreExact() {
    #expect(Theme.tomato.backgroundHex == "#FA5B3D")
    #expect(Theme.teal.backgroundHex == "#20BEC6")
    #expect(Theme.gray.backgroundHex == "#9B9B9B")
    #expect(Theme.pink.backgroundHex == "#F268F1")
    #expect(Theme.chartreuse.backgroundHex == "#CBD82B")
    #expect(Theme.allCases.count == 5)
}

@Test func awakeToggleFilesCorrectKinds() {
    let store = AwakeStore(defaults: freshSuite())
    #expect(store.isAwake)
    #expect(store.toggle() == .sleep) // going to sleep files a sleep report
    #expect(!store.isAwake)
    #expect(store.toggle() == .wake)  // waking files a wake report
    #expect(store.isAwake)
}

@Test func awakeStatePersists() {
    let defaults = freshSuite()
    _ = AwakeStore(defaults: defaults).toggle()
    #expect(!AwakeStore(defaults: defaults).isAwake)
}

@Test func appLockPolicyNeverLocksWhenDisabled() {
    let now = Date()
    #expect(!AppLockPolicy.shouldLock(enabled: false, backgroundedAt: now.addingTimeInterval(-1000), now: now))
    #expect(!AppLockPolicy.shouldLock(enabled: false, backgroundedAt: nil, now: now))
}

@Test func appLockPolicyNeverLocksWithoutBackgroundedAt() {
    #expect(!AppLockPolicy.shouldLock(enabled: true, backgroundedAt: nil, now: Date()))
}

@Test func appLockPolicyStaysUnlockedWithinGrace() {
    let now = Date()
    let backgroundedAt = now.addingTimeInterval(-59)
    #expect(!AppLockPolicy.shouldLock(enabled: true, backgroundedAt: backgroundedAt, now: now))
}

@Test func appLockPolicyLocksAfterGrace() {
    let now = Date()
    let backgroundedAt = now.addingTimeInterval(-61)
    #expect(AppLockPolicy.shouldLock(enabled: true, backgroundedAt: backgroundedAt, now: now))
}

@Test func spotlightIndexingAlwaysAllowedWhenLockDisabled() {
    // With app lock off, the while-locked opt-in is irrelevant.
    #expect(AppLockPolicy.allowsSpotlightIndexing(lockEnabled: false, spotlightWhileLockedEnabled: false))
    #expect(AppLockPolicy.allowsSpotlightIndexing(lockEnabled: false, spotlightWhileLockedEnabled: true))
}

@Test func spotlightIndexingBlockedByLockWithoutOptIn() {
    // Default posture: enabling app lock stops Spotlight indexing.
    #expect(!AppLockPolicy.allowsSpotlightIndexing(lockEnabled: true, spotlightWhileLockedEnabled: false))
}

@Test func spotlightIndexingAllowedWhileLockedWithOptIn() {
    #expect(AppLockPolicy.allowsSpotlightIndexing(lockEnabled: true, spotlightWhileLockedEnabled: true))
}

@Test func appLockPolicyAtExactlyGraceDoesNotLock() {
    // Documented choice: elapsed time exactly equal to the grace interval does
    // NOT lock — only strictly-greater-than-grace elapsed time locks. This
    // matches the original `> backgroundGraceInterval` behavior being replaced.
    let now = Date()
    let backgroundedAt = now.addingTimeInterval(-60)
    #expect(!AppLockPolicy.shouldLock(enabled: true, backgroundedAt: backgroundedAt, now: now))
}
