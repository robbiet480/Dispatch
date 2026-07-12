import DispatchKit
import SwiftUI

/// Spotify connect/disconnect (plan 26). Reachable from Settings → Sensors →
/// MEDIA. Connection here means "Dispatch may read the currently playing
/// track at report time" — nothing else.
struct SpotifySettingsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(SpotifyController.self) private var spotify

    private var theme: Theme { themeStore.theme }

    private var statusText: String {
        if !spotify.isConfigured { return "Not configured" }
        if spotify.isConnected { return "Connected" }
        if !spotify.isSpotifyAppInstalled { return "Spotify app not installed" }
        return "Not connected"
    }

    var body: some View {
        ZStack {
            Color.themeBackground(theme)
                .ignoresSafeArea()

            List {
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(statusText)
                            .opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("spotify-status")

                    if spotify.isConnected {
                        Button("Disconnect Spotify") {
                            spotify.disconnect()
                        }
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("spotify-disconnect")
                    } else {
                        Button("Connect Spotify") {
                            spotify.connect()
                        }
                        .foregroundStyle(.white)
                        .disabled(!spotify.isConfigured)
                        .accessibilityIdentifier("spotify-connect")
                    }
                } header: {
                    Text("SPOTIFY")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.8))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if !spotify.isConfigured {
                            Text("Spotify isn't configured in this build: the app needs a Spotify client ID (SpotifyClientID in Info.plist) from the Spotify developer dashboard.")
                        } else if !spotify.isSpotifyAppInstalled, !spotify.isConnected {
                            Text("Install the Spotify app to connect — Dispatch reads the now-playing track through it.")
                        }
                        Text("Dispatch reads only the currently playing track (song, artist, album) when you file a report. It never controls playback or reads your library.")
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .listRowBackground(Color.clear)
                }
                .listRowBackground(Color.white.opacity(0.12))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Spotify")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
