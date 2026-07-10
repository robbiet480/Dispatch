import DispatchKit
import Foundation
import os
import SpotifyiOS
import SwiftUI

private let spotifyLog = Logger(subsystem: "io.robbie.Dispatch", category: "spotify")

/// Owns the Spotify connect/disconnect lifecycle (plan 26). "Connected" means
/// an App Remote access token is stored in the Keychain — the reader makes a
/// short-lived App Remote connection per capture, so there is no long-lived
/// socket to manage here.
///
/// SDK API names verified against SpotifyiOS v5.0.1 headers (2026-07-10):
/// `SPTConfiguration(clientID:redirectURL:)`, instance method
/// `authorizeAndPlayURI(_:completionHandler:)` (wakes Spotify, runs auth,
/// returns via the redirect URI), instance method
/// `authorizationParameters(from:)` returning a dictionary keyed by
/// `SPTAppRemoteAccessTokenKey`.
@MainActor
@Observable
final class SpotifyController {
    private(set) var isConnected: Bool
    let isTestEnvironment: Bool

    /// Kept alive across connect() → handleCallback(url:) — the parameter
    /// extraction is an instance method on SPTAppRemote.
    private var appRemote: SPTAppRemote?

    init(isTestEnvironment: Bool? = nil) {
        let resolvedTestEnvironment = isTestEnvironment ?? {
            let arguments = ProcessInfo.processInfo.arguments
            return arguments.contains("--mock-sensors") || arguments.contains("--ui-testing")
        }()
        self.isTestEnvironment = resolvedTestEnvironment
        // Test env: no Keychain reads, no SDK traffic — settings render a
        // deterministic "Not connected".
        self.isConnected = resolvedTestEnvironment ? false : SpotifyTokenStore().load() != nil
    }

    var isConfigured: Bool { SpotifyConfig.isConfigured }

    /// True when the Spotify app is installed (App Remote requires it).
    /// canOpenURL needs `LSApplicationQueriesSchemes` = ["spotify"] (set).
    var isSpotifyAppInstalled: Bool {
        guard !isTestEnvironment, let url = URL(string: "spotify:") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Kicks off authorization: wakes the Spotify app, which shows its auth
    /// UI and calls back into Dispatch via the `dispatch-spotify` scheme.
    /// The empty play URI means "resume whatever was playing" — we never
    /// start new playback.
    func connect() {
        guard !isTestEnvironment, let config = SpotifyConfig.load() else { return }
        let remote = makeAppRemote(config: config)
        appRemote = remote
        remote.authorizeAndPlayURI("", completionHandler: nil)
    }

    /// Routes the `dispatch-spotify://callback` URL: extracts the access
    /// token and stores it in the Keychain. Failure (user denied, malformed
    /// URL) just logs — the settings screen keeps showing "Not connected".
    func handleCallback(url: URL) {
        guard !isTestEnvironment, let config = SpotifyConfig.load() else { return }
        // Cold-start callback (app relaunched by the redirect): connect()'s
        // instance is gone — build a fresh one to parse the parameters.
        let remote = appRemote ?? makeAppRemote(config: config)
        appRemote = remote
        let parameters = remote.authorizationParameters(from: url)
        if let token = parameters?[SPTAppRemoteAccessTokenKey] {
            // A failed Keychain persist must NOT claim a connected state
            // (PR #25 review) — the reader would find no token next capture.
            if SpotifyTokenStore().save(token) {
                isConnected = true
                spotifyLog.info("spotify connected — token stored")
            } else {
                spotifyLog.error("spotify auth succeeded but keychain save failed — staying disconnected")
            }
        } else {
            let description = parameters?[SPTAppRemoteErrorDescriptionKey] ?? "no token in callback"
            spotifyLog.error("spotify auth callback failed: \(description, privacy: .public)")
        }
    }

    func disconnect() {
        SpotifyTokenStore().delete()
        isConnected = false
        spotifyLog.info("spotify disconnected — token deleted")
    }

    /// Delete All Data hook (PR #25 review; mirrors
    /// `WebhookManager.clearSecretForDataWipe`): the token is a credential in
    /// the Keychain, outside both defaults suites — and Keychain items even
    /// survive app deletion — so the wipe path must clear it explicitly and
    /// reset the published connection state. Delete is idempotent
    /// (kit-tested), safe on installs that never connected.
    func clearCredentialForDataWipe() {
        disconnect()
    }

    private func makeAppRemote(config: SpotifyConfig) -> SPTAppRemote {
        let configuration = SPTConfiguration(clientID: config.clientID, redirectURL: config.redirectURL)
        return SPTAppRemote(configuration: configuration, logLevel: .none)
    }
}
