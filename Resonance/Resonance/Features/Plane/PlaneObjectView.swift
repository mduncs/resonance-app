import SwiftUI

/// The Object stratum: one album fills the frame — large art, admission/provenance
/// story, and track rows: art + metadata on the
/// left, a dense track list on the right.
struct PlaneObjectView: View {
    let album: Album?
    let songs: [Song]
    let isLoading: Bool
    let voiceName: String?
    let nowPlaying: Song?
    /// True when the album still sits in the Waiting Room (Salon projection).
    let isOnAudition: Bool
    /// Play the album from a given track index.
    let onPlay: (Int) -> Void
    /// Admit the album's songs to the library (only meaningful while auditioning).
    let onAdmit: () -> Void

    /// GI-B: the docked evidence rail toggled by ⌘I at near distances. Observed
    /// here so the Object stratum hosts the rail when it is the present stratum;
    /// the plane crossfade hides this copy at other distances.
    @State private var rail = PlaneEvidenceRailController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState
    /// GI-C: the album dossier's first sentence, shown as the header's one-line
    /// story. Clicking it opens the evidence rail (the full testimony, in place).
    @State private var story: String?

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let album {
                    content(album)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if rail.isOpen {
                Divider()
                PlaneEvidenceRail(subject: album.map(EvidenceSubject.album))
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { evidenceToggle }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: rail.isOpen)
        .task(id: album?.id) { loadStory() }
        .onReceive(NotificationCenter.default.publisher(for: .resonanceCurationDidChange)) { _ in
            loadStory()
        }
    }

    private func loadStory() {
        story = album.flatMap {
            DossierPreviewCache.shared.firstSentence(for: .album($0), appState: appState)
        }
    }

    /// Interim discoverability trigger (⌘I routes here via `ResonanceApp` when the
    /// plane is the active surface). A quiet affordance so the rail is reachable
    /// even before the near/far z-gating lands in `PlaneView`.
    private var evidenceToggle: some View {
        Button {
            rail.toggle()
        } label: {
            Image(systemName: rail.isOpen ? "sidebar.right" : "text.magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(rail.isOpen ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(16)
        .help(rail.isOpen ? "Hide evidence (⌘I)" : "Show evidence (⌘I)")
        .accessibilityLabel(rail.isOpen ? "Hide evidence" : "Show evidence")
    }

    private func content(_ album: Album) -> some View {
        HStack(alignment: .top, spacing: 32) {
            // Left: art, metadata, actions
            VStack(alignment: .leading, spacing: 20) {
                EnvironmentAlbumArtView(coverArtId: album.coverArt, size: .extraLarge, flexible: true)
                    .frame(width: 300, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)

                VStack(alignment: .leading, spacing: 8) {
                    Text(album.name)
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(2)
                    Text(album.artist)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    Text(metaLine(album))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    if isOnAudition {
                        storyLine
                    }

                    // GI-C: the header's one-line story — the dossier's first
                    // sentence, blooming into the full testimony (the rail) on
                    // click. Omitted entirely when the library has no story.
                    if let story {
                        Button {
                            rail.toggle()
                        } label: {
                            Text(story)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                        .help("Read the full story (⌘I)")
                        .accessibilityLabel("Story: \(story). Click for the full testimony.")
                    }
                }

                VStack(spacing: 10) {
                    Button {
                        onPlay(0)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(songs.isEmpty)

                    if isOnAudition {
                        Button(action: onAdmit) {
                            Label("Admit", systemImage: "tray.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .help("Admit this album to your library")
                    }
                }
            }
            .frame(width: 300)

            // Right: track rows
            VStack(alignment: .leading, spacing: 0) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else if songs.isEmpty {
                    Text("No playable tracks")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 12)
                } else {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        PlaneTrackRow(
                            index: index,
                            song: song,
                            isPlaying: nowPlaying?.id == song.id,
                            onPlay: { onPlay(index) }
                        )
                        if index < songs.count - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 860)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // The amber-ish audition story line: "on audition"
    // in the warm accent, then "· not yet admitted".
    private var storyLine: some View {
        (
            Text("on audition").foregroundStyle(.orange).fontWeight(.medium)
            + Text(" · not yet admitted").foregroundStyle(.secondary)
        )
        .font(.system(size: 12))
        .padding(.top, 2)
    }

    private func metaLine(_ album: Album) -> String {
        var parts: [String] = []
        if let year = album.year, year > 0 { parts.append(String(year)) }
        if let voiceName { parts.append("via \(voiceName)") }
        if parts.isEmpty { parts.append("\(album.songCount) tracks") }
        return parts.joined(separator: " · ")
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No album selected")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}

/// A single track row in the Object stratum. Double-click plays from this track.
private struct PlaneTrackRow: View {
    let index: Int
    let song: Song
    let isPlaying: Bool
    let onPlay: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if isPlaying {
                    Image(systemName: "play.fill").font(.system(size: 9))
                } else {
                    Text(String(format: "%2d", (song.track ?? index + 1)))
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .frame(width: 20, alignment: .trailing)
            .foregroundStyle(isPlaying ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))

            Text(song.title)
                .font(.system(size: 13))
                .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(song.formattedDuration)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: onPlay)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Track \(song.track ?? index + 1): \(song.title)")
        .accessibilityHint("Double-click to play")
        .accessibilityAddTraits(.isButton)
    }
}
