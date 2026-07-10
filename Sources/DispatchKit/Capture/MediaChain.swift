import Foundation

/// Degrade-through media resolution (plan 26): Apple Music → Spotify →
/// other-audio floor. Each level falling through is NORMAL, not an error —
/// a Spotify read failure or timeout still reaches the floor. Returns nil
/// ONLY when nothing is audible (documented choice: nil = silence, payloads
/// stay lean).
public enum MediaChain {
    public static func resolve(
        music: MediaSample?,
        spotify: () async -> MediaSample?,
        otherAudioPlaying: () -> Bool
    ) async -> MediaSample? {
        if let music { return music }
        if let spotifySample = await spotify() { return spotifySample }
        return otherAudioPlaying() ? MediaSample(source: .otherAudio) : nil
    }
}
