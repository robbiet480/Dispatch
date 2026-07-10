import Foundation

/// Spotify client configuration (plan 26), read from the app's Info.plist
/// (`SpotifyClientID` / `SpotifyRedirectURI` — config, not code constants).
/// nil-safe by design: a missing key or the unedited placeholder renders
/// SpotifySettingsView's connect button disabled with an explanatory footnote,
/// never crashes.
struct SpotifyConfig: Sendable {
    let clientID: String
    let redirectURL: URL

    static let placeholderClientID = "SPOTIFY_CLIENT_ID_PLACEHOLDER"

    static func load(bundle: Bundle = .main) -> SpotifyConfig? {
        guard let clientID = bundle.object(forInfoDictionaryKey: "SpotifyClientID") as? String,
              !clientID.isEmpty,
              clientID != placeholderClientID,
              let redirectString = bundle.object(forInfoDictionaryKey: "SpotifyRedirectURI") as? String,
              let redirectURL = URL(string: redirectString)
        else { return nil }
        return SpotifyConfig(clientID: clientID, redirectURL: redirectURL)
    }

    static var isConfigured: Bool { load() != nil }
}
