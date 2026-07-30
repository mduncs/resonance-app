import SwiftUI

struct LyricsView: View {
    @Environment(AppState.self) private var appState
    @State private var lyrics: Lyrics = .empty
    @State private var currentLineIndex: Int = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if lyrics.isEmpty {
                    CompactStatusView(
                        title: "No Lyrics",
                        systemImage: "quote.bubble",
                        message: "Lyrics are not available for this track."
                    )
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                            LyricLineView(
                                line: line,
                                isCurrent: index == currentLineIndex,
                                onTap: {
                                    if let timestamp = line.timestamp {
                                        Task {
                                            await appState.playbackManager.seek(to: timestamp)
                                        }
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
            .onChange(of: currentLineIndex) { _, newIndex in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .onChange(of: appState.currentTime) { _, time in
            updateCurrentLine(for: time)
        }
        .task {
            await loadLyrics()
        }
        .onChange(of: appState.nowPlaying?.id) { _, _ in
            Task {
                await loadLyrics()
            }
        }
    }

    private func loadLyrics() async {
        guard let song = appState.nowPlaying else {
            lyrics = .empty
            return
        }

        // Use LyricsService (handles caching and multiple sources)
        if let cached = await appState.lyricsService.getLyrics(for: song) {
            // Prefer synced lyrics, fall back to plain
            let lyricsText = cached.syncedLyrics ?? cached.plainLyrics ?? ""

            if !lyricsText.isEmpty {
                let parsedLines = LRCParser.parse(lyricsText)
                let isSynced = parsedLines.contains { $0.timestamp != nil }

                if parsedLines.isEmpty {
                    // Plain text lyrics (no timestamps) - split by newlines
                    let plainLines = lyricsText.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .map { LyricLine(text: $0) }
                    lyrics = Lyrics(lines: plainLines, isSynced: false)
                } else {
                    lyrics = Lyrics(lines: parsedLines, isSynced: isSynced)
                }
            } else {
                lyrics = .empty
            }
        } else {
            lyrics = .empty
        }
        currentLineIndex = 0
    }

    private func updateCurrentLine(for time: TimeInterval) {
        guard lyrics.isSynced else { return }

        for (index, line) in lyrics.lines.enumerated().reversed() {
            if let timestamp = line.timestamp, timestamp <= time {
                if currentLineIndex != index {
                    currentLineIndex = index
                }
                return
            }
        }
    }
}

struct LyricLineView: View {
    let line: LyricLine
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        Text(line.text)
            .font(isCurrent ? .title2 : .body)
            .fontWeight(isCurrent ? .semibold : .regular)
            .foregroundStyle(foregroundStyle)
            .multilineTextAlignment(.center)
            .opacity(line.isBackground ? 0.6 : 1.0)
            .scaleEffect(isCurrent ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.2), value: isCurrent)
            .onTapGesture(perform: onTap)
    }

    private var foregroundStyle: some ShapeStyle {
        if isCurrent {
            return AnyShapeStyle(.primary)
        } else {
            return AnyShapeStyle(.secondary)
        }
    }
}

// MARK: - LRC Parser

struct LRCParser {
    static func parse(_ content: String) -> [LyricLine] {
        var lines: [LyricLine] = []

        let pattern = #"\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        for line in content.components(separatedBy: .newlines) {
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
                let centis = Int(line[centisRange]) ?? 0

                let timestamp = Double(minutes * 60 + seconds) + Double(centis) / (centis > 99 ? 1000 : 100)
                let text = String(line[textRange]).trimmingCharacters(in: .whitespaces)
                let isBackground = text.hasPrefix("(") && text.hasSuffix(")")

                if !text.isEmpty {
                    lines.append(LyricLine(timestamp: timestamp, text: text, isBackground: isBackground))
                }
            } else {
                // Unsynced line
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("[") {
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
