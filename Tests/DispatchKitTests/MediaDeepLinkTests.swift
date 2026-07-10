import Foundation
import Testing
@testable import DispatchKit

// MARK: - Spotify

@Test func spotifyTrackURIOpensNativelyWhenAppInstalled() throws {
    let sample = MediaSample(source: .spotify, title: "Song 2", artist: "Blur",
                             spotifyTrackURI: "spotify:track:1AhDOtG9vPSOmsWgNW0BEY")
    let url = try #require(MediaDeepLink.url(for: sample, spotifyAppInstalled: true))
    #expect(url.absoluteString == "spotify:track:1AhDOtG9vPSOmsWgNW0BEY")
}

@Test func spotifyTrackURIFallsBackToWebLinkWithAttribution() throws {
    let sample = MediaSample(source: .spotify, title: "Song 2", artist: "Blur",
                             spotifyTrackURI: "spotify:track:1AhDOtG9vPSOmsWgNW0BEY")
    let url = try #require(MediaDeepLink.url(for: sample, spotifyAppInstalled: false))
    // Web-link fallback + utm_campaign attribution per the content-linking guide.
    #expect(url.absoluteString
        == "https://open.spotify.com/track/1AhDOtG9vPSOmsWgNW0BEY?utm_campaign=io.robbie.Dispatch")
}

@Test func spotifyWithoutURIFallsBackToSearch() throws {
    let sample = MediaSample(source: .spotify, title: "Song 2", artist: "Blur")
    let native = try #require(MediaDeepLink.url(for: sample, spotifyAppInstalled: true))
    #expect(native.absoluteString == "spotify:search:Song%202%20Blur")
    let web = try #require(MediaDeepLink.url(for: sample, spotifyAppInstalled: false))
    #expect(web.absoluteString
        == "https://open.spotify.com/search/Song%202%20Blur?utm_campaign=io.robbie.Dispatch")
}

@Test func spotifyNonTrackURIStillLinksOnTheWeb() throws {
    // Podcast episodes etc.: "spotify:<type>:<id>" maps to open.spotify.com/<type>/<id>.
    let sample = MediaSample(source: .spotify, title: "Some Episode",
                             spotifyTrackURI: "spotify:episode:abc123")
    let web = try #require(MediaDeepLink.url(for: sample, spotifyAppInstalled: false))
    #expect(web.absoluteString == "https://open.spotify.com/episode/abc123?utm_campaign=io.robbie.Dispatch")
}

@Test func malformedSpotifyURIDegradesToSearch() throws {
    let sample = MediaSample(source: .spotify, title: "Song", artist: "Artist",
                             spotifyTrackURI: "https://not-a-spotify-uri")
    let url = try #require(MediaDeepLink.url(for: sample, spotifyAppInstalled: true))
    #expect(url.absoluteString == "spotify:search:Song%20Artist")
}

// MARK: - Apple Music

@Test func appleMusicStoreIDLinksToSong() throws {
    let sample = MediaSample(source: .appleMusic, title: "Song", artist: "Artist",
                             appleMusicStoreID: "1440857781")
    let url = try #require(MediaDeepLink.url(for: sample, spotifyAppInstalled: false))
    #expect(url.absoluteString == "https://music.apple.com/song/1440857781")
}

@Test func appleMusicWithoutStoreIDFallsBackToSearch() throws {
    let sample = MediaSample(source: .appleMusic, title: "Song", artist: "Artist")
    let url = try #require(MediaDeepLink.url(for: sample, spotifyAppInstalled: true))
    #expect(url.absoluteString == "https://music.apple.com/search?term=Song%20Artist")
}

// MARK: - No link

@Test func otherAudioAndUnknownSourcesHaveNoLink() {
    #expect(MediaDeepLink.url(for: MediaSample(source: .otherAudio), spotifyAppInstalled: true) == nil)

    var unknown = MediaSample(source: .spotify, title: "Song")
    unknown.source = "vinyl" // future source: we can't pick a service to search
    #expect(MediaDeepLink.url(for: unknown, spotifyAppInstalled: true) == nil)
}

@Test func noMetadataAndNoIDMeansNoLink() {
    // A titleless sample with no identifier has nothing to search for.
    let sample = MediaSample(source: .spotify)
    #expect(MediaDeepLink.url(for: sample, spotifyAppInstalled: true) == nil)
}

// MARK: - Wire format

/// The identifier fields are additive: encoded only when present, tolerated
/// when absent, preserved through re-encode (house v2 leniency rules).
@Test func mediaIdentifiersAreAdditiveOnTheWire() throws {
    let bare = MediaSample(source: .appleMusic, title: "Song")
    let bareJSON = try #require(String(data: JSONEncoder().encode(bare), encoding: .utf8))
    #expect(!bareJSON.contains("spotifyTrackURI"))
    #expect(!bareJSON.contains("appleMusicStoreID"))

    let full = MediaSample(source: .spotify, title: "Song",
                           spotifyTrackURI: "spotify:track:x", appleMusicStoreID: "42")
    let decoded = try JSONDecoder().decode(MediaSample.self, from: JSONEncoder().encode(full))
    #expect(decoded.spotifyTrackURI == "spotify:track:x")
    #expect(decoded.appleMusicStoreID == "42")

    // Pre-deep-link payloads (no identifier keys) decode with nils.
    let legacy = Data(#"{"source": "appleMusic", "title": "Old Song", "playbackState": 1}"#.utf8)
    let old = try JSONDecoder().decode(MediaSample.self, from: legacy)
    #expect(old.spotifyTrackURI == nil)
    #expect(old.appleMusicStoreID == nil)
}
