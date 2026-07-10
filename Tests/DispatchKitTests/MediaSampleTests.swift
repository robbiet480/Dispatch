import Foundation
import Testing
@testable import DispatchKit

@Test func mediaSampleWireKeysAreCleanNames() throws {
    let sample = MediaSample(source: .appleMusic, title: "Song", artist: "Artist",
                             album: "Album", playbackState: .playing)
    let data = try JSONEncoder().encode(sample)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"source\""))
    #expect(json.contains("\"playbackState\""))
    #expect(!json.contains("sourceType"))
    #expect(!json.contains("playbackStateType"))
}

/// Unknown source/playbackState raws import leniently and re-export untouched
/// (the ConnectionType raw-storage precedent).
@Test func mediaSampleUnknownRawsAreLenient() throws {
    let wire = Data(#"{"source": "vinyl", "playbackState": 9, "title": "Needle Drop"}"#.utf8)
    let decoded = try JSONDecoder().decode(MediaSample.self, from: wire)
    #expect(decoded.sourceType == nil)
    #expect(decoded.source == "vinyl")
    #expect(decoded.playbackStateType == nil)
    #expect(decoded.playbackState == 9)

    let reencoded = try JSONDecoder().decode(
        MediaSample.self, from: JSONEncoder().encode(decoded))
    #expect(reencoded.source == "vinyl")
    #expect(reencoded.playbackState == 9)
    #expect(reencoded.title == "Needle Drop")
}

@Test func mediaSampleDetailLineFormats() {
    let full = MediaSample(source: .spotify, title: "Song", artist: "Artist")
    #expect(full.detailLine == "Song — Artist, via Spotify")

    let titleOnly = MediaSample(source: .appleMusic, title: "Song")
    #expect(titleOnly.detailLine == "Song, via Apple Music")

    let floor = MediaSample(source: .otherAudio)
    #expect(floor.detailLine == "Audio playing")
}

@Test func mediaSourceDisplayNames() {
    #expect(MediaSource.appleMusic.displayName == "Apple Music")
    #expect(MediaSource.spotify.displayName == "Spotify")
    #expect(MediaSource.otherAudio.displayName == "Other audio")
}
