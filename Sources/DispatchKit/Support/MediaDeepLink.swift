import Foundation

/// Pure resolver from a captured `MediaSample` to the best "open in the
/// source app" URL for the report-detail row. Returns nil when no sensible
/// link exists — the row then renders plain.
///
/// Spotify forms follow the official iOS content-linking guide
/// (https://developer.spotify.com/documentation/ios/tutorials/content-linking):
/// - App installed (caller checks `canOpenURL("spotify:")`, which requires
///   `spotify` in `LSApplicationQueriesSchemes` — present in App/Info.plist):
///   open the `spotify:` URI captured from the App Remote player state.
/// - Not installed: the `https://open.spotify.com/<type>/<id>` web form, with
///   the guide's `utm_campaign=<bundle id>` attribution parameter appended.
///   (The guide also asks integrations to respect Spotify branding when
///   showing a "listen on Spotify" affordance — the detail row uses a neutral
///   link affordance, no Spotify marks.)
/// - No URI: a search deep link built from title + artist (`spotify:search:…`
///   natively, `open.spotify.com/search/…` on the web).
///
/// Apple Music uses `https://music.apple.com` universal links — they open the
/// Music app directly when installed and degrade to the web when not, so no
/// scheme check is needed: `/song/<storeID>` when the store ID was captured,
/// `/search?term=…` otherwise.
///
/// Old reports (nil identifiers) get the search fallback — but ONLY when the
/// source service is known; unknown future sources and the other-audio floor
/// (no metadata at all) resolve to nil.
public enum MediaDeepLink {
    /// utm_campaign attribution value per the Spotify content-linking guide.
    static let attributionCampaign = "io.robbie.Dispatch"

    public static func url(for sample: MediaSample, spotifyAppInstalled: Bool) -> URL? {
        switch sample.sourceType {
        case .spotify:
            return spotifyURL(for: sample, appInstalled: spotifyAppInstalled)
        case .appleMusic:
            return appleMusicURL(for: sample)
        case .otherAudio, nil:
            return nil
        }
    }

    // MARK: - Spotify

    private static func spotifyURL(for sample: MediaSample, appInstalled: Bool) -> URL? {
        // "spotify:<type>:<id>" — tolerate any content type (track, episode…).
        if let uri = sample.spotifyTrackURI {
            let parts = uri.split(separator: ":").map(String.init)
            if parts.count == 3, parts[0] == "spotify" {
                if appInstalled { return URL(string: uri) }
                return URL(string:
                    "https://open.spotify.com/\(parts[1])/\(parts[2])?utm_campaign=\(attributionCampaign)")
            }
            // Malformed/unexpected URI shape: fall through to search.
        }
        guard let query = searchQuery(for: sample) else { return nil }
        if appInstalled { return URL(string: "spotify:search:\(query)") }
        return URL(string: "https://open.spotify.com/search/\(query)?utm_campaign=\(attributionCampaign)")
    }

    // MARK: - Apple Music

    private static func appleMusicURL(for sample: MediaSample) -> URL? {
        if let storeID = sample.appleMusicStoreID {
            return URL(string: "https://music.apple.com/song/\(storeID)")
        }
        guard let query = searchQuery(for: sample) else { return nil }
        return URL(string: "https://music.apple.com/search?term=\(query)")
    }

    // MARK: - Search fallback

    /// Percent-encoded "title artist" query; nil when there's nothing to
    /// search for (no metadata → no link).
    private static func searchQuery(for sample: MediaSample) -> String? {
        let terms = [sample.title, sample.artist]
            .compactMap(\.self)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !terms.isEmpty else { return nil }
        // Query must survive inside both a path segment and a query value:
        // encode everything outside unreserved characters (spaces → %20).
        return terms.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~")))
    }
}
