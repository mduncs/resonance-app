import SwiftUI
import AppKit

struct NowPlayingBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var routeAvailability = AirPlayRouteAvailability()
    @State private var isVolumeExpanded = false
    @State private var isScrubberHovered = false
    @State private var isScrubberDragging = false
    @State private var scrubberDragProgress: CGFloat?
    @State private var isPointerInsideBar = false
    @State private var lastPointerLocation: CGPoint?
    @State private var seekTask: Task<Void, Never>?
    @State private var observedRepeatMode: RepeatMode = .off

    /// Music 1.7 exposes a 700×54 NSGlassEffectView. Its controls live in a
    /// separate 682×49 inner coordinate system, translated by approximately
    /// (+9,+9) inside the host. Keep those coordinate systems explicit: the
    /// host is not the old AX capsule.
    private enum NativeMetrics {
        static let hostWidth: CGFloat = 700
        static let hostHeight: CGFloat = 54
        static let innerWidth: CGFloat = 682
        static let innerHeight: CGFloat = 49
        static let innerOffsetX: CGFloat = 9
        static let innerOffsetY: CGFloat = 9
        static let albumArtSize: CGFloat = 34
        static let centerWidth: CGFloat = 406
        static let centerWidthWithRoutePicker: CGFloat = 369
        static let scrubberRestHeight: CGFloat = 18
        static let scrubberExpandedHeight: CGFloat = 32
        static let scrubberRestTrackHeight: CGFloat = 2
        static let scrubberExpandedTrackHeight: CGFloat = 8
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: NativeMetrics.hostWidth, height: NativeMetrics.hostHeight)

            innerSurface
            scrubberRow
        }
        .frame(width: NativeMetrics.hostWidth, height: NativeMetrics.hostHeight, alignment: .topLeading)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: isScrubberExpanded)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: isVolumeExpanded)
        .modifier(GlassEffectModifier(shape: .capsule))
        .accessibilityElement(children: .contain)
        // Track in the stable footer coordinate space, not the resizing rail:
        // entering the thin strip reveals time; the revealed rail remains
        // hovered as the pointer moves upward into it. No playback write here.
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                isPointerInsideBar = true
                lastPointerLocation = location
                updateScrubberHover(at: location)
            case .ended:
                isPointerInsideBar = false
                lastPointerLocation = nil
                isScrubberHovered = false
            }
        }
        .onChange(of: appState.nowPlaying?.id) { _, _ in
            resetScrubberInteraction()
        }
        .onChange(of: appState.activeServerId) { _, _ in
            resetScrubberInteraction()
        }
        .onChange(of: isVolumeExpanded) { _, expanded in
            if expanded {
                isScrubberHovered = false
            } else if isPointerInsideBar, let lastPointerLocation {
                updateScrubberHover(at: lastPointerLocation)
            }
        }
        .onChange(of: isScrubberAvailable) { _, available in
            if !available {
                resetScrubberInteraction()
            }
        }
        .onDisappear {
            resetScrubberInteraction()
            isPointerInsideBar = false
            lastPointerLocation = nil
        }
        .onReceive(appState.playbackManager.$repeatMode) { mode in
            observedRepeatMode = mode
        }
    }

    /// The old AX fixture's 682×49 interaction surface. The native hierarchy
    /// places it about (+9,+9) inside the 700×54 glass host; child frames stay
    /// in that inner coordinate system.
    private var innerSurface: some View {
        ZStack(alignment: .topLeading) {
            playbackControls()
            centerSection()
            rightControls()
        }
        .frame(width: NativeMetrics.innerWidth, height: NativeMetrics.innerHeight, alignment: .topLeading)
        .offset(x: NativeMetrics.innerOffsetX, y: NativeMetrics.innerOffsetY)
    }

    private var showsRoutePicker: Bool {
        if let fixture = DeterministicCaptureFixture.configuration {
            return fixture.multipleRoutesDetected
        }
        return routeAvailability.multipleRoutesDetected
    }

    private var centerWidth: CGFloat {
        showsRoutePicker ? NativeMetrics.centerWidthWithRoutePicker : NativeMetrics.centerWidth
    }

    private var metadataTextWidth: CGFloat {
        // Native metadata: artwork 34 + gap 8, text, gap 8 + More 36.
        centerWidth - 86
    }

    // Footer ink is monochrome, independent of the user's Finder/accent color.
    // Explicit enabled-mode colors remain on shuffle/repeat/inspector controls.
    private var controlInk: Color { colorScheme == .dark ? .white : .black }

    private var scrubberHitWidth: CGFloat {
        centerWidth - 4
    }

    private var scrubberSurfaceHeight: CGFloat {
        isScrubberExpanded ? NativeMetrics.scrubberExpandedHeight : NativeMetrics.scrubberRestHeight
    }

    private var isScrubberExpanded: Bool {
        isScrubberAvailable && (isScrubberHovered || isScrubberDragging)
    }

    private var rightControlsOffsetX: CGFloat {
        showsRoutePicker ? 535 : 572
    }

    private var rightControlsWidth: CGFloat {
        showsRoutePicker ? 148 : 111
    }

    // MARK: - Center Section (inner artwork 157,1 → host 166,10)

    private func centerSection() -> some View {
        ZStack(alignment: .topLeading) {
            nowPlayingInfo(albumArtSize: NativeMetrics.albumArtSize)
                // Music's hover reference retains a faint, defocused trace of
                // the cover/title above the timeline. Do not remove it entirely.
                // These are screenshot-guided values, not captured filter inputs.
                .blur(radius: isScrubberExpanded ? 3 : 0)
                .opacity(isScrubberExpanded ? 0.55 : 1)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.25),
                        .init(color: isScrubberExpanded ? .clear : .black, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
            if !isVolumeExpanded {
                moreControl
                    .opacity(isScrubberExpanded ? 0 : 1)
                    .offset(x: centerWidth - 36, y: -1)
            }
        }
        .allowsHitTesting(!isScrubberExpanded)
        .accessibilityHidden(isScrubberExpanded)
        .frame(width: centerWidth, height: 34, alignment: .topLeading)
        .offset(x: 157, y: 1)
    }

    // MARK: - Scrubber (host-local frame 168,40,402,18)

    private var scrubberRow: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width + 4
            let trackHeight = isScrubberExpanded
                ? NativeMetrics.scrubberExpandedTrackHeight
                : NativeMetrics.scrubberRestTrackHeight

            ZStack(alignment: .topLeading) {
                HStack {
                        Text(formatTime(scrubberTime))
                        Spacer()
                        Text("−\(formatTime(max(0, appState.currentDuration - scrubberTime)))")
                    }
                    // User's Sep 10 hover reference: timer ink matches the
                    // 13-point footer text, rather than the former tiny labels.
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(controlInk)
                    .frame(width: trackWidth, alignment: .leading)
                    .offset(x: -2, y: -2)
                    .opacity(isScrubberExpanded ? 1 : 0)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(controlInk.opacity(isScrubberExpanded ? 0.28 : 0.16))
                        .frame(width: trackWidth, height: trackHeight)

                    Capsule()
                        .fill(controlInk.opacity(isScrubberExpanded ? 0.78 : 0.52))
                        .frame(
                            width: progressWidth(in: trackWidth),
                            height: trackHeight
                        )
                }
                .frame(width: trackWidth, height: NativeMetrics.scrubberRestHeight)
                .frame(
                    width: trackWidth,
                    height: scrubberSurfaceHeight,
                    alignment: .center
                )
                // Native hover/drag track is host y37…45 inside the y21…53
                // interaction surface, not vertically centered in that surface.
                .offset(x: -2, y: isScrubberExpanded ? 4 : 0)
            }
            .frame(
                width: geometry.size.width,
                height: scrubberSurfaceHeight,
                alignment: .topLeading
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isScrubberAvailable, geometry.size.width > 0 else { return }
                        if !isScrubberDragging {
                            seekTask?.cancel()
                            seekTask = nil
                        }
                        isScrubberDragging = true
                        scrubberDragProgress = max(0, min(1, value.location.x / geometry.size.width))
                    }
                    .onEnded { value in
                        guard isScrubberAvailable, geometry.size.width > 0 else {
                            resetScrubberInteraction()
                            return
                        }
                        let progress = max(0, min(1, value.location.x / geometry.size.width))
                        isScrubberDragging = false
                        commitSeek(to: progress * appState.currentDuration)
                    }
            )
        }
        .frame(width: scrubberHitWidth, height: scrubberSurfaceHeight)
        .offset(x: 168, y: isScrubberExpanded ? 21 : 40)
        .opacity(isScrubberAvailable ? 1 : 0)
        .allowsHitTesting(isScrubberAvailable)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("FooterScrubber")
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(formatTime(scrubberTime)) of \(formatTime(appState.currentDuration))")
        .accessibilityHidden(!isScrubberAvailable)
        .accessibilityAdjustableAction { direction in
            adjustScrubber(direction)
        }
    }

    private var scrubberTime: TimeInterval {
        guard let dragProgress = scrubberDragProgress, appState.currentDuration > 0 else {
            return appState.currentTime
        }
        return dragProgress * appState.currentDuration
    }

    private var isScrubberAvailable: Bool {
        appState.nowPlaying != nil
            && appState.currentDuration.isFinite
            && appState.currentDuration > 0
            && appState.playbackManager.currentSourceSupportsSeeking
    }

    private func commitSeek(to time: TimeInterval) {
        guard isScrubberAvailable, time.isFinite else {
            resetScrubberInteraction()
            return
        }

        seekTask?.cancel()
        let duration = appState.currentDuration
        guard duration.isFinite, duration > 0,
              let songID = appState.nowPlaying?.id else {
            resetScrubberInteraction()
            return
        }
        let target = max(0, min(duration, time))
        let serverID = appState.activeServerId
        scrubberDragProgress = CGFloat(target / duration)

        seekTask = Task { @MainActor in
            guard !Task.isCancelled,
                  appState.nowPlaying?.id == songID,
                  appState.activeServerId == serverID,
                  isScrubberAvailable else {
                return
            }
            await appState.playbackManager.seek(to: target)
            guard !Task.isCancelled,
                  appState.nowPlaying?.id == songID,
                  appState.activeServerId == serverID else {
                return
            }
            scrubberDragProgress = nil
            seekTask = nil
        }
    }

    private func adjustScrubber(_ direction: AccessibilityAdjustmentDirection) {
        guard isScrubberAvailable else { return }
        let step = max(1, appState.currentDuration * 0.05)
        switch direction {
        case .increment:
            commitSeek(to: scrubberTime + step)
        case .decrement:
            commitSeek(to: scrubberTime - step)
        @unknown default:
            return
        }
    }

    private func resetScrubberInteraction() {
        seekTask?.cancel()
        seekTask = nil
        isScrubberHovered = false
        isScrubberDragging = false
        scrubberDragProgress = nil
    }

    private func updateScrubberHover(at location: CGPoint) {
        let top: CGFloat = isScrubberExpanded ? 21 : 40
        let region = CGRect(x: 166, y: top, width: centerWidth, height: 54 - top)
        isScrubberHovered = !isVolumeExpanded && isScrubberAvailable && region.contains(location)
    }

    // MARK: - Glass Effect Modifiers

    private struct GlassEffectModifier: ViewModifier {
        let shape: AnyShape

        init(shape: some Shape) {
            self.shape = AnyShape(shape)
        }

        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(.regular.interactive(), in: shape)
            } else {
                content
                    .background { shape.fill(.ultraThinMaterial) }
                    .clipShape(shape)
            }
        }
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard appState.currentDuration.isFinite, appState.currentDuration > 0 else { return 0 }
        let currentProgress = appState.currentTime.isFinite
            ? CGFloat(appState.currentTime / appState.currentDuration)
            : 0
        let rawRatio = scrubberDragProgress ?? currentProgress
        let ratio = rawRatio.isFinite ? rawRatio : 0
        return totalWidth * max(0, min(1, ratio))
    }

    // MARK: - Playback Controls (inner frames translated +9,+9 into host)

    private func playbackControls() -> some View {
        ZStack(alignment: .topLeading) {
            // Inner coordinates: shuffle (0,4,28,28), previous
            // (28,4,28,28), play (56,0,36,36), next (92,4,28,28),
            // repeat (120,4,28,28). The enclosing inner surface supplies
            // the host-local (+9,+9) translation.
            Button {
                appState.queueManager.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NativeTransportButtonStyle())
            .frame(width: 28, height: 28)
            .offset(x: 0, y: 4)
            .foregroundStyle(appState.queueManager.isShuffleEnabled ? Color.accentColor : .primary)
            .accessibilityLabel(appState.queueManager.isShuffleEnabled ? "Shuffle on" : "Shuffle off")
            .accessibilityHint("Double tap to toggle shuffle")
            .accessibilityIdentifier("FooterShuffle")
            .accessibilityAddTraits(appState.queueManager.isShuffleEnabled ? [.isButton, .isSelected] : .isButton)

            Button {
                Task { await appState.playbackManager.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14.5))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NativeTransportButtonStyle())
            .frame(width: 28, height: 28)
            .offset(x: 28, y: 4)
            .opacity(appState.playbackManager.canGoPrevious ? 1.0 : 0.3)
            .disabled(!appState.playbackManager.canGoPrevious)
            .accessibilityLabel("Previous track")
            .accessibilityHint(appState.playbackManager.canGoPrevious ? "Double tap to play previous track" : "No previous track available")
            .accessibilityIdentifier("FooterPrevious")

            Button {
                Task {
                    if appState.nowPlaying == nil {
                        await resumeFromHistory()
                    } else {
                        await appState.playbackManager.togglePlayPause()
                    }
                }
            } label: {
                Image(systemName: appState.playbackState == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 26.5))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NativePlayPauseButtonStyle())
            .frame(width: 36, height: 36)
            .offset(x: 56, y: 0)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(appState.playbackState == .playing ? "Pause" : "Play")
            .accessibilityHint(appState.playbackState == .playing ? "Double tap to pause" : "Double tap to play")
            .accessibilityIdentifier("FooterPlayPause")

            Button {
                Task { await appState.playbackManager.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14.5))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NativeTransportButtonStyle())
            .frame(width: 28, height: 28)
            .offset(x: 92, y: 4)
            .opacity(appState.playbackManager.canGoNext ? 1.0 : 0.3)
            .disabled(!appState.playbackManager.canGoNext)
            .accessibilityLabel("Next track")
            .accessibilityHint(appState.playbackManager.canGoNext ? "Double tap to play next track" : "No next track available")
            .accessibilityIdentifier("FooterNext")

            Button {
                appState.playbackManager.cycleRepeatMode()
            } label: {
                Image(systemName: repeatIcon)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NativeTransportButtonStyle())
            .frame(width: 28, height: 28)
            .offset(x: 120, y: 4)
            .foregroundStyle(observedRepeatMode != .off ? Color.accentColor : .primary)
            .accessibilityLabel(repeatAccessibilityLabel)
            .accessibilityHint("Double tap to change repeat mode")
            .accessibilityIdentifier("FooterRepeat")
            .accessibilityAddTraits(observedRepeatMode != .off ? [.isButton, .isSelected] : .isButton)
        }
        .frame(width: 157, height: NativeMetrics.innerHeight, alignment: .topLeading)
        .foregroundStyle(controlInk)
        .tint(controlInk)
    }

    // MARK: - Hover/pressed (standard highlight, native has no custom mouse handlers)

    private struct NativeTransportButtonStyle: ButtonStyle {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }

    private struct NativePlayPauseButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            NativePlayPauseButtonFace(isPressed: configuration.isPressed) {
                configuration.label
            }
        }
    }

    /// Native 25-footer-play-pressed-light: the 36-point glyph parent shrinks
    /// to 32.4 points, independently of the white, half-opacity press backing
    /// expanding to 39.6 points. Only this control's pressed state is evidenced.
    private struct NativePlayPauseButtonFace<Content: View>: View {
        let isPressed: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @ViewBuilder let content: Content

        var body: some View {
            content
                .scaleEffect(isPressed ? 0.9 : 1)
                .background {
                    if isPressed {
                        Circle()
                            .fill(Color.white.opacity(0.5))
                            .frame(width: 36, height: 36)
                            .scaleEffect(1.1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isPressed)
        }
    }

    // MARK: - Now Playing Info (host-local artwork 166,10,34,34)

    @ViewBuilder
    private func nowPlayingInfo(albumArtSize: CGFloat) -> some View {
        if let song = appState.nowPlaying {
            HStack(spacing: 8) {
                AlbumArtMenuButton(song: song, size: albumArtSize)
                    .frame(width: albumArtSize, height: albumArtSize)

                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        navigateToAlbumWithSong(albumId: song.albumId, songId: song.id)
                    } label: {
                        MarqueeText(text: song.title, font: .system(size: 13, weight: .semibold))
                            .frame(width: metadataTextWidth, height: 16, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(song.albumId.isEmpty)
                    .accessibilityLabel("Album: \(song.album)")
                    .accessibilityHint("Show the album containing \(song.title)")
                    .help("Go to Album")

                    Button {
                        navigateToArtist(song.artistId)
                    } label: {
                        MarqueeText(
                            text: "\(song.artist) — \(song.album)",
                            font: .system(size: 12),
                            color: .secondary
                        )
                        .frame(width: metadataTextWidth, height: 15, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(song.artistId.isEmpty)
                    .accessibilityLabel("Artist: \(song.artist)")
                    .accessibilityHint("Show \(song.artist)")
                    .help("Go to Artist")
                }
                .offset(y: 0.5)
                .contextMenu {
                    SongContextMenu(song: song)
                }
            }
            .frame(width: centerWidth, height: 34, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: albumArtSize, height: albumArtSize)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Not Playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Select a song")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: centerWidth, height: 34, alignment: .leading)
        }
    }

    // MARK: - Metadata More accessory (host x536, or x499 with route picker)

    @ViewBuilder
    private var moreControl: some View {
        if let song = appState.nowPlaying {
            Menu {
                if !showsRoutePicker {
                    HStack(spacing: 8) {
                        Label("AirPlay", systemImage: "airplayaudio")
                        Spacer(minLength: 8)
                        AirPlayButton()
                            .frame(width: 24, height: 20)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("AirPlay")

                    Divider()
                }
                SongContextMenu(song: song)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(controlInk)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(controlInk)
            .tint(controlInk)
            .frame(width: 36, height: 36)
            .accessibilityLabel("More")
            .accessibilityHint("Show actions for the current song")
            .accessibilityIdentifier("FooterMore")
        } else {
            Button {} label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NativeTransportButtonStyle())
            .frame(width: 36, height: 36)
            .disabled(true)
            .accessibilityLabel("More")
            .accessibilityIdentifier("FooterMore")
        }
    }

    // MARK: - Right Controls (host-local x544,581,618,655)
    // The captured four-slot sequence is More, Lyrics, Up Next, and Volume.
    // AirPlay remains available from More without inventing a fifth rest slot.

    private func rightControls() -> some View {
        HStack(spacing: 1) {
            Button {
                appState.toggleNowPlayingInspector(.lyrics)
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NativeTransportButtonStyle())
            .foregroundStyle(appState.nowPlayingInspector == .lyrics ? Color.accentColor : controlInk)
            .accessibilityLabel("Lyrics")
            .accessibilityHint("Show or hide lyrics")
            .accessibilityIdentifier("FooterLyrics")
            .opacity(isVolumeExpanded ? 0 : 1)
            .allowsHitTesting(!isVolumeExpanded)
            .accessibilityHidden(isVolumeExpanded)
            .accessibilityAddTraits(appState.nowPlayingInspector == .lyrics ? [.isButton, .isSelected] : .isButton)

            Button {
                appState.toggleNowPlayingInspector(.queue)
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NativeTransportButtonStyle())
            .foregroundStyle(appState.nowPlayingInspector == .queue ? Color.accentColor : controlInk)
            .accessibilityLabel("Up Next")
            .accessibilityHint("Show or hide the queue")
            .accessibilityIdentifier("FooterQueue")
            .opacity(isVolumeExpanded ? 0 : 1)
            .allowsHitTesting(!isVolumeExpanded)
            .accessibilityHidden(isVolumeExpanded)
            .accessibilityAddTraits(appState.nowPlayingInspector == .queue ? [.isButton, .isSelected] : .isButton)

            if showsRoutePicker {
                AirPlayButton()
                    .frame(width: 36, height: 36)
                    .accessibilityIdentifier("FooterAirPlay")
                    .accessibilityLabel("AirPlay")
                    .opacity(isVolumeExpanded ? 0 : 1)
                    .allowsHitTesting(!isVolumeExpanded)
                    .accessibilityHidden(isVolumeExpanded)
            }

            InlineVolumeControl(isPresented: $isVolumeExpanded)
        }
        .frame(width: rightControlsWidth, height: 36, alignment: .topLeading)
        .offset(x: rightControlsOffsetX, y: 0)
    }

    // MARK: - Volume (native inline expansion)

    // September 9 empty-state capture: unchanged 700×54 footer; expanded
    // 149×40 capsule at host (544,7), speaker at (655,9), slider hit 107×24.
    // Public glass and rail colors remain provisional. Hover-open,
    // mute, loaded-state overlap, and native dismissal timing are not established.
    private struct InlineVolumeControl: View {
        @Environment(AppState.self) private var appState
        @Environment(\.colorScheme) private var colorScheme
        @Binding var isPresented: Bool
        @State private var wheelController = FooterVolumeWheelController()

        private var speaker: some View {
            speakerButton(expanded: false)
        }

        private var expandedSpeaker: some View {
            speakerButton(expanded: true)
        }

        private func speakerButton(expanded: Bool) -> some View {
            Button { isPresented = !expanded } label: {
                Image(systemName: volumeSymbol)
                    .font(.system(size: 15))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NativeTransportButtonStyle())
            .foregroundStyle(colorScheme == .dark ? Color.white : .black)
            .accessibilityIdentifier("FooterVolume")
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int(appState.volume * 100)) percent")
            .accessibilityHint(isPresented ? "Volume control expanded" : "Show volume control")
            .help(expanded ? "Close Volume Control" : "Show Volume Control")
            .frame(width: 36, height: 36)
        }

        var body: some View {
            speaker
                .opacity(isPresented ? 0 : 1)
                .allowsHitTesting(!isPresented)
                .accessibilityHidden(isPresented)
                .background(VolumeWheelRegion(controller: wheelController))
                .overlay(alignment: .bottomTrailing) {
                    ZStack(alignment: .topLeading) {
                        if isPresented {
                            CapturedVolumeSlider(value: Binding(
                                get: { Double(appState.volume) },
                                set: { appState.volume = Float($0) }
                            ), wheelController: wheelController)
                            .frame(width: 107, height: 24)
                            .offset(x: 8, y: 8)
                            .transition(.opacity)
                        }
                        expandedSpeaker.offset(x: 111, y: 2)
                    }
                    .frame(width: 149, height: 40, alignment: .topLeading)
                    .background(alignment: .trailing) {
                        Color.clear
                            .frame(width: isPresented ? 149 : 36, height: 40)
                            .modifier(GlassEffectModifier(shape: .capsule))
                    }
                    .opacity(isPresented ? 1 : 0)
                    .allowsHitTesting(isPresented)
                    .accessibilityHidden(!isPresented)
                    .background {
                        if isPresented { VolumeDismissObserver { isPresented = false } }
                    }
                    .offset(x: 2, y: 2)
                }
                .onAppear {
                    wheelController.readVolume = { Double(appState.volume) }
                    wheelController.writeVolume = { appState.volume = Float($0) }
                }
                .onDisappear { wheelController.cancel() }
        }

        private var volumeSymbol: String {
            appState.volume <= 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        }
    }

    /// A real NSSlider retains native keyboard/focus/AX adjustment, but owns its
    /// captured flat rail rendering and pointer mapping. No permanent thumb was
    /// visible in the reference; hover/drag-specific decoration remains unknown.
    private struct CapturedVolumeSlider: NSViewRepresentable {
        @Binding var value: Double
        let wheelController: FooterVolumeWheelController

        func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

        func makeNSView(context: Context) -> RailSlider {
            let slider = RailSlider(frame: NSRect(x: 0, y: 0, width: 107, height: 24))
            slider.minValue = 0
            slider.maxValue = 1
            slider.isContinuous = true
            slider.wheelController = wheelController
            context.coordinator.wheelController = wheelController
            // Retain keyboard/AX adjustment without AppKit's accent-colored ring.
            slider.focusRingType = .none
            slider.target = context.coordinator
            slider.action = #selector(Coordinator.changed(_:))
            slider.setAccessibilityIdentifier("FooterVolumeSlider")
            slider.setAccessibilityLabel("Volume")
            return slider
        }

        func updateNSView(_ slider: RailSlider, context: Context) {
            context.coordinator.value = $value
            slider.doubleValue = min(1, max(0, value))
            slider.needsDisplay = true
        }

        static func dismantleNSView(_ slider: RailSlider, coordinator: Coordinator) {
            slider.wheelController?.pointerTracking = false
            slider.wheelController?.cancel()
        }

        @MainActor final class Coordinator: NSObject {
            var value: Binding<Double>
            var wheelController: FooterVolumeWheelController?
            init(value: Binding<Double>) { self.value = value }
            @objc func changed(_ slider: NSSlider) {
                wheelController?.cancel()
                value.wrappedValue = min(1, max(0, slider.doubleValue))
                slider.needsDisplay = true
            }
        }

        final class RailSlider: NSSlider {
            var wheelController: FooterVolumeWheelController?
            private var isPointerTracking = false
            override var intrinsicContentSize: NSSize { NSSize(width: 107, height: 24) }

            private var rail: NSRect {
                NSRect(x: 8, y: (bounds.height - 8) / 2, width: bounds.width - 16, height: 8)
            }

            override func draw(_ dirtyRect: NSRect) {
                // Response_4, September 9 light/empty capture: extended-sRGB black
                // track alpha .2; opaque black fill. Dark colors remain provisional.
                // Captured layer compositingFilter is "plusD". Public SDK exposes
                // plusDarker but does not establish equivalence to that private
                // layer filter (or its backdrop scope); blending remains unresolved.
                let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let trackColor = isDark
                    ? NSColor.labelColor.withAlphaComponent(0.16)
                    : NSColor(colorSpace: .extendedSRGB, components: [0, 0, 0, 0.2], count: 4)
                let fillColor = isDark
                    ? NSColor.white.withAlphaComponent(0.52)
                    : NSColor(colorSpace: .extendedSRGB, components: [0, 0, 0, 1], count: 4)
                trackColor.setFill()
                NSBezierPath(roundedRect: rail, xRadius: 4, yRadius: 4).fill()
                let amount = min(1, max(0, doubleValue))
                if amount > 0 {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: rail, xRadius: 4, yRadius: 4).addClip()
                    fillColor.setFill()
                    NSRect(x: rail.minX, y: rail.minY,
                           width: rail.width * amount, height: rail.height).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
            }

            override func accessibilityFrame() -> NSRect {
                guard let window else { return super.accessibilityFrame() }
                return window.convertToScreen(convert(bounds, to: nil))
            }

            override func mouseDown(with event: NSEvent) {
                guard isEnabled, let window else { return }
                wheelController?.cancel()
                window.makeFirstResponder(self)
                isPointerTracking = true
                wheelController?.pointerTracking = true
                updatePointer(event)
            }

            override func mouseDragged(with event: NSEvent) {
                guard isEnabled, isPointerTracking else { return }
                updatePointer(event)
            }

            override func mouseUp(with event: NSEvent) {
                guard isPointerTracking else { return }
                isPointerTracking = false
                wheelController?.pointerTracking = false
                guard isEnabled else { return }
                updatePointer(event)
            }

            override func scrollWheel(with event: NSEvent) {
                guard isEnabled, !isPointerTracking else { return }
                wheelController?.scrollWheel(with: event)
            }

            private func updatePointer(_ event: NSEvent) {
                guard rail.width > 0 else { return }
                let point = convert(event.locationInWindow, from: nil)
                setVolume((point.x - rail.minX) / rail.width)
            }

            private func setVolume(_ value: Double) {
                guard value.isFinite else { return }
                let bounded = min(1, max(0, value))
                guard bounded != doubleValue else { return }
                doubleValue = bounded
                needsDisplay = true
                sendAction(action, to: target)
            }
        }
    }

    /// Local event observation does not activate the app or consume outside clicks.
    /// Native hierarchy contains an outside-click detector; exact timing is unverified.
    private struct VolumeDismissObserver: NSViewRepresentable {
        let dismiss: () -> Void

        func makeNSView(context: Context) -> DismissView {
            let view = DismissView()
            view.dismiss = dismiss
            return view
        }

        func updateNSView(_ view: DismissView, context: Context) {
            view.dismiss = dismiss
        }

        static func dismantleNSView(_ view: DismissView, coordinator: ()) {
            view.stopObserving()
        }

        final class DismissView: NSView {
            var dismiss: (() -> Void)?
            private var monitor: Any?

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                stopObserving()
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
                ) { [weak self] event in
                    guard let self else { return event }
                    if event.type == .keyDown {
                        if event.keyCode == 53, event.window === self.window {
                            self.dismiss?()
                            return nil
                        }
                    } else if event.window !== self.window ||
                                !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                        self.dismiss?()
                    }
                    return event
                }
            }

            func stopObserving() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
        }
    }

    // MARK: - Helpers

    private func navigateToAlbum(_ albumId: String) {
        guard !albumId.isEmpty else { return }
        appState.navigationTargetSongId = nil  // Clear any song highlight
        appState.navigationTargetArtistId = nil
        appState.navigationTargetAlbumId = albumId
        appState.selectedSidebarItem = .albums
    }

    private func navigateToAlbumWithSong(albumId: String, songId: String) {
        guard !albumId.isEmpty else { return }
        appState.navigationTargetArtistId = nil
        appState.navigationTargetSongId = songId  // Highlight this song
        appState.navigationTargetAlbumId = albumId
        appState.selectedSidebarItem = .albums
    }

    private func navigateToArtist(_ artistId: String) {
        guard !artistId.isEmpty else { return }
        appState.navigationTargetAlbumId = nil
        appState.navigationTargetSongId = nil
        appState.navigationTargetArtistId = artistId
        appState.selectedSidebarItem = .artists
    }

    private func resumeFromHistory() async {
        let history = (try? appState.databaseManager.loadPlayHistory(
            serverId: appState.activeServerId,
            limit: 1
        )) ?? []

        if let lastPlayed = history.first {
            do {
                let songs = appState.visibleSongsForPlayback(
                    try await appState.networkActor.fetchAlbumSongs(albumId: lastPlayed.albumId)
                )
                if let startIndex = songs.firstIndex(where: { $0.id == lastPlayed.songId }) {
                    await appState.playbackManager.play(songs: Array(songs.suffix(from: startIndex)))
                    return
                } else if !songs.isEmpty {
                    await appState.playbackManager.play(songs: songs)
                    return
                }
            } catch {
                print("Failed to resume from history: \(error)")
            }
        }

        // Fallback: play a random album ("Made for You")
        do {
            let albums = try await appState.networkActor.fetchAlbums(type: .random, size: 1)
            if let album = albums.first {
                let songs = try await appState.playableAlbumSongs(for: album)
                await appState.playbackManager.play(songs: songs)
            }
        } catch {
            print("Failed to play random album: \(error)")
        }
    }

    private var repeatIcon: String {
        switch observedRepeatMode {
        case .off: return "repeat"
        case .all: return "repeat.circle.fill"
        case .one: return "repeat.1"
        }
    }

    private var repeatAccessibilityLabel: String {
        switch observedRepeatMode {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds: Int
        if !time.isFinite || time <= 0 {
            totalSeconds = 0
        } else if time >= Double(Int.max) {
            totalSeconds = Int.max
        } else {
            totalSeconds = Int(time)
        }
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

// MARK: - Album Art Menu Button (left-click = menu, same as right-click)

private struct AlbumArtMenuButton: View {
    @Environment(AppState.self) private var appState
    let song: Song
    let size: CGFloat

    var body: some View {
        Menu {
            menuItems
        } label: {
            EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .miniBar)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .contextMenu {
                    menuItems
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: size, height: size)
        .accessibilityLabel("\(song.title) artwork actions")
        .accessibilityHint("Show actions for the current track")
        .accessibilityIdentifier("FooterArtworkMenu")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button { navigateToAlbum(song.albumId) } label: {
            Label("Go to Album", systemImage: "square.stack")
        }
        .disabled(song.albumId.isEmpty)
        Divider()
        Button { appState.showMiniPlayer() } label: {
            Label("MiniPlayer", systemImage: "pip")
        }
        Button { appState.enterImmersiveMode() } label: {
            Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
        }
    }

    private func navigateToAlbum(_ albumId: String) {
        guard !albumId.isEmpty else { return }
        appState.navigationTargetSongId = nil
        appState.navigationTargetArtistId = nil
        appState.navigationTargetAlbumId = albumId
        appState.selectedSidebarItem = .albums
    }
}

// MARK: - AutoPlay Toggle

struct AutoPlayToggle: View {
    @Environment(AppState.self) private var appState
    @State private var isHovered = false

    var body: some View {
        Button {
            appState.isAutoPlayEnabled.toggle()
        } label: {
            Image(systemName: "infinity")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(appState.isAutoPlayEnabled ? Color.accentColor : .secondary)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Marquee Text (shows ... when truncated, smooth scroll after 1s hover)

struct MarqueeText: View {
    let text: String
    let font: Font
    var color: Color = .primary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var shouldScroll = false
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var scrollTask: Task<Void, Never>?

    private let scrollSpeed: CGFloat = 30
    private let hoverDelay: TimeInterval = 1.0
    private let pauseAtEnd: TimeInterval = 1.0

    private var isTruncated: Bool {
        textWidth > containerWidth && containerWidth > 0
    }

    var body: some View {
        GeometryReader { geometry in
            let containerW = geometry.size.width

            ZStack(alignment: .leading) {
                // Hidden: measure full text width
                Text(text)
                    .font(font)
                    .fixedSize()
                    .background(GeometryReader { textGeo in
                        Color.clear
                            .onAppear { textWidth = textGeo.size.width }
                            .onChange(of: text) { _, _ in
                                textWidth = textGeo.size.width
                                resetScroll()
                                if isHovered && isTruncated { startScrollAfterDelay() }
                            }
                    })
                    .hidden()

                // DEFAULT: Truncated with ellipsis
                if !shouldScroll {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .frame(maxWidth: containerW, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // SCROLLING: Full text that moves smoothly
                if shouldScroll {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .fixedSize()
                        .offset(x: offset)
                }
            }
            .frame(width: containerW, alignment: .leading)
            .clipped()
            .onAppear {
                containerWidth = containerW
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                containerWidth = newWidth
                resetScroll()
                if isHovered && isTruncated { startScrollAfterDelay() }
            }
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering && isTruncated && !reduceMotion {
                startScrollAfterDelay()
            } else {
                resetScroll()
            }
        }
        .onChange(of: reduceMotion) { _, isReduced in
            if isReduced {
                resetScroll()
            } else if isHovered && isTruncated {
                startScrollAfterDelay()
            }
        }
        .onDisappear { resetScroll() }
    }

    private var scrollDuration: TimeInterval {
        guard textWidth > containerWidth else { return 0 }
        let distance = textWidth - containerWidth + 20
        return Double(distance) / Double(scrollSpeed)
    }

    private func startScrollAfterDelay() {
        scrollTask?.cancel()
        guard isHovered, isTruncated, !reduceMotion else { return }

        scrollTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(hoverDelay))
            } catch {
                return
            }
            guard !Task.isCancelled, isHovered, isTruncated, !reduceMotion else { return }
            shouldScroll = true
            offset = 0

            while !Task.isCancelled, isHovered, isTruncated, !reduceMotion {
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
                guard !Task.isCancelled, isHovered, isTruncated, !reduceMotion else { return }

                let distance = textWidth - containerWidth + 20
                withAnimation(.linear(duration: scrollDuration)) {
                    offset = -distance
                }
                do {
                    try await Task.sleep(for: .seconds(scrollDuration))
                } catch {
                    return
                }
                guard !Task.isCancelled, isHovered, isTruncated, !reduceMotion else { return }
                offset = 0

                do {
                    try await Task.sleep(for: .seconds(pauseAtEnd))
                } catch {
                    return
                }
            }
        }
    }

    private func resetScroll() {
        scrollTask?.cancel()
        scrollTask = nil
        shouldScroll = false
        offset = 0
    }
}

/// Shared by the open rail and the closed speaker hit region. Wheel deltas
/// accumulate into a bounded target; a short, monotonic ramp smooths BOTH the
/// displayed rail and actual audio gain without overshoot or queued detents.
/// Calibration is application tuning, not a recovered Apple timing constant.
@MainActor
final class FooterVolumeWheelController {
    var readVolume: () -> Double = { 1 }
    var writeVolume: (Double) -> Void = { _ in }
    var pointerTracking = false
    private(set) var targetVolume: Double?
    private var timer: Timer?
    private var lastTick = 0.0
    private var response = 0.045

    func scrollWheel(with event: NSEvent) {
        guard !pointerTracking, event.momentumPhase.isEmpty else { return }
        let x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let delta = abs(y) >= abs(x) ? y : x
        guard delta.isFinite, delta != 0 else { return }
        let current = readVolume()
        guard current.isFinite else { return }
        let step = event.hasPreciseScrollingDeltas ? 0.0025 : 0.02
        let target = min(1, max(0, (targetVolume ?? current) + Double(delta) * step))
        targetVolume = target
        response = event.hasPreciseScrollingDeltas ? 0.028 : 0.045
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || abs(target - current) < 0.0001 {
            writeVolume(target)
            cancel()
            return
        }
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let next = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    private func tick() {
        guard let target = targetVolume else { cancel(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, now - lastTick)
        lastTick = now
        let current = readVolume()
        let next = current + (target - current) * (1 - exp(-elapsed / response))
        if abs(target - next) < 0.0001 {
            writeVolume(target)
            cancel()
        } else {
            writeVolume(next)
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        targetVolume = nil
    }
}

private struct VolumeWheelRegion: NSViewRepresentable {
    let controller: FooterVolumeWheelController
    func makeNSView(context: Context) -> FooterVolumeWheelRegion {
        let view = FooterVolumeWheelRegion()
        view.controller = controller
        return view
    }
    func updateNSView(_ view: FooterVolumeWheelRegion, context: Context) { view.controller = controller }
    static func dismantleNSView(_ view: FooterVolumeWheelRegion, coordinator: ()) { view.stopMonitoring() }
}

/// Observe wheel events only inside this speaker's own window-local bounds;
/// the SwiftUI button remains the click target and never has to expand first.
final class FooterVolumeWheelRegion: NSView {
    var controller: FooterVolumeWheelController?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScrollWheel(event, in: event.window, at: event.locationInWindow) == true ? nil : event
        }
    }
    @discardableResult
    func handleScrollWheel(_ event: NSEvent, in sourceWindow: NSWindow?, at point: NSPoint) -> Bool {
        guard let window, sourceWindow === window, !isHiddenOrHasHiddenAncestor,
              bounds.contains(convert(point, from: nil)), let controller else { return false }
        controller.scrollWheel(with: event)
        return true
    }
    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

#Preview {
    NowPlayingBar()
        .environment(AppState())
}
