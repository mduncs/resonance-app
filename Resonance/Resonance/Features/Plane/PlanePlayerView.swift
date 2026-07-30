import SwiftUI

/// The Player stratum: now-playing takes over. Centered art, track title,
/// artist — album, a thin progress line, transport, and the decision deck
/// (Capture / Mark / Project / Admit). The
/// deck renders from `CurationVerbRegistry.deckVerbs()` so it cannot drift from
/// the QuickCaptureMenu / ⌘K HUD; tapping a verb calls back into `PlaneView`
/// (via `onVerb`) which performs it, toasts any confirmation, and refreshes the
/// plane so wu-wei effects (marks, admits) land on the shelf tiles.
struct PlanePlayerView: View {
    @Environment(AppState.self) private var appState

    /// Run a deck verb. Owned by `PlaneView` so the deck buttons and the bare
    /// k/m/p/a key grammar share one perform → toast → refresh path.
    let onVerb: (CurationVerb) -> Void

    /// GI-B: the docked evidence rail toggled by ⌘I at near distances. The Player
    /// stratum hosts the rail when it is the present stratum; the plane crossfade
    /// hides this copy at other distances. Subject follows the now-playing song.
    @State private var rail = PlaneEvidenceRailController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// GI-C: the now-playing song's dossier first sentence — the session line.
    /// Clicking it opens the evidence rail (the full testimony, in place).
    @State private var story: String?

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let song = appState.nowPlaying {
                    content(song)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            if rail.isOpen {
                Divider()
                PlaneEvidenceRail(subject: appState.nowPlaying.map(EvidenceSubject.song))
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { evidenceToggle }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: rail.isOpen)
        .task(id: appState.nowPlaying?.id) { loadStory() }
        .onReceive(NotificationCenter.default.publisher(for: .resonanceCurationDidChange)) { _ in
            loadStory()
        }
    }

    private func loadStory() {
        story = appState.nowPlaying.flatMap {
            DossierPreviewCache.shared.firstSentence(for: .song($0), appState: appState)
        }
    }

    /// Interim discoverability trigger (⌘I routes here via `ResonanceApp` when the
    /// plane is the active surface), so the rail is reachable before the near/far
    /// z-gating lands in `PlaneView`.
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

    private func content(_ song: Song) -> some View {
        VStack(spacing: 20) {
            EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .extraLarge, flexible: true)
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 8)

            VStack(spacing: 6) {
                Text(song.title)
                    .font(.system(size: 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("\(song.artist) — \(song.album)")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // GI-C: the session line — the dossier's first sentence for the
                // now-playing song, blooming into the full testimony (the rail)
                // on click. Omitted entirely when the library has no story.
                if let story {
                    Button {
                        rail.toggle()
                    } label: {
                        Text(story)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .help("Read the full story (⌘I)")
                    .accessibilityLabel("Story: \(story). Click for the full testimony.")
                }
            }

            progressBar
            transport
            deck(song)
        }
        .frame(maxWidth: 560)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var progressBar: some View {
        let duration = appState.currentDuration
        let fraction = duration > 0 ? min(1, max(0, appState.currentTime / duration)) : 0
        return VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 3)

            HStack {
                Text(formatTime(appState.currentTime))
                Spacer()
                Text(formatTime(duration))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button {
                Task { await appState.playbackManager.previous() }
            } label: {
                Image(systemName: "backward.fill").font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .disabled(!appState.playbackManager.canGoPrevious)
            .opacity(appState.playbackManager.canGoPrevious ? 1 : 0.3)

            Button {
                Task { await appState.playbackManager.togglePlayPause() }
            } label: {
                Image(systemName: appState.playbackState == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 26))
            }
            .buttonStyle(.plain)

            Button {
                Task { await appState.playbackManager.next() }
            } label: {
                Image(systemName: "forward.fill").font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .disabled(!appState.playbackManager.canGoNext)
            .opacity(appState.playbackManager.canGoNext ? 1 : 0.3)
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Decision deck

    /// One button per registry verb, single centered row (prototype restraint:
    /// gaps ~10pt). The primary verb (Admit) takes accent border + text; verbs
    /// disable when unavailable for the current now-playing subject.
    private func deck(_ song: Song) -> some View {
        let context = CurationVerbContext(
            appState: appState,
            song: song,
            album: appState.albums.first(where: { $0.id == song.albumId })
        )
        return HStack(spacing: 10) {
            ForEach(CurationVerbRegistry.deckVerbs()) { verb in
                deckButton(verb, isAvailable: verb.isAvailable(context))
            }
        }
        .padding(.top, 4)
    }

    private func deckButton(_ verb: CurationVerb, isAvailable: Bool) -> some View {
        Button {
            onVerb(verb)
        } label: {
            VStack(spacing: 4) {
                Text(verb.title)
                    .font(.system(size: 12, weight: .semibold))
                if let hint = verb.keyHint {
                    Text(hint)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(verb.isPrimary ? Color.accentColor.opacity(0.85) : Color.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minWidth: 60)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        verb.isPrimary ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: 1
                    )
            )
            .foregroundStyle(verb.isPrimary ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.4)
        .help(verb.title)
        .accessibilityLabel(verb.keyHint.map { "\(verb.title), key \($0)" } ?? verb.title)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.slash")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Nothing playing")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
