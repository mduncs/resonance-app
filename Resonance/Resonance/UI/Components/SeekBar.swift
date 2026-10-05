import SwiftUI

struct SeekBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDragging = false
    @State private var isHovering = false
    @State private var dragProgress: Double = 0
    @State private var pendingSeekProgress: Double?
    @State private var seekTask: Task<Void, Never>?

    var showTime: Bool = true
    // Preserve Listen's existing hit region; the captured immersive player
    // supplies its measured 15-point control allocation explicitly.
    var interactionHeight: CGFloat = 20
    var trackHeight: CGFloat = 4
    var trackVerticalOffset: CGFloat = 0
    var trackAppearance: TrackAppearance = .standard

    enum TrackAppearance {
        case standard
        case capturedExpanded
    }

    var body: some View {
        HStack(spacing: 8) {
            if showTime {
                Text(formatTime(currentTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    track(width: geometry.size.width)
                        .offset(y: trackVerticalOffset)

                    // Scrubber
                    Circle()
                        .fill(.white)
                        .shadow(radius: 2)
                        .frame(width: isDragging ? 14 : 10, height: isDragging ? 14 : 10)
                        .offset(x: scrubberOffset(in: geometry.size.width))
                        .opacity(canSeek && (isDragging || isHovering) ? 1 : 0)
                }
                .frame(height: interactionHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard canSeek, geometry.size.width > 0 else { return }
                            if !isDragging {
                                seekTask?.cancel()
                                seekTask = nil
                                pendingSeekProgress = nil
                            }
                            isDragging = true
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            dragProgress = progress
                        }
                        .onEnded { value in
                            guard canSeek, geometry.size.width > 0 else {
                                resetInteraction()
                                return
                            }
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            commitSeek(to: progress * duration)
                            isDragging = false
                        }
                )
                .onHover { hovering in
                    if reduceMotion {
                        isHovering = canSeek && hovering
                    } else {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHovering = canSeek && hovering
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback position")
                .accessibilityValue(seekBarAccessibilityValue)
                .accessibilityAdjustableAction { direction in
                    guard canSeek else { return }
                    let seekAmount: TimeInterval = 10 // 10 seconds
                    switch direction {
                    case .increment:
                        let newTime = min(duration, currentTime + seekAmount)
                        commitSeek(to: newTime)
                    case .decrement:
                        let newTime = max(0, currentTime - seekAmount)
                        commitSeek(to: newTime)
                    @unknown default:
                        break
                    }
                }
            }
            .frame(height: interactionHeight)
            .allowsHitTesting(canSeek)
            .disabled(!canSeek)

            if showTime {
                Text(formatTime(duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .leading)
            }
        }
        .onChange(of: appState.nowPlaying?.id) { resetInteraction() }
        .onChange(of: appState.activeServerId) { resetInteraction() }
        .onChange(of: canSeek) { resetInteraction() }
        .onDisappear { resetInteraction() }
    }

    private var canSeek: Bool {
        appState.nowPlaying != nil
            && duration.isFinite && duration > 0
            && appState.playbackManager.currentSourceSupportsSeeking
    }

    private func commitSeek(to time: TimeInterval) {
        guard canSeek, time.isFinite else { return }
        seekTask?.cancel()
        let songID = appState.nowPlaying?.id
        let serverID = appState.activeServerId
        let target = min(duration, max(0, time))
        pendingSeekProgress = target / duration
        seekTask = Task { @MainActor in
            guard !Task.isCancelled, canSeek,
                  appState.nowPlaying?.id == songID,
                  appState.activeServerId == serverID else { return }
            await appState.playbackManager.seek(to: target)
            guard !Task.isCancelled,
                  appState.nowPlaying?.id == songID,
                  appState.activeServerId == serverID else { return }
            pendingSeekProgress = nil
            seekTask = nil
        }
    }

    private func resetInteraction() {
        seekTask?.cancel()
        seekTask = nil
        isDragging = false
        isHovering = false
        dragProgress = 0
        pendingSeekProgress = nil
    }

    @ViewBuilder
    private func track(width: CGFloat) -> some View {
        switch trackAppearance {
        case .standard:
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: progressWidth(in: width))
            }
            .frame(height: trackHeight)
        case .capturedExpanded:
            // Music captures03/11/14/15: two disjoint rectangular segments,
            // each clipped by a full-width radius3 parent with plusL blending.
            // A rounded progress capsule over a complete track double-blends
            // the played region and rounds the internal boundary incorrectly.
            let rawWidth = progressWidth(in: width)
            let filledWidth = rawWidth.isFinite ? min(max(0, rawWidth), width) : 0
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0x1.ccccccp-2))
                    .frame(width: filledWidth, height: trackHeight)
                    .frame(width: width, height: trackHeight, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .circular))
                    .blendMode(.plusLighter)
                Rectangle()
                    .fill(Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0x1.70a3d8p-3))
                    .frame(width: width - filledWidth, height: trackHeight)
                    .frame(width: width, height: trackHeight, alignment: .trailing)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .circular))
                    .blendMode(.plusLighter)
            }
            .frame(width: width, height: trackHeight)
        }
    }

    private var currentTime: TimeInterval {
        appState.currentTime
    }

    private var duration: TimeInterval {
        appState.currentDuration
    }

    private var progress: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let rawProgress = isDragging
            ? dragProgress
            : (pendingSeekProgress ?? (currentTime / duration))
        guard rawProgress.isFinite else { return 0 }
        return min(1, max(0, rawProgress))
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        totalWidth * CGFloat(progress)
    }

    private func scrubberOffset(in totalWidth: CGFloat) -> CGFloat {
        let scrubberSize: CGFloat = isDragging ? 14 : 10
        return (totalWidth * CGFloat(progress)) - (scrubberSize / 2)
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
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var seekBarAccessibilityValue: String {
        let displayedTime = duration.isFinite && duration > 0 ? progress * duration : 0
        let currentTotalSeconds = safeIntegerSeconds(displayedTime)
        let durationTotalSeconds = safeIntegerSeconds(duration)
        let currentMinutes = currentTotalSeconds / 60
        let currentSeconds = currentTotalSeconds % 60
        let durationMinutes = durationTotalSeconds / 60
        let durationSeconds = durationTotalSeconds % 60

        let currentStr: String
        if currentMinutes == 0 {
            currentStr = "\(currentSeconds) seconds"
        } else if currentMinutes == 1 {
            currentStr = "1 minute \(currentSeconds) seconds"
        } else {
            currentStr = "\(currentMinutes) minutes \(currentSeconds) seconds"
        }

        let durationStr: String
        if durationMinutes == 0 {
            durationStr = "\(durationSeconds) seconds"
        } else if durationMinutes == 1 {
            durationStr = "1 minute \(durationSeconds) seconds"
        } else {
            durationStr = "\(durationMinutes) minutes \(durationSeconds) seconds"
        }

        return "\(currentStr) of \(durationStr)"
    }

    private func safeIntegerSeconds(_ time: TimeInterval) -> Int {
        guard time.isFinite, time > 0 else { return 0 }
        return Int(min(time, Double(Int.max / 2)))
    }
}

struct SeekBarCompact: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 3)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: progressWidth(in: geometry.size.width), height: 3)
            }
        }
        .frame(height: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback progress")
        .accessibilityValue(progressAccessibilityValue)
    }

    private var progress: Double {
        guard appState.currentDuration > 0 else { return 0 }
        return appState.currentTime / appState.currentDuration
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        totalWidth * CGFloat(progress)
    }

    private var progressAccessibilityValue: String {
        let percent = Int(progress * 100)
        return "\(percent) percent"
    }
}

#Preview {
    VStack(spacing: 20) {
        SeekBar()
            .frame(width: 300)

        SeekBarCompact()
            .frame(width: 300)
    }
    .padding()
    .environment(AppState())
}
