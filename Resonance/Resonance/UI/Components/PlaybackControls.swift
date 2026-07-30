import SwiftUI

struct PlaybackControls: View {
    @Environment(AppState.self) private var appState

    var showShuffle: Bool = true
    var showRepeat: Bool = true
    var size: ControlSize = .regular

    var body: some View {
        HStack(spacing: spacing) {
            if showShuffle {
                Button {
                    appState.queueManager.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .symbolVariant(appState.queueManager.isShuffleEnabled ? .fill : .none)
                }
                .buttonStyle(.plain)
                .foregroundStyle(appState.queueManager.isShuffleEnabled ? Color.accentColor : Color.primary)
                .accessibilityLabel(appState.queueManager.isShuffleEnabled ? "Shuffle on" : "Shuffle off")
                .accessibilityHint("Double tap to toggle shuffle")
                .accessibilityAddTraits(appState.queueManager.isShuffleEnabled ? [.isButton, .isSelected] : .isButton)
            }

            // Previous
            Button {
                Task {
                    await appState.playbackManager.previous()
                }
            } label: {
                Image(systemName: "backward.fill")
                    .font(buttonFont)
            }
            .buttonStyle(.plain)
            .disabled(!appState.playbackManager.canGoPrevious)
            .accessibilityLabel("Previous track")
            .accessibilityHint(appState.playbackManager.canGoPrevious ? "Double tap to play previous track" : "No previous track available")

            // Play/Pause
            Button {
                Task {
                    await appState.playbackManager.togglePlayPause()
                }
            } label: {
                Image(systemName: appState.playbackState == .playing ? "pause.fill" : "play.fill")
                    .font(playPauseFont)
                    .frame(width: playPauseSize, height: playPauseSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(appState.playbackState == .playing ? "Pause" : "Play")
            .accessibilityHint(appState.playbackState == .playing ? "Double tap to pause" : "Double tap to play")

            // Next
            Button {
                Task {
                    await appState.playbackManager.next()
                }
            } label: {
                Image(systemName: "forward.fill")
                    .font(buttonFont)
            }
            .buttonStyle(.plain)
            .disabled(!appState.playbackManager.canGoNext)
            .accessibilityLabel("Next track")
            .accessibilityHint(appState.playbackManager.canGoNext ? "Double tap to play next track" : "No next track available")

            if showRepeat {
                Button {
                    appState.playbackManager.cycleRepeatMode()
                } label: {
                    Image(systemName: repeatIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(appState.playbackManager.repeatMode != .off ? Color.accentColor : Color.primary)
                .accessibilityLabel(repeatAccessibilityLabel)
                .accessibilityHint("Double tap to change repeat mode")
                .accessibilityAddTraits(appState.playbackManager.repeatMode != .off ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private var spacing: CGFloat {
        switch size {
        case .mini: return 8
        case .small: return 12
        case .regular: return 16
        case .large, .extraLarge: return 20
        @unknown default: return 16
        }
    }

    private var buttonFont: Font {
        switch size {
        case .mini: return .caption
        case .small: return .subheadline
        case .regular: return .title3
        case .large, .extraLarge: return .title2
        @unknown default: return .title3
        }
    }

    private var playPauseFont: Font {
        switch size {
        case .mini: return .body
        case .small: return .title3
        case .regular: return .title
        case .large, .extraLarge: return .largeTitle
        @unknown default: return .title
        }
    }

    private var playPauseSize: CGFloat {
        switch size {
        case .mini: return 20
        case .small: return 28
        case .regular: return 36
        case .large, .extraLarge: return 48
        @unknown default: return 36
        }
    }

    private var repeatIcon: String {
        switch appState.playbackManager.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private var repeatAccessibilityLabel: String {
        switch appState.playbackManager.repeatMode {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        PlaybackControls(size: .mini)
        PlaybackControls(size: .small)
        PlaybackControls(size: .regular)
        PlaybackControls(size: .large)
    }
    .padding()
    .environment(AppState())
}
