import SwiftUI

// DEMO 1: Compact centered transport
// Progress bar integrated under controls, everything centered
struct NowPlayingBarDemo1: View {
    @State private var progress: Double = 0.35
    @State private var volume: Double = 0.7

    var body: some View {
        HStack(spacing: 0) {
            Spacer()

            // Center cluster: controls + progress + now playing
            HStack(spacing: 24) {
                // Controls
                HStack(spacing: 20) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 11))
                    Image(systemName: "backward.fill")
                        .font(.system(size: 13))
                    Image(systemName: "play.fill")
                        .font(.system(size: 22))
                    Image(systemName: "forward.fill")
                        .font(.system(size: 13))
                    Image(systemName: "repeat")
                        .font(.system(size: 11))
                }

                // Now playing: art + info
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.blue.gradient)
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Song Title Here")
                            .font(.system(size: 12, weight: .medium))
                        Text("Artist Name — Album")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Right: utils + volume
            HStack(spacing: 12) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                Image(systemName: "quote.bubble")
                    .font(.system(size: 12))
                Image(systemName: "list.bullet")
                    .font(.system(size: 12))

                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10))
                    Slider(value: $volume).frame(width: 60).controlSize(.mini)
                }
            }
            .padding(.trailing, 16)
        }
        .frame(height: 50)
        .background {
            VStack(spacing: 0) {
                Spacer()
                // Progress bar at very bottom
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.primary.opacity(0.1))
                        Rectangle().fill(.primary.opacity(0.4))
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 2)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// DEMO 2: Progress bar ABOVE content, spanning width
struct NowPlayingBarDemo2: View {
    @State private var progress: Double = 0.35
    @State private var volume: Double = 0.7

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar on TOP
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.primary.opacity(0.1))
                    Rectangle().fill(.red.opacity(0.8))
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 3)

            // Content row
            HStack(spacing: 0) {
                // Left: controls
                HStack(spacing: 18) {
                    Image(systemName: "shuffle").font(.system(size: 11))
                    Image(systemName: "backward.fill").font(.system(size: 12))
                    Image(systemName: "pause.fill").font(.system(size: 18))
                    Image(systemName: "forward.fill").font(.system(size: 12))
                    Image(systemName: "repeat").font(.system(size: 11))
                }
                .padding(.leading, 16)

                Spacer()

                // Center: now playing
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.purple.gradient)
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Song Title")
                            .font(.system(size: 12, weight: .medium))
                        Text("Artist")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Right: volume + utils
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 10))
                        Slider(value: $volume).frame(width: 60).controlSize(.mini)
                    }
                    Image(systemName: "infinity").font(.system(size: 10))
                    Image(systemName: "list.bullet").font(.system(size: 11))
                    Image(systemName: "quote.bubble").font(.system(size: 11))
                }
                .padding(.trailing, 16)
            }
            .frame(height: 47)
        }
        .frame(height: 50)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// DEMO 3: Minimal - just controls in center, tiny art, progress underneath controls only
struct NowPlayingBarDemo3: View {
    @State private var progress: Double = 0.35
    @State private var volume: Double = 0.7

    var body: some View {
        HStack(spacing: 0) {
            Spacer()

            // Center cluster with integrated progress
            VStack(spacing: 4) {
                HStack(spacing: 16) {
                    // Mini art
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.orange.gradient)
                        .frame(width: 32, height: 32)

                    // Controls
                    HStack(spacing: 16) {
                        Image(systemName: "backward.fill").font(.system(size: 12))
                        Image(systemName: "play.fill").font(.system(size: 20))
                        Image(systemName: "forward.fill").font(.system(size: 12))
                    }

                    // Song info
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Song")
                            .font(.system(size: 11, weight: .medium))
                        Text("Artist")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 80, alignment: .leading)
                }

                // Progress under this cluster only
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.15))
                        Capsule().fill(.primary.opacity(0.5))
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(width: 200, height: 3)
            }

            Spacer()

            // Right: volume
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 10))
                Slider(value: $volume).frame(width: 60).controlSize(.mini)
            }
            .padding(.trailing, 16)
        }
        .frame(height: 52)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// Preview all demos stacked
struct NowPlayingBarDemos: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("DEMO 1: Compact centered").font(.caption).foregroundStyle(.secondary)
            NowPlayingBarDemo1()

            Text("DEMO 2: Progress on top").font(.caption).foregroundStyle(.secondary)
            NowPlayingBarDemo2()

            Text("DEMO 3: Minimal centered").font(.caption).foregroundStyle(.secondary)
            NowPlayingBarDemo3()

            Spacer()
        }
        .padding()
        .frame(width: 700, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#Preview("Bar Demos") {
    NowPlayingBarDemos()
}
