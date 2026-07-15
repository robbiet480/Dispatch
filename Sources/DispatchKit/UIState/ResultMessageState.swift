import Foundation

/// A one-shot result message (export/import outcome) plus the scene that asked
/// for it.
///
/// The Mac renders its main window and its Settings window as separate scenes
/// that BOTH observe the single export controller. A bare `isShowingMessage`
/// boolean therefore lit up every scene bound to it — export a file from
/// Settings and the confirmation appeared in the Settings window and the main
/// window at once. Recording the origin, and letting each scene ask "is this
/// mine?", keeps the alert in exactly one place.
public struct ResultMessageState: Sendable, Equatable {
    /// The scene a message belongs to.
    public enum Scene: Sendable, Hashable {
        /// The main window — File-menu import/export lands here.
        case primary
        /// The Settings window's Data pane.
        case settings
    }

    public private(set) var text: String?
    public private(set) var origin: Scene = .primary
    /// Whether a message is currently up. `dismiss()` (or the SwiftUI binding
    /// setting false) clears it, which drops it in every scene at once.
    public private(set) var isPresented = false

    public init() {}

    /// Records a result message and the scene that produced it.
    public mutating func present(_ text: String, from origin: Scene) {
        self.text = text
        self.origin = origin
        isPresented = true
    }

    /// True only for the scene that asked — so exactly one window presents.
    public func isPresented(in scene: Scene) -> Bool {
        isPresented && origin == scene
    }

    public mutating func dismiss() {
        isPresented = false
    }
}
