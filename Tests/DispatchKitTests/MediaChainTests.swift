import Foundation
import Testing
@testable import DispatchKit

/// The degrade-through contract (plan 26): Apple Music → Spotify →
/// other-audio floor; nil only when nothing is audible.

@Test func musicSampleWinsAndShortCircuitsSpotify() async {
    let music = MediaSample(source: .appleMusic, title: "Song")
    let spotifyAsked = OSAllocatedFlag()
    let resolved = await MediaChain.resolve(
        music: music,
        spotify: { spotifyAsked.set(); return nil },
        otherAudioPlaying: { true })
    #expect(resolved == music)
    #expect(!spotifyAsked.isSet)
}

@Test func spotifySampleUsedWhenMusicSilent() async {
    let spotify = MediaSample(source: .spotify, title: "Song", artist: "Artist")
    let resolved = await MediaChain.resolve(
        music: nil,
        spotify: { spotify },
        otherAudioPlaying: { false })
    #expect(resolved == spotify)
}

/// The explicit Spotify-timeout→otherAudio test: a Spotify read failure or
/// budget overrun (nil) still reaches the floor.
@Test func spotifyFailureDegradesToOtherAudioFloor() async throws {
    let resolved = await MediaChain.resolve(
        music: nil,
        spotify: { nil }, // simulates timeout/connection failure
        otherAudioPlaying: { true })
    let sample = try #require(resolved)
    #expect(sample.sourceType == .otherAudio)
    #expect(sample.playbackStateType == .playing)
}

@Test func silenceResolvesToNil() async {
    let resolved = await MediaChain.resolve(
        music: nil,
        spotify: { nil },
        otherAudioPlaying: { false })
    #expect(resolved == nil)
}

/// Tiny non-Sendable-free flag for asserting a closure never ran.
private final class OSAllocatedFlag: @unchecked Sendable {
    private var value = false
    func set() { value = true }
    var isSet: Bool { value }
}
