import AppKit
import Observation

// MARK: - MiniPlayer mode

enum MiniPlayerMode: String, CaseIterable {
    case art
    case queue
    case lyrics

    static let compositorSize = CGSize(width: 320, height: 320)
    private static let userDefaultsKey = "miniPlayerMode"

    var next: MiniPlayerMode {
        switch self {
        case .art: return .queue
        case .queue: return .lyrics
        case .lyrics: return .art
        }
    }

    var accessibilityName: String {
        switch self {
        case .art: return "Artwork"
        case .queue: return "Playing Next"
        case .lyrics: return "Lyrics"
        }
    }

    /// Modes are compositor content, never window sizes.
    var size: CGSize { Self.compositorSize }

    static var persisted: MiniPlayerMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
                  let mode = MiniPlayerMode(rawValue: raw) else {
                return .art
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
        }
    }
}

// MARK: - Native MiniPlayer ownership

/// The native MiniPlayer evidence reports a titled, full-size-content window
/// whose outer frame is 320×320. This subclass makes that geometry an AppKit
/// invariant: AppKit chrome may change the origin, but never the outer size.
final class MiniPlayerWindow: NSWindow {
    static let outerSize = NSSize(width: 320, height: 320)

    static func fixedOuterFrame(for frame: NSRect) -> NSRect {
        var fixed = frame
        fixed.size = outerSize
        return fixed
    }

    override class func frameRect(
        forContentRect contentRect: NSRect,
        styleMask: NSWindow.StyleMask
    ) -> NSRect {
        var frame = super.frameRect(forContentRect: contentRect, styleMask: styleMask)
        frame.size = outerSize
        return frame
    }

    override class func contentRect(
        forFrameRect frameRect: NSRect,
        styleMask: NSWindow.StyleMask
    ) -> NSRect {
        guard styleMask.contains(.fullSizeContentView) else {
            var content = super.contentRect(forFrameRect: frameRect, styleMask: styleMask)
            content.size = outerSize
            return content
        }

        // Full-size content deliberately shares the native outer coordinate
        // space; standard titlebar buttons remain owned by AppKit.
        return NSRect(origin: frameRect.origin, size: outerSize)
    }

    override func setFrame(
        _ frameRect: NSRect,
        display flag: Bool,
        animate animateFlag: Bool
    ) {
        super.setFrame(
            Self.fixedOuterFrame(for: frameRect),
            display: flag,
            animate: animateFlag
        )
    }

    func enforceFixedOuterFrame() {
        let fixed = Self.fixedOuterFrame(for: frame)
        guard frame.size != fixed.size else { return }
        super.setFrame(fixed, display: false, animate: false)
    }
}

/// Owns the direct AppKit compositor, standard AppKit chrome, and close
/// callback. AppState retains one controller for the lifetime of the window.
@MainActor
final class MiniPlayerWindowController: NSWindowController, NSWindowDelegate {
    static let outerSize = MiniPlayerWindow.outerSize
    static let frameAutosaveName = "MiniPlayer frame"

    private let onClose: (NSWindow) -> Void

    init(
        appState: AppState,
        initialMode: MiniPlayerMode,
        persistsModeChanges: Bool,
        autosavesFrame: Bool,
        level: NSWindow.Level,
        onClose: @escaping (NSWindow) -> Void
    ) {
        self.onClose = onClose

        let window = MiniPlayerWindow(
            contentRect: NSRect(origin: .zero, size: Self.outerSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.identifier = NSUserInterfaceItemIdentifier("miniPlayer")
        window.title = "Mini Player"
        window.setAccessibilityIdentifier("miniPlayer")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = level
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = Self.outerSize
        window.maxSize = Self.outerSize

        let hasSavedFrame = autosavesFrame
            && UserDefaults.standard.object(
                forKey: "NSWindow Frame \(Self.frameAutosaveName)"
            ) != nil
        if autosavesFrame {
            _ = window.setFrameAutosaveName(Self.frameAutosaveName)
        }

        let rootView = MiniPlayerView(
            appState: appState,
            initialMode: initialMode,
            persistsModeChanges: persistsModeChanges
        )
        rootView.translatesAutoresizingMaskIntoConstraints = true
        rootView.autoresizingMask = [.width, .height]
        rootView.frame = NSRect(origin: .zero, size: Self.outerSize)
        window.contentView = rootView

        window.delegate = self
        window.enforceFixedOuterFrame()
        if !hasSavedFrame {
            window.center()
        }
        window.enforceFixedOuterFrame()
    }

    required init?(coder: NSCoder) {
        fatalError("MiniPlayerWindowController does not support coder initialization")
    }

    var reportedOuterFrame: NSRect {
        window?.frame ?? .zero
    }

    var reportsNativeOuterSize: Bool {
        reportedOuterFrame.size == Self.outerSize
    }

    func present(activate: Bool) {
        guard let window = window as? MiniPlayerWindow else { return }
        window.enforceFixedOuterFrame()
        if activate {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        Self.outerSize
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onClose(window)
    }
}

// MARK: - Direct AppKit compositor

/// Public-AppKit reconstruction of Music.MPContentView. The view is flipped so
/// the captured top-left frames can be assigned literally, without a hosting
/// view or SwiftUI's content-layout negotiation.
@MainActor
final class MiniPlayerView: NSView {
    static let side: CGFloat = 320

    private enum TransportSlot: Int {
        case shuffle
        case previous
        case playPause
        case next
        case repeatMode
    }

    private final class FlippedVisualEffectView: NSVisualEffectView {
        override var isFlipped: Bool { true }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class VibrantView: NSView {
        override var allowsVibrancy: Bool { true }
    }

    private struct PendingScrub: Equatable {
        let songID: String
        let serverID: String?
        let target: TimeInterval
    }

    private final class TrackingSlider: NSSlider {
        var onTrackingChanged: ((Bool) -> Void)?

        override func mouseDown(with event: NSEvent) {
            onTrackingChanged?(true)
            defer { onTrackingChanged?(false) }
            super.mouseDown(with: event)
        }
    }

    let appState: AppState
    private let persistsModeChanges: Bool
    private var mode: MiniPlayerMode
    private var isHovering = false
    private var observationStarted = false
    private var observedSongID: String?
    private var observedArtworkID: String?
    private var artworkTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var pendingScrub: PendingScrub?
    private var isScrubberTracking = false
    private var trackingArea: NSTrackingArea?
    private var queueRows: [UUID: NSButton] = [:]

    // Direct role map from the captured Music subtree.
    private let contentVisualEffect = FlippedVisualEffectView()
    private let fullArtwork = NSImageView()
    private let blurPlane = FlippedVisualEffectView()
    private let titlePlatter = FlippedView()
    // Music's root is flipped, but these AppKit platters retain bottom-left
    // child coordinates. In particular the scrubber sits above its labels.
    private let scrubberContainer = NSView()
    private let scrubberPlatter = NSView()
    private let scrubber = TrackingSlider()
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "−0:00")
    private let transportContainer = VibrantView()
    private let transportPlatter = NSView()
    private var transportButtons: [NSButton] = []
    private let modeButton = NSButton()

    // Resonance-only content modes remain available for explicit callers and
    // fixture routes, but stay hidden in the artwork state.
    private let queueSurface = FlippedView()
    private let queueHeading = NSTextField(labelWithString: "Playing Next")
    private let queueCount = NSTextField(labelWithString: "0")
    private let lyricsSurface = FlippedView()
    private let lyricsHeading = NSTextField(labelWithString: "Lyrics")
    private let lyricsScrollView = NSScrollView()
    private let lyricsTextView = NSTextView()

    init(
        appState: AppState,
        initialMode: MiniPlayerMode? = nil,
        persistsModeChanges: Bool = !DeterministicCaptureFixture.isEnabled
    ) {
        self.appState = appState
        self.mode = initialMode ?? MiniPlayerMode.persisted
        self.persistsModeChanges = persistsModeChanges
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        configureView()
        refreshFromAppState()
    }

    required init?(coder: NSCoder) {
        fatalError("MiniPlayerView does not support coder initialization")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.side, height: Self.side)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        guard window != nil, !observationStarted else { return }
        observationStarted = true
        observeAppState()
    }

    override func layout() {
        super.layout()
        // The window and root are fixed at 320×320. Keep the full-window role
        // literal even if AppKit asks the root to lay itself out again.
        contentVisualEffect.frame = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        fullArtwork.frame = contentVisualEffect.frame
        blurPlane.frame.size.width = Self.side
        titlePlatter.frame = NSRect(x: 4, y: 157, width: 300, height: 48)
        scrubberContainer.frame = NSRect(x: 14, y: 215, width: 292, height: 39)
        scrubberPlatter.frame = NSRect(x: 2, y: 0, width: 288, height: 31)
        scrubber.frame = NSRect(x: 0, y: 19, width: 288, height: 12)
        transportContainer.frame = NSRect(x: 18, y: 270, width: 284, height: 32)
        transportPlatter.frame = NSRect(x: 0, y: 0, width: 284, height: 32)
        queueSurface.frame = bounds
        lyricsSurface.frame = bounds
        modeButton.frame = NSRect(x: 276, y: 12, width: 32, height: 32)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        updateAccessoryVisibility()
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let hovering = bounds.contains(convert(event.locationInWindow, from: nil))
        guard hovering != isHovering else { return }
        isHovering = hovering
        updateAccessoryVisibility()
    }


    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        updateAccessoryVisibility()
    }

    // MARK: Public mode entry

    func setMode(_ newMode: MiniPlayerMode) {
        guard mode != newMode else { return }
        mode = newMode
        if persistsModeChanges {
            MiniPlayerMode.persisted = newMode
        }
        refreshModeVisibility()
        reloadLyrics()
    }


    // MARK: Construction

    private func configureView() {
        // The direct root is an unstyled compositor; AppKit's theme frame owns
        // the window chrome and its outer corners.

        configureVisualEffect(contentVisualEffect, material: .popover, blending: .behindWindow)

        // The direct root order mirrors Music.MPContentView: effect plane,
        // artwork, hidden blur/title roles, then hover accessories.
        addSubview(contentVisualEffect)
        addSubview(fullArtwork)
        addSubview(blurPlane)
        addSubview(queueSurface)
        addSubview(lyricsSurface)
        addSubview(titlePlatter)
        addSubview(scrubberContainer)
        addSubview(transportContainer)
        addSubview(modeButton)

        fullArtwork.frame = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        fullArtwork.imageScaling = .scaleProportionallyUpOrDown
        fullArtwork.imageAlignment = .alignCenter
        fullArtwork.image = placeholderArtwork
        fullArtwork.isEditable = false
        fullArtwork.toolTip = "Mini Player Artwork"

        blurPlane.frame = NSRect(x: 0, y: 0, width: 320, height: 203)
        blurPlane.isHidden = true

        configureTitlePlatter()
        configureScrubber()
        configureTransport()
        configureQueueSurface()
        configureLyricsSurface()
        configureModeButton()
        refreshModeVisibility()
        updateAccessoryVisibility()
    }

    private func configureVisualEffect(
        _ view: NSVisualEffectView,
        material: NSVisualEffectView.Material,
        blending: NSVisualEffectView.BlendingMode
    ) {
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.isEmphasized = false
    }

    private func configureTitlePlatter() {
        titlePlatter.frame = NSRect(x: 4, y: 157, width: 300, height: 48)
        titlePlatter.isHidden = true
        titlePlatter.appearance = NSAppearance(named: .vibrantDark)

        let title = NSTextField(labelWithString: "")
        // Native unflipped stack (0,4,236,40), title (0,19,236,21),
        // subtitle (0,0,236,19), with an eight-point text inset. Convert
        // their origins into this flipped title platter's coordinate space.
        title.frame = NSRect(x: 8, y: 4, width: 228, height: 21)
        title.font = .systemFont(ofSize: 17, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.identifier = NSUserInterfaceItemIdentifier("miniPlayer.title")

        let artist = NSTextField(labelWithString: "")
        artist.frame = NSRect(x: 8, y: 25, width: 228, height: 19)
        artist.font = .systemFont(ofSize: 15)
        artist.textColor = .secondaryLabelColor
        artist.lineBreakMode = .byTruncatingTail
        artist.identifier = NSUserInterfaceItemIdentifier("miniPlayer.artist")

        titlePlatter.addSubview(title)
        titlePlatter.addSubview(artist)
    }

    private func configureScrubber() {
        scrubberContainer.frame = NSRect(x: 14, y: 215, width: 292, height: 39)
        scrubberContainer.isHidden = true
        scrubberPlatter.frame = NSRect(x: 2, y: 0, width: 288, height: 31)
        // Captured native scrubber platter uses VibrantDark independently
        // of the outer window appearance (Aug24 Response_2, 0x7767b91b00).
        scrubberPlatter.appearance = NSAppearance(named: .vibrantDark)
        scrubberContainer.addSubview(scrubberPlatter)

        configureTimeLabel(elapsedLabel, frame: NSRect(x: -2, y: 0, width: 27, height: 13), alignment: .left)
        configureTimeLabel(remainingLabel, frame: NSRect(x: 255, y: 0, width: 33, height: 13), alignment: .right)
        // Native elapsed field 0x775858d880 is semantic secondaryLabelColor.
        elapsedLabel.textColor = .secondaryLabelColor
        scrubberPlatter.addSubview(elapsedLabel)
        scrubberPlatter.addSubview(remainingLabel)

        scrubber.frame = NSRect(x: 0, y: 19, width: 288, height: 12)
        scrubber.minValue = 0
        scrubber.maxValue = 1
        scrubber.doubleValue = 0
        scrubber.isContinuous = false
        scrubber.onTrackingChanged = { [weak self] isTracking in
            self?.isScrubberTracking = isTracking
            if isTracking {
                self?.seekTask?.cancel()
                self?.seekTask = nil
                self?.pendingScrub = nil
            }
        }
        scrubber.controlSize = .small
        scrubber.trackFillColor = NSColor.labelColor.withAlphaComponent(0.65)
        scrubber.target = self
        scrubber.action = #selector(scrubberValueChanged(_:))
        scrubber.toolTip = "Track Position"
        scrubberPlatter.addSubview(scrubber)
    }

    private func configureTimeLabel(_ label: NSTextField, frame: NSRect, alignment: NSTextAlignment) {
        label.frame = frame
        label.alignment = alignment
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.backgroundColor = .clear
        label.isBordered = false
        label.lineBreakMode = .byTruncatingTail
    }

    private func configureTransport() {
        transportContainer.frame = NSRect(x: 18, y: 270, width: 284, height: 32)
        transportContainer.isHidden = true
        transportPlatter.frame = NSRect(x: 0, y: 0, width: 284, height: 32)
        transportContainer.addSubview(transportPlatter)

        let slots: [NSRect] = [
            NSRect(x: 0, y: 0, width: 32, height: 32),
            NSRect(x: 57, y: 0, width: 57, height: 32),
            NSRect(x: 114, y: 0, width: 56, height: 32),
            NSRect(x: 170, y: 0, width: 57, height: 32),
            NSRect(x: 252, y: 0, width: 32, height: 32)
        ]
        let labels = ["Shuffle", "Previous", "Play", "Next", "Repeat"]
        let symbols = ["shuffle", "backward.fill", "play.fill", "forward.fill", "repeat"]
        let pointSizes: [CGFloat] = [16, 20, 24, 20, 16]
        let buttonFrames: [NSRect] = [
            NSRect(x: 0, y: 0, width: 32, height: 32),
            NSRect(x: 11, y: -3, width: 34, height: 39),
            NSRect(x: 11, y: -6, width: 34, height: 44),
            NSRect(x: 12, y: -3, width: 34, height: 39),
            NSRect(x: 0, y: 0, width: 32, height: 32)
        ]

        for index in 0..<slots.count {
            // Slot allocation and the actual native button frame differ.
            let slot = NSView(frame: slots[index])
            let button = NSButton(frame: buttonFrames[index])
            button.tag = index
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = (
                index == TransportSlot.shuffle.rawValue
                    || index == TransportSlot.repeatMode.rawValue
            ) ? .secondaryLabelColor : .labelColor
            button.target = self
            button.action = #selector(transportAction(_:))
            button.toolTip = labels[index]
            button.setAccessibilityLabel(labels[index])
            button.image = transportImage(symbol: symbols[index], pointSize: pointSizes[index])
            transportButtons.append(button)
            slot.addSubview(button)
            transportPlatter.addSubview(slot)
        }
    }
    private func configureModeButton() {
        modeButton.frame = NSRect(x: 276, y: 12, width: 32, height: 32)
        modeButton.isBordered = false
        modeButton.bezelStyle = .regularSquare
        modeButton.imagePosition = .imageOnly
        modeButton.imageScaling = .scaleProportionallyDown
        modeButton.contentTintColor = .white
        modeButton.wantsLayer = true
        modeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        modeButton.layer?.cornerRadius = 16
        modeButton.target = self
        modeButton.action = #selector(cycleMode(_:))
        updateModeButton()
    }

    private func configureQueueSurface() {
        queueSurface.frame = bounds
        queueSurface.wantsLayer = true
        queueSurface.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        queueSurface.isHidden = true

        queueHeading.frame = NSRect(x: 16, y: 30, width: 230, height: 24)
        queueHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        queueHeading.textColor = .white
        queueCount.frame = NSRect(x: 230, y: 32, width: 34, height: 18)
        queueCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        queueCount.alignment = .right
        queueCount.textColor = NSColor.white.withAlphaComponent(0.6)
        queueSurface.addSubview(queueHeading)
        queueSurface.addSubview(queueCount)
    }

    private func configureLyricsSurface() {
        lyricsSurface.frame = bounds
        lyricsSurface.wantsLayer = true
        lyricsSurface.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        lyricsSurface.isHidden = true

        lyricsHeading.frame = NSRect(x: 16, y: 30, width: 288, height: 24)
        lyricsHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        lyricsHeading.textColor = .white
        lyricsSurface.addSubview(lyricsHeading)

        lyricsScrollView.frame = NSRect(x: 12, y: 62, width: 296, height: 244)
        lyricsScrollView.borderType = .noBorder
        lyricsScrollView.drawsBackground = false
        lyricsScrollView.hasVerticalScroller = true
        lyricsScrollView.hasHorizontalScroller = false
        lyricsScrollView.autohidesScrollers = true

        lyricsTextView.frame = NSRect(x: 0, y: 0, width: 296, height: 244)
        lyricsTextView.minSize = NSSize(width: 0, height: 244)
        lyricsTextView.maxSize = NSSize(width: 296, height: CGFloat.greatestFiniteMagnitude)
        lyricsTextView.isVerticallyResizable = true
        lyricsTextView.isHorizontallyResizable = false
        lyricsTextView.autoresizingMask = [.width]
        lyricsTextView.textContainer?.widthTracksTextView = true
        lyricsTextView.textContainer?.containerSize = NSSize(
            width: 296,
            height: CGFloat.greatestFiniteMagnitude
        )
        lyricsTextView.isEditable = false
        lyricsTextView.isSelectable = true
        lyricsTextView.drawsBackground = false
        lyricsTextView.textColor = .white
        lyricsTextView.font = .systemFont(ofSize: 13)
        lyricsTextView.textContainerInset = NSSize(width: 4, height: 4)
        lyricsTextView.string = "Lyrics are not available for this track."
        lyricsScrollView.documentView = lyricsTextView
        lyricsSurface.addSubview(lyricsScrollView)
    }

    // MARK: State and observation

    private func observeAppState() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            _ = self.appState.nowPlaying?.id
            _ = self.appState.nowPlaying?.coverArt
            _ = self.appState.playbackState
            _ = self.appState.currentTime
            _ = self.appState.duration
            _ = self.appState.shuffleEnabled
            _ = self.appState.playbackManager.repeatMode
            _ = self.appState.playbackManager.currentSourceSupportsSeeking
            _ = self.appState.playbackManager.canGoPrevious
            _ = self.appState.playbackManager.canGoNext
            _ = self.appState.queueManager.allUpcomingCount
            _ = self.appState.queueManager.upcomingItems(limit: 15)
        } onChange: { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshFromAppState()
                self.observeAppState()
            }
        }
    }

    private func refreshFromAppState() {
        let currentSongID = appState.nowPlaying?.id
        let currentArtworkID = appState.nowPlaying?.coverArt
        if currentArtworkID != observedArtworkID {
            observedArtworkID = currentArtworkID
            loadArtwork(for: currentArtworkID)
        }
        if currentSongID != observedSongID {
            observedSongID = currentSongID
            reloadLyrics()
        }

        if let song = appState.nowPlaying {
            updateTitle(song: song)
        }
        updateBlurFrame()
        updateScrubberState()
        updateTransportState()
        updateQueueSurface()
        refreshModeVisibility()
    }

    private func updateTitle(song: Song) {
        let labels = titlePlatter.subviews.compactMap { $0 as? NSTextField }
        guard labels.count >= 2 else { return }
        labels[0].stringValue = song.title
        labels[1].stringValue = "\(song.artist) — \(song.album)"
    }

    private func updateBlurFrame() {
        blurPlane.frame = NSRect(
            x: 0,
            y: 0,
            width: 320,
            height: appState.playbackState == .playing ? 185 : 203
        )
    }

    private func updateScrubberState() {
        let duration = appState.duration
        if let pendingScrub,
           (pendingScrub.songID != appState.nowPlaying?.id
            || pendingScrub.serverID != appState.activeServerId
            || !appState.playbackManager.currentSourceSupportsSeeking
            || !duration.isFinite || duration <= 0) {
            self.pendingScrub = nil
            seekTask?.cancel()
            seekTask = nil
        }

        let displayedTime = pendingScrub?.target ?? appState.currentTime
        let rawRatio = duration.isFinite && duration > 0 && displayedTime.isFinite
            ? displayedTime / duration
            : 0
        let ratio = rawRatio.isFinite ? max(0, min(1, rawRatio)) : 0
        if !isScrubberTracking {
            scrubber.doubleValue = ratio
        }
        scrubber.isEnabled = duration.isFinite
            && duration > 0
            && appState.playbackManager.currentSourceSupportsSeeking
        elapsedLabel.stringValue = formatTime(appState.currentTime)
        remainingLabel.stringValue = "−\(formatTime(max(0, duration - appState.currentTime)))"
    }

    private func updateTransportState() {
        guard transportButtons.count == 5 else { return }
        let shuffle = transportButtons[TransportSlot.shuffle.rawValue]
        shuffle.alphaValue = appState.shuffleEnabled ? 1 : 0.48
        shuffle.setAccessibilityValue(appState.shuffleEnabled ? "On" : "Off")

        let previous = transportButtons[TransportSlot.previous.rawValue]
        previous.isEnabled = appState.playbackManager.canGoPrevious
        previous.alphaValue = previous.isEnabled ? 1 : 0.35
        previous.toolTip = previous.isEnabled ? "Previous" : "No previous track available"

        let next = transportButtons[TransportSlot.next.rawValue]
        next.isEnabled = appState.playbackManager.canGoNext
        next.alphaValue = next.isEnabled ? 1 : 0.35
        next.toolTip = next.isEnabled ? "Next" : "No next track available"

        let repeatButton = transportButtons[TransportSlot.repeatMode.rawValue]
        repeatButton.alphaValue = appState.playbackManager.repeatMode == .off ? 0.48 : 1
        repeatButton.setAccessibilityValue(repeatAccessibilityValue)

        let playSymbol = appState.playbackState == .playing ? "pause.fill" : "play.fill"
        let playPause = transportButtons[TransportSlot.playPause.rawValue]
        playPause.image = transportImage(symbol: playSymbol, pointSize: 24)
        playPause.setAccessibilityLabel(appState.playbackState == .playing ? "Pause" : "Play")
        playPause.toolTip = appState.playbackState == .playing ? "Pause" : "Play"
        let repeatSymbol = appState.playbackManager.repeatMode == .one ? "repeat.1" : "repeat"
        repeatButton.image = transportImage(symbol: repeatSymbol, pointSize: 16)
    }

    private var repeatAccessibilityValue: String {
        switch appState.playbackManager.repeatMode {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "One"
        }
    }

    private func refreshModeVisibility() {
        let isArtwork = mode == .art
        fullArtwork.isHidden = !isArtwork
        queueSurface.isHidden = mode != .queue
        lyricsSurface.isHidden = mode != .lyrics
        updateModeButton()
        updateAccessoryVisibility()
    }

    private func updateModeButton() {
        let symbol: String
        switch mode.next {
        case .art: symbol = "photo"
        case .queue: symbol = "list.bullet"
        case .lyrics: symbol = "quote.bubble"
        }
        modeButton.image = transportImage(symbol: symbol, pointSize: 13)
        let label = "Show \(mode.next.accessibilityName)"
        modeButton.toolTip = label
        modeButton.setAccessibilityLabel(label)
    }

    private func updateAccessoryVisibility() {
        let visible = isHovering && mode == .art && appState.nowPlaying != nil
        titlePlatter.isHidden = !visible
        scrubberContainer.isHidden = !visible
        transportContainer.isHidden = !visible
        modeButton.alphaValue = isHovering ? 1 : 0.72
    }

    // MARK: Artwork

    private var placeholderArtwork: NSImage? {
        NSImage(systemSymbolName: "music.note", accessibilityDescription: "No artwork")?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 72, weight: .regular)
        )
    }

    private func loadArtwork(for coverArtID: String?) {
        artworkTask?.cancel()
        fullArtwork.image = placeholderArtwork
        guard let coverArtID, !coverArtID.isEmpty else { return }

        let cacheActor = appState.cacheActor
        let networkActor = appState.networkActor
        artworkTask = Task { [weak self] in
            if let image = await cacheActor.getArtworkImage(for: coverArtID, size: .extraLarge) {
                guard !Task.isCancelled else { return }
                self?.fullArtwork.image = image
                return
            }

            do {
                let data = try await networkActor.fetchCoverArt(
                    id: coverArtID,
                    size: Int(ArtworkSize.extraLarge.pointSize * 2)
                )
                try? await cacheActor.cacheArtworkWithImage(data, for: coverArtID, size: .extraLarge)
                guard !Task.isCancelled, let image = NSImage(data: data) else { return }
                self?.fullArtwork.image = image
            } catch {
                // Keep the same placeholder behavior as AlbumArtView.
            }
        }
    }

    // MARK: Queue and lyrics modes

    private func updateQueueSurface() {
        queueCount.stringValue = "\(appState.queueManager.allUpcomingCount)"
        let items = appState.queueManager.upcomingItems(limit: 7)
        let visibleIDs = Set(items.map(\.id))

        // Playback-time observation refreshes this surface every tick. Reuse
        // rows by queue identity so focused/accessibility targets are not
        // destroyed and recreated while a person is interacting with them.
        let staleIDs = queueRows.keys.filter { !visibleIDs.contains($0) }
        for id in staleIDs {
            queueRows.removeValue(forKey: id)?.removeFromSuperview()
        }

        for (index, item) in items.enumerated() {
            let row: NSButton
            if let existing = queueRows[item.id] {
                row = existing
            } else {
                row = makeQueueRow(for: item)
                queueRows[item.id] = row
                queueSurface.addSubview(row)
            }

            row.title = "\(item.song.title) — \(item.song.artist)"
            row.frame = NSRect(x: 16, y: 66 + CGFloat(index * 31), width: 288, height: 26)
            row.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
            row.setAccessibilityLabel("\(item.song.title), \(item.song.artist)")
            row.toolTip = "Play \(item.song.title)"
        }
    }

    private func makeQueueRow(for item: QueueItem) -> NSButton {
        let row = NSButton(
            title: "\(item.song.title) — \(item.song.artist)",
            target: self,
            action: #selector(queueRowAction(_:))
        )
        row.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        row.alignment = .left
        row.font = .systemFont(ofSize: 11)
        row.isBordered = false
        row.bezelStyle = .regularSquare
        row.contentTintColor = .white
        row.lineBreakMode = .byTruncatingTail
        return row
    }

    private func reloadLyrics() {
        lyricsTask?.cancel()
        guard mode == .lyrics, let song = appState.nowPlaying else {
            lyricsTextView.string = "Nothing Playing"
            return
        }

        lyricsTextView.string = "Loading lyrics…"
        let lyricsService = appState.lyricsService
        lyricsTask = Task { [weak self] in
            let cached = await lyricsService.getLyrics(for: song)
            guard !Task.isCancelled else { return }
            let text = cached?.syncedLyrics ?? cached?.plainLyrics
            self?.lyricsTextView.string = text?.isEmpty == false
                ? text!
                : "Lyrics are not available for this track."
        }
    }

    // MARK: Actions

    @objc private func cycleMode(_ sender: NSButton) {
        setMode(mode.next)
    }

    @objc private func transportAction(_ sender: NSButton) {
        switch TransportSlot(rawValue: sender.tag) {
        case .shuffle:
            appState.shuffleEnabled.toggle()
        case .previous:
            Task { await appState.playbackManager.previous() }
        case .playPause:
            Task { await appState.playbackManager.togglePlayPause() }
        case .next:
            Task { await appState.playbackManager.next() }
        case .repeatMode:
            switch appState.playbackManager.repeatMode {
            case .off: appState.playbackManager.repeatMode = .all
            case .all: appState.playbackManager.repeatMode = .one
            case .one: appState.playbackManager.repeatMode = .off
            }
        case nil:
            break
        }
    }

    @objc private func scrubberValueChanged(_ sender: NSSlider) {
        guard appState.duration.isFinite, appState.duration > 0,
              appState.playbackManager.currentSourceSupportsSeeking,
              let songID = appState.nowPlaying?.id else { return }
        let serverID = appState.activeServerId
        let target = min(appState.duration, max(0, sender.doubleValue * appState.duration))
        let pending = PendingScrub(songID: songID, serverID: serverID, target: target)
        seekTask?.cancel()
        pendingScrub = pending
        updateScrubberState()
        seekTask = Task { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  self.pendingScrub == pending,
                  self.appState.nowPlaying?.id == pending.songID,
                  self.appState.activeServerId == pending.serverID,
                  self.appState.playbackManager.currentSourceSupportsSeeking else { return }
            await self.appState.playbackManager.seek(to: pending.target)
            guard !Task.isCancelled, self.pendingScrub == pending else { return }
            self.pendingScrub = nil
            self.seekTask = nil
            self.updateScrubberState()
        }
    }

    @objc private func queueRowAction(_ sender: NSButton) {
        guard let rawID = sender.identifier?.rawValue,
              let id = UUID(uuidString: rawID) else { return }
        Task {
            guard let item = appState.queueManager.skipTo(id: id) else { return }
            await appState.playbackManager.play(song: item.song)
        }
    }

    // MARK: AppKit helpers

    private func transportImage(symbol: String, pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        )
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
