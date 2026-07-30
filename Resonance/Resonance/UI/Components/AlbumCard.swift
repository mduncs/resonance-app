import SwiftUI

struct AlbumCard: View {
    @Environment(AppState.self) private var appState
    let album: Album
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                EnvironmentAlbumArtView(coverArtId: album.coverArt, size: .large)
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)

                // Hover play button
                if isHovered {
                    Button {
                        Task {
                            await playAlbum()
                        }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(album.name)

                Text(album.artist)
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(album.artist)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: 200)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(albumAccessibilityLabel)
        .accessibilityHint("Double tap to view album")
        .accessibilityAddTraits(.isButton)
    }

    private var albumAccessibilityLabel: String {
        var label = "Album: \(album.name) by \(album.artist)"
        if let year = album.year {
            label += ", \(year)"
        }
        return label
    }

    private func playAlbum() async {
        do {
            let songs = try await appState.playableAlbumSongs(for: album)
            await appState.playbackManager.play(songs: songs)
        } catch {
            print("Failed to play album: \(error)")
        }
    }
}

struct AlbumCardLarge: View {
    @Environment(AppState.self) private var appState
    let album: Album
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                EnvironmentAlbumArtView(coverArtId: album.coverArt, size: .large)
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)

                // Hover play button
                if isHovered {
                    Button {
                        Task {
                            await playAlbum()
                        }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .help(album.name)

                Text(album.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(album.artist)

            }
            .padding(.horizontal, 4)
        }
        .frame(width: 204)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(albumAccessibilityLabel)
        .accessibilityHint("Double tap to view album")
        .accessibilityAddTraits(.isButton)
    }

    private var albumAccessibilityLabel: String {
        var label = "Album: \(album.name) by \(album.artist)"
        if let year = album.year {
            label += ", \(year)"
        }
        if album.songCount > 0 {
            label += ", \(album.songCount) songs"
        }
        return label
    }

    private func playAlbum() async {
        do {
            let songs = try await appState.playableAlbumSongs(for: album)
            await appState.playbackManager.play(songs: songs)
        } catch {
            print("Failed to play album: \(error)")
        }
    }
}

#Preview {
    HStack(spacing: 20) {
        AlbumCard(album: .placeholder)
        AlbumCardLarge(album: .placeholder)
    }
    .padding()
    .environment(AppState())
}
