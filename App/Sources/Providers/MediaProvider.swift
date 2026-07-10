import AVFAudio
import DispatchKit
import Foundation
import MediaPlayer

/// Spotify seam (plan 26): Task 4 ships the always-nil stub; Task 5's App
/// Remote reader conforms. Any failure returning nil DEGRADES to the next
/// chain level — the reader must never throw past this boundary.
protocol SpotifyNowPlayingReading: Sendable {
    func currentSample() async -> MediaSample?
}

struct NoSpotify: SpotifyNowPlayingReading {
    func currentSample() async -> MediaSample? { nil }
}

/// Picks the media reader for the current launch. Returns the real Spotify
/// App Remote reader only when the user has connected Spotify (token stored)
/// and we're not in a test environment; otherwise the always-nil stub.
enum SpotifyReaderFactory {
    static func current() -> any SpotifyNowPlayingReading {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("--mock-sensors"), !arguments.contains("--ui-testing"),
              SpotifyConfig.isConfigured, SpotifyTokenStore().load() != nil
        else { return NoSpotify() }
        return SpotifyNowPlayingReader()
    }
}

/// Captures what's audibly playing at report time via the kit's
/// degrade-through chain: Apple Music → Spotify → other-audio floor.
/// nil from every level = nothing audible → `.unavailable("Nothing playing")`
/// so `report.media` stays nil and the checklist hint reads honestly.
struct MediaProvider: SensorProvider {
    let kind = SensorKind.media
    let spotify: any SpotifyNowPlayingReading

    func capture() async throws -> SensorPayload {
        let sample = await MediaChain.resolve(
            music: await Self.appleMusicSample(),
            spotify: { await spotify.currentSample() },
            otherAudioPlaying: { AVAudioSession.sharedInstance().isOtherAudioPlaying }
        )
        // nil = nothing audible (documented in MediaChain): surfaces as
        // .unavailable("Nothing playing") via the coordinator's
        // String(describing:) error mapping (ProviderError is
        // CustomStringConvertible).
        guard let sample else { throw ProviderError("Nothing playing") }
        return .media(sample)
    }

    /// Level 1: the system Music player. Only when the media library is
    /// authorized AND actually playing a known item. MPMusicPlayerController
    /// is main-thread-affine (verified: the Media Player framework documents
    /// main-thread use and systemMusicPlayer posts UIKit-tied notifications;
    /// hence @MainActor).
    @MainActor
    static func appleMusicSample() -> MediaSample? {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return nil }
        let player = MPMusicPlayerController.systemMusicPlayer
        guard player.playbackState == .playing, let item = player.nowPlayingItem else { return nil }
        return MediaSample(source: .appleMusic, title: item.title, artist: item.artist,
                           album: item.albumTitle, playbackState: .playing)
    }
}
