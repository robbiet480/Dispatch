import Foundation
import Testing
@testable import DispatchKit

/// The wipe-path contract (PR #25 review): delete is idempotent — a missing
/// item is a no-op, so Delete All Data can call it unconditionally, including
/// on installs that never connected Spotify.
@Test func spotifyTokenStoreDeleteIsIdempotent() {
    // Unique per-run service name keeps the test off any real item.
    let store = SpotifyTokenStore(service: "io.robbie.Dispatch.tests.spotify-\(UUID().uuidString)")

    // Never-connected install: delete on a missing item must not trap.
    store.delete()
    #expect(store.load() == nil)

    // Environments without a usable keychain (some CI sandboxes) can't
    // exercise the save path — the idempotent-delete-on-missing assertions
    // above still ran, so bail rather than flake.
    guard store.save("token-123") else { return }
    #expect(store.load() == "token-123")

    // Overwrite (SecItemUpdate branch) keeps a single readable value.
    #expect(store.save("token-456"))
    #expect(store.load() == "token-456")

    store.delete()
    #expect(store.load() == nil)
    store.delete() // second delete: still a no-op
    #expect(store.load() == nil)
}
