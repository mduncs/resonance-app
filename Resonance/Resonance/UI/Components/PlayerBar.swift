import SwiftUI
import AppKit

// MARK: - Player bar
//
// Layout targets:
// - Full-bleed 80pt footer band, warm dark glass rgb(36,34,31), content zone
//   ~55pt, center transport platter 369x55 radius ~27, artwork ~32-40, right
//   control clusters.
// - Icons are SF Symbols: play.fill <-> stop.fill by state,
//   backward.fill / forward.fill / shuffle / repeat / repeat.1.
// - Hover/pressed = standard AppKit highlight; focus = system ring (no custom).
// - Controls use 24px icons at a 32pt pitch.

struct PlayerBar: View {
    @Environment(AppState.self) private var appState
    @State private var repeatMode: RepeatMode = .off

    var body: some View {
        HStack(spacing: 0) {
            // ---- leading: artwork + metadata ----
            artwork
                .padding(.leading, 20)

            metadata
                .padding(.leading, 12)

            Spacer(minLength: 24)

            // ---- center: transport platter (measured 369x55 capsule) ----
            transportPlatter

            Spacer(minLength: 24)

            // ---- trailing: right controls ----
            rightControls
                .padding(.trailing, 20)
        }
        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 80)
        .background(barGlass)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    // MARK: Glass — NSVisualEffectView family (binary-verified: Music instantiates NSVisualEffectView + setMaterial:)
    private var barGlass: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, state: .active)
            // measured native tint overlay (dark authority; light uses web pill light glass)
            Color(nsColor: NSColor(
                calibratedRed: 36/255, green: 34/255, blue: 31/255, alpha: 0.92
            ))
        }
        .opacity(appState.playbackState == .stopped ? 0.6 : 1)
    }

    // MARK: Artwork
    private var artwork: some View {
        AlbumArtView(coverArtId: appState.nowPlaying?.coverArt, size: .miniBar, flexible: true)
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityLabel("Album artwork")
    }

    // MARK: Metadata
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(appState.nowPlaying?.title ?? "Nothing Playing")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(appState.nowPlaying?.artist ?? "Select a track to begin")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 280, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Transport platter
    private var transportPlatter: some View {
        HStack(spacing: 32) {
            transportButton("shuffle", isOn: appState.shuffleEnabled) {
                appState.shuffleEnabled.toggle()
            }
            transportButton("backward.fill") {
                Task { await appState.playbackManager.previous() }
            }
            playPauseButton
            transportButton("forward.fill") {
                Task { await appState.playbackManager.next() }
            }
            transportButton(repeatSymbol, isOn: repeatMode != .off) {
                repeatMode = repeatMode == .off ? .all : (repeatMode == .all ? .one : .off)
            }
        }
        .padding(.horizontal, 28)
        .frame(width: 369, height: 55)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: NSColor(calibratedWhite: 0.5, alpha: 0.22)))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transport controls")
    }

    private var repeatSymbol: String {
        repeatMode == .one ? "repeat.1" : "repeat"
    }

    private func transportButton(_ symbol: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .symbolVariant(isOn ? .fill : .none)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.accentColor : Color.primary)
    }

    private var playPauseButton: some View {
        Button {
            Task { await appState.playbackManager.togglePlayPause() }
        } label: {
            Image(systemName: appState.playbackState == .playing ? "stop.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(appState.playbackState == .playing ? "Pause" : "Play")
    }

    // MARK: Right controls
    private var rightControls: some View {
        HStack(spacing: 20) {
            Button {
                appState.toggleNowPlayingInspector(.lyrics)
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lyrics")

            Button {
                appState.toggleNowPlayingInspector(.queue)
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Up Next")

            volumeControl
        }
        .foregroundStyle(.primary)
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeSymbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { appState.volume },
                    set: { appState.volume = $0 }
                ),
                in: 0...1
            )
            .frame(width: 110)
            .accessibilityLabel("Volume")
        }
    }

    private var volumeSymbol: String {
        let v = appState.volume
        if v <= 0.01 { return "speaker.slash.fill" }
        if v < 0.34 { return "speaker.fill" }
        if v < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.3.fill"
    }
}
