import DispatchKit
import Foundation
import SpotifyiOS

/// Level 2 of the media chain (plan 26): a short-lived App Remote
/// connect-read-disconnect per capture. EVERY failure mode — no token, no
/// config, connection failure (`didFailConnectionAttemptWithError`), stale
/// token, Spotify app missing, 5-second budget overrun — returns nil so
/// `MediaChain` degrades to the other-audio floor. Never throws, never hangs
/// past the budget (which sits inside the coordinator's 10s sensor timeout).
///
/// SDK claims verified against SpotifyiOS v5.0.1 headers (2026-07-10):
/// `connectionParameters.accessToken`, `connect()`/`disconnect()`, delegate
/// `appRemoteDidEstablishConnection` / `didFailConnectionAttemptWithError` /
/// `didDisconnectWithError`, `playerAPI?.getPlayerState(_:)` with
/// `SPTAppRemoteCallback = (Any?, Error?) -> Void`, and the state shape
/// `track.name` / `track.artist.name` / `track.album.name` / `isPaused`.
@MainActor
final class SpotifyNowPlayingReader: SpotifyNowPlayingReading {
    nonisolated init() {}

    func currentSample() async -> MediaSample? {
        guard let token = SpotifyTokenStore().load(), let config = SpotifyConfig.load() else { return nil }
        // One session object per read; nothing is reused across captures.
        return await SpotifyReadSession().read(token: token, config: config)
    }
}

/// One connect → getPlayerState → disconnect round-trip. MainActor-bound:
/// the App Remote is main-thread-affine (its delegate callbacks arrive on
/// the main thread — SDK demo/docs convention, asserted via assumeIsolated).
@MainActor
private final class SpotifyReadSession: NSObject, SPTAppRemoteDelegate {
    private var appRemote: SPTAppRemote?
    private var continuation: CheckedContinuation<MediaSample?, Never>?

    func read(token: String, config: SpotifyConfig) async -> MediaSample? {
        let configuration = SPTConfiguration(clientID: config.clientID, redirectURL: config.redirectURL)
        let remote = SPTAppRemote(configuration: configuration, logLevel: .none)
        remote.connectionParameters.accessToken = token
        remote.delegate = self
        appRemote = remote
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            remote.connect()
            // Internal 5s budget (inside the coordinator's 10s sensor
            // timeout): overrun = nil = degrade to the other-audio floor.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.finish(nil)
            }
        }
    }

    /// One-shot: disconnects and resumes exactly once, whichever of
    /// success/failure/timeout gets here first.
    private func finish(_ sample: MediaSample?) {
        guard let continuation else { return }
        self.continuation = nil
        appRemote?.delegate = nil
        appRemote?.disconnect()
        appRemote = nil
        continuation.resume(returning: sample)
    }

    private func handleConnected() {
        guard let playerAPI = appRemote?.playerAPI else {
            finish(nil)
            return
        }
        playerAPI.getPlayerState { [weak self] result, _ in
            // SDK callbacks arrive on the main thread (see class comment).
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let state = result as? SPTAppRemotePlayerState else {
                    self.finish(nil)
                    return
                }
                self.finish(MediaSample(
                    source: .spotify,
                    title: state.track.name,
                    artist: state.track.artist.name,
                    album: state.track.album.name,
                    playbackState: state.isPaused ? .paused : .playing
                ))
            }
        }
    }

    // MARK: SPTAppRemoteDelegate (nonisolated ObjC entry points; main thread)

    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        // Uses the session's own stored appRemote (same instance) rather than
        // the non-Sendable parameter, which can't cross into the actor.
        MainActor.assumeIsolated { handleConnected() }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        MainActor.assumeIsolated { finish(nil) }
    }
}
