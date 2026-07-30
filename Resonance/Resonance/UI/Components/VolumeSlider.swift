import SwiftUI

struct VolumeSlider: View {
    @Environment(AppState.self) private var appState
    @State private var isDragging = false
    @State private var dragVolume: Float = 0

    var showIcons: Bool = true
    var width: CGFloat = 100

    var body: some View {
        HStack(spacing: 6) {
            if showIcons {
                Button {
                    Task {
                        await appState.audioActor.setVolume(0)
                        appState.volume = 0
                    }
                } label: {
                    Image(systemName: volumeIcon)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 4)

                    // Fill
                    Capsule()
                        .fill(.primary.opacity(0.8))
                        .frame(width: volumeWidth(in: geometry.size.width), height: 4)

                    // Knob
                    Circle()
                        .fill(.white)
                        .shadow(radius: 1)
                        .frame(width: 10, height: 10)
                        .offset(x: knobOffset(in: geometry.size.width))
                        .opacity(isDragging ? 1 : 0)
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let volume = Float(max(0, min(1, value.location.x / geometry.size.width)))
                            dragVolume = volume
                            Task {
                                await appState.audioActor.setVolume(volume)
                            }
                        }
                        .onEnded { _ in
                            appState.volume = dragVolume
                            isDragging = false
                        }
                )
            }
            .frame(width: width, height: 16)

            if showIcons {
                Button {
                    Task {
                        await appState.audioActor.setVolume(1)
                        appState.volume = 1
                    }
                } label: {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var currentVolume: Float {
        isDragging ? dragVolume : appState.volume
    }

    private var volumeIcon: String {
        if currentVolume < 0.01 {
            return "speaker.slash.fill"
        } else if currentVolume < 0.33 {
            return "speaker.wave.1.fill"
        } else if currentVolume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private func volumeWidth(in totalWidth: CGFloat) -> CGFloat {
        totalWidth * CGFloat(currentVolume)
    }

    private func knobOffset(in totalWidth: CGFloat) -> CGFloat {
        (totalWidth * CGFloat(currentVolume)) - 5
    }
}

struct VolumeSliderCompact: View {
    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: volumeIcon)
                .font(.caption)

            if isHovering {
                VolumeSlider(showIcons: false, width: 60)
                    .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }

    private var volumeIcon: String {
        if appState.volume < 0.01 {
            return "speaker.slash.fill"
        } else if appState.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if appState.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        VolumeSlider()
        VolumeSlider(showIcons: false)
        VolumeSliderCompact()
    }
    .padding()
    .environment(AppState())
}
