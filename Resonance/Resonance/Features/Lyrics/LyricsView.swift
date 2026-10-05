import SwiftUI
import AppKit

struct LyricsView: View {
    /// Captured presentation-specific spacing; plain lyrics retain their layout.
    var syncedLineSpacing: CGFloat = 16

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lyrics: Lyrics = .empty
    @State private var currentLineIndex: Int = -1
    @State private var loadGeneration = UUID()
    @State private var viewState: ViewState = .loading
    /// True while the reader drags the panel. Automatic scrolling pauses so a
    /// manual scroll position is never fought by playback ticks, and resumes
    /// after a short idle interval or on song change.
    @State private var isUserScrolling = false
    @State private var scrollResumeTask: Task<Void, Never>?
    @State private var retryLoadTask: Task<Void, Never>?

    private struct LyricsIdentity: Equatable {
        let serverID: String?
        let songID: String?
    }

    private var lyricsIdentity: LyricsIdentity {
        LyricsIdentity(serverID: appState.activeServerId, songID: appState.nowPlaying?.id)
    }

    private enum ViewState: Equatable {
        case noSong
        case loading
        case empty
        case error(String)
        case populated
    }

    /// How long automatic scrolling stays suspended after a manual drag.
    private static let manualScrollResumeInterval: Duration = .seconds(4)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                switch viewState {
                case .noSong:
                    CompactStatusView(
                        title: "Nothing Playing",
                        systemImage: "music.note",
                        message: "Play a song to follow along with its lyrics."
                    )
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                case .loading:
                    InlineLoadingStatusView(title: "Loading lyrics...")
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                case .empty:
                    CompactStatusView(
                        title: "No Lyrics",
                        systemImage: "quote.bubble",
                        message: "Lyrics are not available for this track."
                    )
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                case .error(let message):
                    CompactStatusView(
                        title: "Couldn't Load Lyrics",
                        systemImage: "exclamationmark.triangle",
                        message: message,
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise"
                    ) {
                        retryLyrics()
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                case .populated:
                    LazyVStack(spacing: lyrics.isSynced ? syncedLineSpacing : 16) {
                        ForEach(lyrics.lines.indices, id: \.self) { index in
                            let line = lyrics.lines[index]
                            let identity = lyricsIdentity
                            let isSeekable = lyrics.isSynced
                                && line.timestamp != nil
                                && appState.playbackManager.currentSourceSupportsSeeking
                            LyricLineView(
                                line: line,
                                isCurrent: lyrics.isSynced && index == currentLineIndex,
                                isSeekable: isSeekable,
                                onTap: {
                                    guard let timestamp = line.timestamp else { return }
                                    Task { @MainActor in
                                        guard identity == lyricsIdentity,
                                              appState.playbackManager.currentSourceSupportsSeeking else { return }
                                        await appState.playbackManager.seek(to: timestamp)
                                    }
                                }
                            )
                            .id(index)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8).onChanged { _ in
                    suspendAutomaticScrolling()
                }
            )
            // Wheel/trackpad scrolling does not produce a DragGesture on macOS.
            // This non-hit-testing observer uses a view-scoped local event
            // monitor and passes every event through to the ScrollView.
            .background {
                GeometryReader { geometry in
                    LyricsScrollWheelObserver(onScroll: suspendAutomaticScrolling)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: currentLineIndex) { _, newIndex in
                // Never fight the reader's manual scroll position; the resume
                // task restores automatic following after the idle interval.
                // Loading and populated branches must not overlap in an
                // animated ScrollViewReader transaction while an inspector is
                // also establishing its split-view fitting constraints.
                guard viewState == .populated,
                      !isUserScrolling, newIndex >= 0 else { return }
                scrollToCurrentLine(proxy, index: newIndex)
            }
            .task(id: viewState) {
                // Install the populated LazyVStack before asking its reader to
                // resolve an ID. Initial positioning is deliberately not
                // animated; later playback-driven line changes still are.
                guard viewState == .populated,
                      currentLineIndex >= 0 else { return }
                await Task.yield()
                guard !Task.isCancelled,
                      viewState == .populated,
                      currentLineIndex >= 0 else { return }
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    proxy.scrollTo(currentLineIndex, anchor: .center)
                }
            }
            .onChange(of: isUserScrolling) { wasScrolling, isScrolling in
                guard wasScrolling, !isScrolling, currentLineIndex >= 0 else { return }
                scrollToCurrentLine(proxy, index: currentLineIndex)
            }
        }
        .onChange(of: appState.currentTime) { _, time in
            updateCurrentLine(for: time)
        }
        .task(id: lyricsIdentity) {
            // Song/server changes cancel the previous presentation task.
            retryLoadTask?.cancel()
            retryLoadTask = nil
            endUserScrollSuspension()
            await loadLyrics()
        }
        .onDisappear {
            loadGeneration = UUID()
            retryLoadTask?.cancel()
            retryLoadTask = nil
            endUserScrollSuspension()
        }
    }

    // MARK: - Scrolling

    private func scrollToCurrentLine(_ proxy: ScrollViewProxy, index: Int) {
        if reduceMotion {
            proxy.scrollTo(index, anchor: .center)
        } else {
            withAnimation(.easeOut(duration: 0.35)) {
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private func suspendAutomaticScrolling() {
        isUserScrolling = true
        scrollResumeTask?.cancel()
        scrollResumeTask = Task {
            try? await Task.sleep(for: Self.manualScrollResumeInterval)
            guard !Task.isCancelled else { return }
            isUserScrolling = false
        }
    }

    private func endUserScrollSuspension() {
        scrollResumeTask?.cancel()
        scrollResumeTask = nil
        isUserScrolling = false
    }

    // MARK: - Loading

    private func retryLyrics() {
        retryLoadTask?.cancel()
        retryLoadTask = Task { await loadLyrics() }
    }

    private func loadLyrics() async {
        guard !Task.isCancelled else { return }
        let identity = lyricsIdentity
        let generation = UUID()
        loadGeneration = generation
        lyrics = .empty
        viewState = .loading
        currentLineIndex = -1

        if DeterministicCaptureFixture.isEnabled {
            let requestedState = ProcessInfo.processInfo.environment["RESONANCE_PARITY_STATE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch requestedState {
            case "loading":
                return
            case "error":
                lyrics = .empty
                viewState = .error("The deterministic fixture requested the unavailable state.")
                return
            case "none", "no-lyrics", "no_lyrics", "empty":
                lyrics = .empty
                viewState = .empty
                return
            default:
                break
            }
        }

        guard let song = appState.nowPlaying else {
            lyrics = .empty
            viewState = .noSong
            return
        }

        // Use LyricsService (handles caching and multiple sources).
        let result = await appState.lyricsService.lookupLyrics(for: song)
        // Includes same-song retries and A → B → A transitions; identity alone
        // would not reject an older A response after returning to that song.
        guard !Task.isCancelled, generation == loadGeneration,
              identity == lyricsIdentity else { return }
        switch result {
        case .found(let cached):
            guard let lyricsText = cached.preferredLyricsText else {
                lyrics = .empty
                viewState = .empty
                return
            }

            do {
                let parsed = try await LyricsDocumentParser.parse(lyricsText)
                guard !Task.isCancelled, generation == loadGeneration,
                      identity == lyricsIdentity else { return }
                lyrics = parsed
                updateCurrentLine(for: appState.currentTime)
                viewState = lyrics.isEmpty ? .empty : .populated
            } catch is CancellationError {
                return
            } catch LyricsParsingError.payloadTooLarge {
                guard generation == loadGeneration, identity == lyricsIdentity else { return }
                lyrics = .empty
                viewState = .error("The lyrics data is too large to display safely.")
            } catch {
                guard generation == loadGeneration, identity == lyricsIdentity else { return }
                lyrics = .empty
                viewState = .error("The lyrics data could not be read.")
            }
        case .notFound:
            lyrics = .empty
            viewState = .empty
        case .failed:
            lyrics = .empty
            viewState = .error("Check your connection and try again.")
        }
    }

    private func updateCurrentLine(for time: TimeInterval) {
        guard lyrics.isSynced else {
            currentLineIndex = -1
            return
        }

        // Scan newest-first so missing or duplicated timestamps resolve to the
        // latest line that has started, deterministically.
        for (index, line) in lyrics.lines.enumerated().reversed() {
            if let timestamp = line.timestamp, timestamp <= time {
                if currentLineIndex != index {
                    currentLineIndex = index
                }
                return
            }
        }
        // Seeking before the first timestamp must clear the previous highlight.
        currentLineIndex = -1
    }
}

struct LyricLineView: View {
    let line: LyricLine
    let isCurrent: Bool
    var isSeekable: Bool = false
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if isSeekable {
            Button(action: onTap) {
                lyricText
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.text)
            .accessibilityHint("Seek playback to this line")
        } else {
            lyricText
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.text)
        }
    }

    /// Fixed type size: emphasis comes from weight, color, and dimming, so a
    /// line change never reflows the surrounding verse.
    private var lyricText: some View {
        Text(line.text)
            .font(.title3)
            .fontWeight(isCurrent ? .semibold : .regular)
            .foregroundStyle(foregroundStyle)
            .multilineTextAlignment(.center)
            .opacity(opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isCurrent)
    }

    private var foregroundStyle: some ShapeStyle {
        if isCurrent {
            return AnyShapeStyle(.primary)
        } else {
            return AnyShapeStyle(.secondary)
        }
    }

    private var opacity: Double {
        line.isBackground ? (isCurrent ? 0.8 : 0.55) : 1.0
    }
}

/// Observes only scroll-wheel events delivered to the lyrics viewport. Returning
/// each event unchanged leaves wheel and trackpad scrolling owned by SwiftUI's
/// ScrollView; the monitor is removed with this presentation and is not global.
private struct LyricsScrollWheelObserver: NSViewRepresentable {
    let onScroll: () -> Void

    func makeNSView(context: Context) -> ScrollObserverView {
        let view = ScrollObserverView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: ScrollObserverView, context: Context) {
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: ScrollObserverView, coordinator: ()) {
        view.stopObserving()
    }

    final class ScrollObserverView: NSView {
        var onScroll: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else {
                    return event
                }
                self.onScroll?()
                return event
            }
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

// MARK: - LRC Parser

enum LyricsParsingError: Error, Equatable {
    case payloadTooLarge
}

enum LyricsDocumentParser {
    /// Far above normal song lyrics while preventing malformed metadata from
    /// materializing an effectively unbounded SwiftUI view tree.
    static let maximumUTF8Bytes = 2 * 1_024 * 1_024
    static let maximumDisplayedLines = 20_000

    static func parse(_ content: String) async throws -> Lyrics {
        let parsingTask = Task.detached(priority: .userInitiated) {
            guard content.utf8.count <= maximumUTF8Bytes else {
                throw LyricsParsingError.payloadTooLarge
            }
            let lines = try LRCParser.parseCancellable(
                content,
                maximumLines: maximumDisplayedLines
            )
            return Lyrics(
                lines: lines,
                isSynced: lines.contains { $0.timestamp != nil }
            )
        }

        return try await withTaskCancellationHandler {
            try await parsingTask.value
        } onCancel: {
            parsingTask.cancel()
        }
    }
}

struct LRCParser {
    static func parse(_ content: String) -> [LyricLine] {
        (try? parseCancellable(content, maximumLines: .max)) ?? []
    }

    static func parseCancellable(_ content: String, maximumLines: Int) throws -> [LyricLine] {
        var lines: [LyricLine] = []

        let pattern = #"\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        for line in content.components(separatedBy: .newlines) {
            try Task.checkCancellation()
            let range = NSRange(line.startIndex..., in: line)

            if let match = regex.firstMatch(in: line, range: range) {
                guard let minutesRange = Range(match.range(at: 1), in: line),
                      let secondsRange = Range(match.range(at: 2), in: line),
                      let centisRange = Range(match.range(at: 3), in: line),
                      let textRange = Range(match.range(at: 4), in: line) else {
                    continue
                }

                let minutes = Int(line[minutesRange]) ?? 0
                let seconds = Int(line[secondsRange]) ?? 0
                let fractionDigits = line[centisRange]
                let fraction = Int(fractionDigits) ?? 0
                // Precision comes from digit count, not magnitude: .003 is
                // three milliseconds, while .03 is thirty milliseconds.
                let divisor = fractionDigits.count == 3 ? 1000.0 : 100.0
                let timestamp = Double(minutes * 60 + seconds) + Double(fraction) / divisor
                let text = String(line[textRange]).trimmingCharacters(in: .whitespaces)
                let isBackground = text.hasPrefix("(") && text.hasSuffix(")")

                if !text.isEmpty {
                    guard lines.count < maximumLines else {
                        throw LyricsParsingError.payloadTooLarge
                    }
                    lines.append(LyricLine(timestamp: timestamp, text: text, isBackground: isBackground))
                }
            } else {
                // Unsynced line
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("[") {
                    guard lines.count < maximumLines else {
                        throw LyricsParsingError.payloadTooLarge
                    }
                    lines.append(LyricLine(text: trimmed))
                }
            }
        }

        return lines.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
    }
}

#Preview {
    LyricsView()
        .environment(AppState())
        .frame(width: 300, height: 500)
}
