import SwiftUI
import AppKit

/// Full-screen Now Playing surface.
///
/// Native baseline: Music 1.7, wave-closure-private captures 03 and 11–14.
/// Response_0 proves fixed bottom controls (72×37, 10-point edge inset)
/// in both 1820×1119 windowed and 2560×1440 full-screen hosts. Packages
/// 11–13 have no paused pointer-state property delta. Playing idle behavior
/// remains unmeasured; chrome currently stays visible without an invented timer.
/// Captured host states use literal artwork/metadata/seek anchors. Responsive
/// interpolation, typography, panel material, and motion remain unresolved;
/// the compact-player rest/reveal mechanism is not evidence
/// for this surface. Keep the protected Emotion Engine background independent.
///
/// The window lifecycle lives in `AppState.enterImmersiveMode` /
/// `exitImmersiveMode` (root-owned). This view closes its host window through
/// the existing `ImmersiveWindowDelegate.windowWillClose` path only.
struct ImmersiveView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.emotionEngine) private var emotionEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Same route-detection mechanism as the footer (`NowPlayingBar`).
    @StateObject private var routeAvailability = AirPlayRouteAvailability()

    @State private var panel: ImmersivePanel?

    enum ImmersivePanel: Equatable {
        case lyrics
        case queue

        var accessibilityName: String {
            switch self {
            case .lyrics: return "Lyrics"
            case .queue: return "Playing Next"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack(alignment: .topLeading) {
                immersionField(size: size)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        requestExit(full: true)
                    }

                if let song = appState.nowPlaying {
                    playerContent(song: song, size: size)
                        .frame(width: usesCapturedLyricsLayout(size: size) ? 1280 : size.width,
                               height: size.height)
                } else {
                    emptyState
                }

                if usesCapturedLyricsLayout(size: size) {
                    // Capture15 parent frame x1248 has bounds origin -32:
                    // actual viewport begins at x1280, not x1248.
                    LyricsView(syncedLineSpacing: 50)
                        .frame(width: 1228, height: 1368)
                        .clipped()
                        .offset(x: 1280, y: 72)
                        .accessibilityLabel("Lyrics")
                        .accessibilityIdentifier("Immersive.Panel.Lyrics")
                }
            }
            .overlay(alignment: .topLeading) {
                dismissCapsule
                    .padding(DesignTokens.Spacing.xl)
            }
            .overlay(alignment: .topTrailing) {
                utilityCapsule
                    .padding(DesignTokens.Spacing.xl)
            }
            .overlay(alignment: .bottomTrailing) {
                bottomTrailingChrome(size: size)
                    .padding(10)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Full Screen Now Playing")
        .accessibilityIdentifier("ImmersiveView")
        .onExitCommand {
            requestExit(full: false)
        }
        .onKeyPress(.space) {
            togglePlayback()
            return .handled
        }
    }

    // MARK: - Immersion field

    /// Emotion Engine remains Resonance's protected background identity; the
    /// scrims exist so controls stay legible over light artwork in both
    /// appearances. Reduced motion swaps the animated field for a static
    /// rendition of the same colors instead of tuning the canvas component.
    private func immersionField(size: CGSize) -> some View {
        ZStack {
            Color.black

            if reduceMotion {
                LinearGradient(
                    colors: [
                        emotionEngine.primaryColor.opacity(0.55),
                        emotionEngine.secondaryColor.opacity(0.35),
                        Color.black,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else if #available(macOS 15.0, *) {
                EmotionMeshGradientBackground(
                    primaryColor: emotionEngine.primaryColor,
                    secondaryColor: emotionEngine.secondaryColor,
                    backgroundColor: emotionEngine.backgroundColor,
                    isPlaying: isPlaybackActive
                )
            } else {
                EmotionGradientBackground(
                    primaryColor: emotionEngine.primaryColor,
                    secondaryColor: emotionEngine.secondaryColor,
                    backgroundColor: emotionEngine.backgroundColor,
                    isPlaying: isPlaybackActive
                )
            }

            // Legibility scrims behind the corner capsules and the transport
            // region. Not interactive.
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.32), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: max(120, size.height * 0.14))

                Spacer(minLength: 0)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: max(160, size.height * 0.22))
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Player content

    private var isPlaybackActive: Bool {
        appState.playbackState == .playing || appState.playbackState == .buffering
    }

    /// Literal measured viewports, not an inferred responsive formula. Native
    /// hosting layers are geometryFlipped=1, so these are top-down coordinates.
    /// Windowed playing and inspector-open layouts remain outside this table.
    private struct CapturedPlayerLayout {
        let artwork: CGRect
        let metadata: CGRect
        let seek: CGRect
        let transportY: CGFloat

        static func measured(size: CGSize, playing: Bool) -> Self? {
            // wave-closure-private 11/14 Response_0, artwork 0x7ca6a6a320;
            // seek 0x7ca3d64280; metadata 0x7ca8792a80.
            if size == CGSize(width: 2560, height: 1440) {
                return Self(
                    artwork: playing
                        ? CGRect(x: 922, y: 284, width: 716, height: 716)
                        : CGRect(x: 1018, y: 380, width: 524, height: 524),
                    metadata: CGRect(x: 922, y: 1019, width: 640, height: 38),
                    seek: CGRect(x: 922, y: 1074, width: 716, height: 15),
                    transportY: 1123
                )
            }
            // 03 Response_0: image 0x76185a5600 under y=52+243+1;
            // seek 0x76170f0a00; metadata 0x76170f0000.
            if size == CGSize(width: 1820, height: 1119), !playing {
                return Self(
                    artwork: CGRect(x: 724, y: 296, width: 372, height: 372),
                    metadata: CGRect(x: 655, y: 755, width: 434, height: 38),
                    seek: CGRect(x: 655, y: 810, width: 510, height: 15),
                    transportY: 859
                )
            }
            return nil
        }
    }

    private func usesCapturedLyricsLayout(size: CGSize) -> Bool {
        panel == .lyrics && !isPlaybackActive && size == CGSize(width: 2560, height: 1440)
    }

    @ViewBuilder
    private func playerContent(song: Song, size: CGSize) -> some View {
        if usesCapturedLyricsLayout(size: size) {
            // Capture15: same vertical allocations as paused fullscreen, with
            // the player shifted 640 points left to make room for lyrics.
            capturedPlayerContent(song: song, layout: CapturedPlayerLayout(
                artwork: CGRect(x: 378, y: 380, width: 524, height: 524),
                metadata: CGRect(x: 282, y: 1019, width: 640, height: 38),
                seek: CGRect(x: 282, y: 1074, width: 716, height: 15),
                transportY: 1123
            ))
        } else if panel == nil,
                  let measured = CapturedPlayerLayout.measured(size: size, playing: isPlaybackActive) {
            capturedPlayerContent(song: song, layout: measured)
        } else {
            unmeasuredPlayerContent(song: song, size: size)
        }
    }

    private func capturedPlayerContent(song: Song, layout: CapturedPlayerLayout) -> some View {
        ZStack(alignment: .topLeading) {
            playerArtwork(song: song, side: layout.artwork.width, captured: true)
                .offset(x: layout.artwork.minX, y: layout.artwork.minY)
            // Anchor the observed metadata allocation. Text descriptors remain
            // unverified; do not clip oversized fallback text to fake a match.
            playerMetadata(song: song, scale: 1, horizontalPadding: 0)
                .frame(width: layout.metadata.width, height: layout.metadata.height, alignment: .topLeading)
                .offset(x: layout.metadata.minX, y: layout.metadata.minY)
            SeekBar(showTime: false, interactionHeight: layout.seek.height,
                    trackHeight: 6, trackVerticalOffset: 0.5,
                    trackAppearance: .capturedExpanded)
                .frame(width: layout.seek.width)
                .accessibilityIdentifier("Immersive.SeekBar")
                .offset(x: layout.seek.minX, y: layout.seek.minY)
            // Native labels begin 17pt below the seek hit region's top, with
            // 13pt allocation. Their font/color remains separately unverified.
            timeLabels(width: layout.seek.width)
                .frame(height: 13, alignment: .top)
                .offset(x: layout.seek.minX, y: layout.seek.minY + 17)
            transportButtons(scale: 1, capturedWidth: layout.seek.width)
                .frame(width: layout.seek.width, height: 30, alignment: .topLeading)
                .offset(x: layout.seek.minX, y: layout.transportY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func unmeasuredPlayerContent(song: Song, size: CGSize) -> some View {
        let artworkSide = min(max(size.width * 0.40, 240), size.height * 0.52, 600)
        let compact = size.height < 700
        let scale: CGFloat = compact ? 0.82 : 1
        return VStack(spacing: compact ? DesignTokens.Spacing.lg : DesignTokens.Spacing.section) {
            Spacer(minLength: 0)
            playerArtwork(song: song, side: artworkSide)
            playerMetadata(song: song, scale: scale)
            transportSection(
                width: min(560, size.width * 0.72),
                scale: scale,
                interactionHeight: 20
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playerArtwork(song: Song, side: CGFloat, captured: Bool = false) -> some View {
        Group {
            if captured {
                artworkImage(song: song, side: side)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .circular))
                    .background {
                        // Captures03/11/14/15: opaque-white shadow owner inset1,
                        // not an alpha-derived shadow on the artwork image.
                        RoundedRectangle(cornerRadius: 9, style: .circular)
                            .fill(.white)
                            .frame(width: side - 2, height: side - 2)
                            .shadow(
                                color: .black.opacity(isPlaybackActive ? 0x1.ccccccp-2 : 0x1.333334p-3),
                                radius: isPlaybackActive ? 32 : 8,
                                y: isPlaybackActive ? 16 : 4
                            )
                    }
                    .overlay(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 10.5, style: .circular)
                            .strokeBorder(.black.opacity(0x1.47ae14p-4), lineWidth: 1)
                            .frame(width: side + 1, height: side + 1)
                            .offset(x: -0.5, y: -0.5)
                            .allowsHitTesting(false)
                    }
            } else {
                artworkImage(song: song, side: side)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xl))
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
            }
        }
        .accessibilityLabel("Album artwork")
        .id(song.id)
    }

    private func artworkImage(song: Song, side: CGFloat) -> some View {
        EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .extraLarge, flexible: true)
            .frame(width: side, height: side)
    }

    private func playerMetadata(song: Song, scale: CGFloat, horizontalPadding: CGFloat = DesignTokens.Spacing.section) -> some View {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text(song.title)
                    .font(.system(size: 28 * scale, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.white)

                // Captured expanded player has one artist — album subtitle,
                // not separate centered artist and album rows. Fonts remain
                // pending native descriptor recovery.
                Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.system(size: 19 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, horizontalPadding)
            .id(song.id)

    }

    private func transportSection(width: CGFloat, scale: CGFloat, interactionHeight: CGFloat = 20, horizontalPadding: CGFloat = DesignTokens.Spacing.section) -> some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            SeekBar(showTime: false, interactionHeight: interactionHeight)
                .tint(.white)
                .frame(width: width)
                .accessibilityIdentifier("Immersive.SeekBar")

            timeLabels(width: width)
            transportButtons(scale: scale)

        }
        .padding(.horizontal, horizontalPadding)
    }

    private func timeLabels(width: CGFloat) -> some View {
        HStack {
            Text(formatTime(appState.currentTime))
            Spacer()
            Text("-\(formatTime(max(0, appState.duration - appState.currentTime)))")
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.65))
        .monospacedDigit()
        .frame(width: width)
    }

    private func transportButtons(scale: CGFloat, capturedWidth: CGFloat? = nil) -> some View {
        // Only supplied for measured host states. These are backing/visual
        // allocations, not certification of native focus or hit regions.
        let frames = capturedWidth.map { width in [
            CGRect(x: 0, y: 0, width: 30, height: 30),
            CGRect(x: width / 2 - 100, y: 1, width: 28, height: 28),
            CGRect(x: width / 2 - 14, y: 1, width: 28, height: 28),
            CGRect(x: width / 2 + 72, y: 1, width: 28, height: 28),
            CGRect(x: width - 30, y: 0, width: 30, height: 30),
        ] }
        let layout = capturedWidth == nil
            ? AnyLayout(HStackLayout(spacing: 34 * scale))
            : AnyLayout(ZStackLayout(alignment: .topLeading))
        return layout {
            Button {
                appState.shuffleEnabled.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 17 * scale, weight: .medium))
                    .foregroundStyle(appState.shuffleEnabled ? .white : .white.opacity(0.48))
                    .frame(width: frames?[0].width ?? 34, height: frames?[0].height ?? 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle")
            .accessibilityValue(appState.shuffleEnabled ? "On" : "Off")
            .accessibilityHint("Play songs in random order")
            .accessibilityIdentifier("Immersive.Shuffle")
            .offset(x: frames?[0].minX ?? 0, y: frames?[0].minY ?? 0)

            Button {
                Task { await appState.playbackManager.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 24 * scale, weight: .semibold))
                    .frame(width: frames?[1].width ?? 40, height: frames?[1].height ?? 40)
            }
            .buttonStyle(.plain)
            .disabled(!appState.playbackManager.canGoPrevious)
            .accessibilityLabel("Previous")
            .accessibilityHint(appState.playbackManager.canGoPrevious ? "Play previous track" : "No previous track available")
            .accessibilityIdentifier("Immersive.Previous")
            .offset(x: frames?[1].minX ?? 0, y: frames?[1].minY ?? 0)
            .accessibilitySortPriority(2)

            Button {
                togglePlayback()
            } label: {
                Image(systemName: appState.playbackState == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 44 * scale, weight: .medium))
                    .frame(width: frames?[2].width ?? 72 * scale, height: frames?[2].height ?? 72 * scale)
                    .overlay(alignment: .top) {
                        if appState.playbackState == .buffering {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white)
                                .offset(y: -6)
                        }
                    }
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .accessibilityLabel(appState.playbackState == .playing ? "Pause" : "Play")
            .accessibilityHint(appState.playbackState == .playing ? "Pause playback" : "Resume playback")
            .accessibilityIdentifier("Immersive.PlayPause")
            .offset(x: frames?[2].minX ?? 0, y: frames?[2].minY ?? 0)
            .accessibilitySortPriority(3)

            Button {
                Task { await appState.playbackManager.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 24 * scale, weight: .semibold))
                    .frame(width: frames?[3].width ?? 40, height: frames?[3].height ?? 40)
            }
            .buttonStyle(.plain)
            .disabled(!appState.playbackManager.canGoNext)
            .accessibilityLabel("Next")
            .accessibilityHint(appState.playbackManager.canGoNext ? "Play next track" : "No next track available")
            .accessibilityIdentifier("Immersive.Next")
            .offset(x: frames?[3].minX ?? 0, y: frames?[3].minY ?? 0)
            .accessibilitySortPriority(2)

            Button {
                appState.playbackManager.cycleRepeatMode()
            } label: {
                Image(systemName: repeatIcon)
                    .font(.system(size: 17 * scale, weight: .medium))
                    .foregroundStyle(appState.playbackManager.repeatMode != .off ? .white : .white.opacity(0.48))
                    .frame(width: frames?[4].width ?? 34, height: frames?[4].height ?? 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Repeat")
            .accessibilityValue(repeatAccessibilityValue)
            .accessibilityHint("Change repeat mode")
            .accessibilityIdentifier("Immersive.Repeat")
            .offset(x: frames?[4].minX ?? 0, y: frames?[4].minY ?? 0)
        }
    }

    private var repeatIcon: String {
        appState.playbackManager.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private var repeatAccessibilityValue: String {
        switch appState.playbackManager.repeatMode {
        case .off: return "Off"
        case .one: return "One"
        case .all: return "All"
        }
    }
    /// Capsule chrome fill: a real material normally; near-opaque black when
    /// Reduce Transparency removes materials, matching the panel-card policy.
    private var capsuleFill: AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(Color.black.opacity(0.92))
            : AnyShapeStyle(Material.ultraThinMaterial)
    }

    private var dismissCapsule: some View {
        Button {
            requestExit(full: true)
        } label: {
            Label("Dismiss Now Playing", systemImage: "chevron.down")
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DesignTokens.Spacing.sm + 2)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(capsuleFill)
        )
        .shadow(color: .black.opacity(0.30), radius: 10, y: 3)
        .accessibilityLabel("Dismiss Now Playing")
        .accessibilityHint("Close the full screen player")
        .accessibilityIdentifier("Immersive.Dismiss")
    }

    /// Top-trailing utilities: switch to MiniPlayer, output routing, and
    /// volume. Pairing output routing with volume mirrors the native dual
    /// AirPlay/volume control mechanism.
    private var utilityCapsule: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Button {
                switchToMiniPlayer()
            } label: {
                Label("Switch to MiniPlayer", systemImage: "arrow.down.right.and.arrow.up.left")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch to MiniPlayer")
            .accessibilityHint("Open the detached MiniPlayer")
            .accessibilityIdentifier("Immersive.MiniPlayer")

            if showsRoutePicker {
                AirPlayButton()
                    .frame(width: 26, height: 26)
                    .accessibilityLabel("AirPlay")
                    .accessibilityIdentifier("Immersive.AirPlay")
            }

            volumeControl
        }
        .padding(.leading, DesignTokens.Spacing.sm + 2)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(capsuleFill)
        )
        .shadow(color: .black.opacity(0.30), radius: 10, y: 3)
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 18)

            Slider(value: Binding(
                get: { Double(appState.volume) },
                set: { appState.volume = Float($0) }
            ))
            .tint(.white)
            // Response_0: 0x7ca8793480 / 0x761778f980, width 114.
            .frame(width: 114)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int(appState.volume * 100)) percent")
            .accessibilityIdentifier("Immersive.VolumeSlider")
        }
        .padding(.trailing, DesignTokens.Spacing.sm + 2)
        .accessibilityElement(children: .contain)
    }

    private var volumeIcon: String {
        if appState.volume < 0.01 { return "speaker.slash.fill" }
        else if appState.volume < 0.33 { return "speaker.wave.1.fill" }
        else if appState.volume < 0.66 { return "speaker.wave.2.fill" }
        else { return "speaker.wave.3.fill" }
    }

    private var showsRoutePicker: Bool {
        if let fixture = DeterministicCaptureFixture.configuration {
            return fixture.multipleRoutesDetected
        }
        return routeAvailability.multipleRoutesDetected
    }

    // MARK: - Bottom-trailing lyrics/queue

    private func bottomTrailingChrome(size: CGSize) -> some View {
        VStack(alignment: .trailing, spacing: DesignTokens.Spacing.md) {
            if let panel, !usesCapturedLyricsLayout(size: size) {
                panelCard(panel, size: size)
            }

            // Response_0: 0x7ca3d65e00 (full-screen), 0x76170f2580
            // (windowed). Child controls are 36×36 at y=1 and y=0.
            HStack(alignment: .top, spacing: 0) {
                panelToggle(.lyrics, icon: "quote.bubble")
                    .offset(y: 1)
                panelToggle(.queue, icon: "list.bullet")
            }
            .frame(width: 72, height: 37, alignment: .top)
            .background(Capsule().fill(capsuleFill))
        }
    }

    private func panelToggle(_ target: ImmersivePanel, icon: String) -> some View {
        let isSelected = panel == target

        return Button {
            // No native duration/easing has been recovered for this transition.
            self.panel = isSelected ? nil : target
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : .white)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.accessibilityName)
        .accessibilityHint(isSelected ? "Hide \(target.accessibilityName)" : "Show \(target.accessibilityName)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(target == .lyrics ? "Immersive.Lyrics" : "Immersive.Queue")
    }

    @ViewBuilder
    private func panelCard(_ panel: ImmersivePanel, size: CGSize) -> some View {
        Group {
            switch panel {
            case .lyrics:
                // Capture15 spacing belongs only to its measured paused
                // fullscreen viewport, not this unmeasured compact fallback.
                LyricsView()
            case .queue:
                ContinuePlayingPanel()
            }
        }
        .frame(
            width: min(420, max(280, size.width * 0.32)),
            height: min(size.height * 0.52, 520)
        )
        .background(
            reduceTransparency
                ? AnyShapeStyle(Color.black.opacity(0.92))
                : AnyShapeStyle(Material.ultraThinMaterial),
            in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xl)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xl))
        .shadow(color: .black.opacity(0.38), radius: 18, y: 6)
        .accessibilityLabel(panel.accessibilityName)
        .accessibilityIdentifier("Immersive.Panel.\(panel.accessibilityName)")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "music.note")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.30))

            Text("Not Playing")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.70))

            Text("Start playing a song to see it here.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, DesignTokens.Spacing.section)
    }

    // MARK: - Exit and hand-off

    /// The immersive window is created by `AppState.enterImmersiveMode` and is
    /// not a SwiftUI presentation, so `dismiss` cannot close it. Closing the
    /// host window routes through the existing `ImmersiveWindowDelegate` so
    /// `AppState` clears its retained references.
    private var immersiveHostWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "immersivePlayer" }
    }

    /// - Parameter full: `true` closes the surface outright (dismiss button,
    ///   double click). `false` first leaves a native full-screen Space and
    ///   keeps the surface for the next press, matching system Escape
    ///   behavior.
    private func requestExit(full: Bool) {
        guard let window = immersiveHostWindow else { return }

        if !full, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return
        }

        window.performClose(nil)
    }

    private func switchToMiniPlayer() {
        appState.showMiniPlayer()
        requestExit(full: true)
    }

    private func togglePlayback() {
        Task { await appState.playbackManager.togglePlayPause() }
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    ImmersiveView()
        .environment(AppState())
}
