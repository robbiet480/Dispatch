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
