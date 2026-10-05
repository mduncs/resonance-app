import SwiftUI

private struct AlbumCardArtworkAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct AlbumCardServerIdentity: Equatable {
    let id: UUID?
    let url: URL?
    let username: String?

    init(server: Server?) {
        id = server?.id
        url = server?.url
        username = server?.username
    }
}

@MainActor
private func playCardAlbum(_ album: Album, using appState: AppState) async {
    let serverIdentity = AlbumCardServerIdentity(server: appState.activeServer)

    do {
        let songs = try await appState.playableAlbumSongs(for: album)
        guard !Task.isCancelled,
              serverIdentity == AlbumCardServerIdentity(server: appState.activeServer) else { return }
        await appState.playbackManager.play(songs: songs)
    } catch is CancellationError {
        // A server reconfiguration invalidates its in-flight album fetch.
    } catch {
        guard !Task.isCancelled,
              serverIdentity == AlbumCardServerIdentity(server: appState.activeServer) else { return }
        appState.showFeedback(
            message: "Couldn't play \(album.name)",
            detail: error.localizedDescription,
            style: .error,
            systemImage: "exclamationmark.triangle"
        )
    }
}

/// The play control is kept outside the card's primary Button/NavigationLink.
/// This matters for cards that open details: nested SwiftUI controls can route
/// both the play and the open action from one pointer click.
struct AlbumCardActionSurface<Content: View>: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let album: Album
    var onPlay: (() -> Void)? = nil
    var playGlyphSize: CGFloat = 48
    let content: (@escaping (Bool) -> Void) -> Content

    @State private var isArtworkHovered = false

    init(
        album: Album,
        onPlay: (() -> Void)? = nil,
        playGlyphSize: CGFloat = 48,
        @ViewBuilder content: @escaping (@escaping (Bool) -> Void) -> Content
    ) {
        self.album = album
        self.onPlay = onPlay
        self.playGlyphSize = playGlyphSize
        self.content = content
    }

    var body: some View {
        ZStack {
            content { isArtworkHovered = $0 }
        }
        .contentShape(Rectangle())
        .overlayPreferenceValue(AlbumCardArtworkAnchorKey.self) { artworkAnchor in
            GeometryReader { proxy in
                if isArtworkHovered, let artworkAnchor {
                    let artworkFrame = proxy[artworkAnchor]
                    AlbumCardPlayButton(album: album, glyphSize: playGlyphSize, action: activatePlay)
                        .position(
                            x: artworkFrame.maxX - (playGlyphSize + 16) / 2,
                            y: artworkFrame.maxY - (playGlyphSize + 16) / 2
                        )
                        .transition(reduceMotion ? .identity : .scale.combined(with: .opacity))
                }
            }
            .allowsHitTesting(isArtworkHovered)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isArtworkHovered)
    }

    private func activatePlay() {
        if let onPlay {
            onPlay()
            return
        }

        Task {
            await playCardAlbum(album, using: appState)
        }
    }
}

private struct AlbumCardPlayButton: View {
    let album: Album
    var glyphSize: CGFloat = 48
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: glyphSize, height: glyphSize)
                .background(.black.opacity(0.6))
                .clipShape(Circle())
                // Preserve the visible glyph/circle while making its full
                // padded footprint part of the Button's hit target.
                .frame(width: glyphSize + 16, height: glyphSize + 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Play \(album.name)")
        .accessibilityLabel("Play \(album.name) by \(album.artist)")
    }
}

struct AlbumCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let album: Album
    var titleLineLimit: Int = 1
    // Opt-in library geometry; Search and other callers retain their 200pt card.
    var libraryCellWidth: CGFloat? = nil
    var artworkSize: CGFloat = 200
    var subtitleOverride: String? = nil
    var libraryTypography = false
    var showsHoverPlayButton = true
    var onArtworkHoverChange: ((Bool) -> Void)? = nil

    private var artworkSide: CGFloat { libraryCellWidth.map { $0 - 10 } ?? artworkSize }
    private var subtitle: String { subtitleOverride ?? album.artist }
    private var usesLibraryStyle: Bool { libraryTypography || libraryCellWidth != nil }
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: libraryCellWidth == nil ? 8 : 4) {
            ZStack(alignment: .bottomTrailing) {
                EnvironmentAlbumArtView(coverArtId: album.coverArt, size: .large, flexible: libraryCellWidth != nil || artworkSize != 200)
                    .frame(width: artworkSide, height: artworkSide)
                    .anchorPreference(key: AlbumCardArtworkAnchorKey.self, value: .bounds) { $0 }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    // Library grid art has a quiet edge, not the hero shadow.
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.black.opacity(0.1), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(usesLibraryStyle ? 0 : 0.15), radius: 8, x: 0, y: 4)

                // Hover play button
                if isHovered && showsHoverPlayButton {
                    AlbumCardPlayButton(album: album) {
                        Task { await playCardAlbum(album, using: appState) }
                    }
                    .transition(reduceMotion ? .identity : .scale.combined(with: .opacity))
                }
            }
            .scaleEffect(!usesLibraryStyle && isHovered ? 1.01 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
            .onHover {
                isHovered = $0
                onArtworkHoverChange?($0)
            }

            VStack(alignment: .leading, spacing: usesLibraryStyle ? 0 : 2) {
                Text(album.name)
                    .font(usesLibraryStyle ? .system(size: 13) : .subheadline)
                    .fontWeight(usesLibraryStyle ? .regular : .semibold)
                    .lineLimit(titleLineLimit)
                    .truncationMode(.tail)
                    .help(album.name)

                Text(subtitle)
                    .font(usesLibraryStyle ? .system(size: 13) : .subheadline)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(subtitle)
            }
            .padding(.horizontal, 2)
        }
        // Keep other consumers' geometry and typography unchanged.
        .frame(width: artworkSide, alignment: .leading)
        .padding(libraryCellWidth == nil ? 0 : 5)
        .frame(width: libraryCellWidth ?? artworkSize,
               height: libraryCellWidth.map { $0 + 56 },
               alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(albumAccessibilityLabel)
        .accessibilityHint("Double tap to view album")
    }

    private var albumAccessibilityLabel: String {
        var label = "Album: \(album.name) by \(album.artist)"
        if let year = album.year {
            label += ", \(year)"
        }
        return label
    }

}

struct AlbumCardLarge: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let album: Album
    var showsHoverPlayButton = true
    var onArtworkHoverChange: ((Bool) -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                EnvironmentAlbumArtView(coverArtId: album.coverArt, size: .large)
                    .frame(width: 200, height: 200)
                    .anchorPreference(key: AlbumCardArtworkAnchorKey.self, value: .bounds) { $0 }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)

                // Hover play button
                if isHovered && showsHoverPlayButton {
                    AlbumCardPlayButton(album: album, glyphSize: 44) {
                        Task { await playCardAlbum(album, using: appState) }
                    }
                    .transition(reduceMotion ? .identity : .scale.combined(with: .opacity))
                }
            }
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
            .onHover {
                isHovered = $0
                onArtworkHoverChange?($0)
            }

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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(albumAccessibilityLabel)
        .accessibilityHint("Double tap to view album")
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

}

#Preview {
    HStack(spacing: 20) {
        AlbumCard(album: .placeholder)
        AlbumCardLarge(album: .placeholder)
    }
    .padding()
    .environment(AppState())
}
