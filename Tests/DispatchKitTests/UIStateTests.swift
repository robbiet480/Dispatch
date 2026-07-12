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

// MARK: - Source tracking (plan 39)

// (d) An automatic source flips state and records the source, but does NOT
// stamp the manual-cooldown timestamp — only manual changes outrank
// automation.
@Test func setAwakeFromFocusFilterRecordsSourceButNotManualStamp() {
    let store = AwakeStore(defaults: freshSuite())
    #expect(store.isAwake)
    store.setAwake(false, source: .focusFilter)
    #expect(!store.isAwake)
    #expect(store.lastChangeSource == .focusFilter)
    #expect(store.lastManualChangeAt == nil)
}

// (e) toggle() records .manual and stamps the cooldown timestamp.
@Test func toggleRecordsManualSourceAndStampsTimestamp() {
    let store = AwakeStore(defaults: freshSuite())
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    #expect(store.toggle(now: now) == .sleep)
    #expect(!store.isAwake)
    #expect(store.lastChangeSource == .manual)
    #expect(store.lastManualChangeAt == now)
}

// (f) Persistence — a second store on the same suite reads back the recorded
// source and manual timestamp.
@Test func sourceAndManualStampPersistAcrossStores() {
    let defaults = freshSuite()
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    AwakeStore(defaults: defaults).setAwake(false, source: .manual, now: now)
    let reloaded = AwakeStore(defaults: defaults)
    #expect(reloaded.lastChangeSource == .manual)
    #expect(reloaded.lastManualChangeAt == now)
}

// (g) The plain isAwake setter stays source-less — existing callers (tests,
// previews) record nothing.
@Test func plainIsAwakeSetterRecordsNoSource() {
    let store = AwakeStore(defaults: freshSuite())
    store.isAwake = false
    #expect(!store.isAwake)
    #expect(store.lastChangeSource == nil)
    #expect(store.lastManualChangeAt == nil)
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
