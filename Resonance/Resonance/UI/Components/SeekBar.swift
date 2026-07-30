import SwiftUI

struct SeekBar: View {
    @Environment(AppState.self) private var appState
    @State private var isDragging = false
    @State private var isHovering = false
    @State private var dragProgress: Double = 0

    var showTime: Bool = true

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
                    // Track
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 4)

                    // Progress
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: progressWidth(in: geometry.size.width), height: 4)

                    // Scrubber
                    Circle()
                        .fill(.white)
                        .shadow(radius: 2)
                        .frame(width: isDragging ? 14 : 10, height: isDragging ? 14 : 10)
                        .offset(x: scrubberOffset(in: geometry.size.width))
                        .opacity(isDragging || isHovering ? 1 : 0)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            dragProgress = progress
                        }
                        .onEnded { value in
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            Task {
                                await appState.playbackManager.seek(to: progress * duration)
                            }
                            isDragging = false
                        }
                )
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovering = hovering
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback position")
                .accessibilityValue(seekBarAccessibilityValue)
                .accessibilityAdjustableAction { direction in
                    let seekAmount: TimeInterval = 10 // 10 seconds
                    switch direction {
                    case .increment:
                        let newTime = min(duration, currentTime + seekAmount)
                        Task { await appState.playbackManager.seek(to: newTime) }
                    case .decrement:
                        let newTime = max(0, currentTime - seekAmount)
                        Task { await appState.playbackManager.seek(to: newTime) }
                    @unknown default:
                        break
                    }
                }
            }
            .frame(height: 20)

            if showTime {
                Text(formatTime(duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .leading)
            }
        }
    }

    private var currentTime: TimeInterval {
        appState.currentTime
    }

    private var duration: TimeInterval {
        appState.currentDuration
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return isDragging ? dragProgress : (currentTime / duration)
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        totalWidth * CGFloat(progress)
    }

    private func scrubberOffset(in totalWidth: CGFloat) -> CGFloat {
        let scrubberSize: CGFloat = isDragging ? 14 : 10
        return (totalWidth * CGFloat(progress)) - (scrubberSize / 2)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var seekBarAccessibilityValue: String {
        let currentMinutes = Int(currentTime) / 60
        let currentSeconds = Int(currentTime) % 60
        let durationMinutes = Int(duration) / 60
        let durationSeconds = Int(duration) % 60

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
