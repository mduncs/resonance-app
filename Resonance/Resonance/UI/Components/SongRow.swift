import SwiftUI

struct SongRow: View {
    @Environment(AppState.self) private var appState

    let song: Song
    var showTrackNumber: Bool = true
    var showAlbumArt: Bool = true
    var isPlaying: Bool = false

    @State private var isDownloaded: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // Track number or playing indicator
            if showTrackNumber {
                Group {
                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(Color.accentColor)
                    } else if let track = song.track, track > 0 {
                        Text("\(track)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("-")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                .monospacedDigit()
                .frame(width: 24, alignment: .trailing)
            }

            // Album art
            if showAlbumArt {
                EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .small)
                    .frame(width: 40, height: 40)
            }

            // Song info
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(song.artist)

                    if !showAlbumArt {
                        Text("—")
                        Text(song.album)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            // Indicators
            HStack(spacing: 8) {
                // Downloaded indicator
                if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Rating indicator
                RatingIndicator(rating: song.rating)

                // Explicit indicator
                if song.isExplicit {
                    Text("E")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .cornerRadius(2)
                }

                // Duration
                Text(song.formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(songAccessibilityLabel)
        .accessibilityHint("Plays the song")
        .accessibilityAddTraits(isPlaying ? [.isButton, .isSelected] : .isButton)
        .task(id: song.id) {
            await checkDownloadStatus()
        }
    }

    private func checkDownloadStatus() async {
        guard let server = await appState.networkActor.activeServer else {
            isDownloaded = false
            return
        }
        isDownloaded = await appState.cacheActor.isDownloaded(songId: song.id, serverId: server.id)
    }

    private var songAccessibilityLabel: String {
        var label = "\(song.title) by \(song.artist)"
        if isPlaying {
            label = "Now playing: " + label
        }
        label += ", \(song.formattedDuration)"
        if song.isExplicit {
            label += ", explicit"
        }
        return label
    }
}

struct SongRowCompact: View {
    let song: Song
    var isPlaying: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            }

            Text(song.title)
                .font(.subheadline)
                .fontWeight(isPlaying ? .semibold : .regular)
                .lineLimit(1)

            Spacer()

            Text(song.formattedDuration)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(songAccessibilityLabel)
        .accessibilityHint("Plays the song")
        .accessibilityAddTraits(isPlaying ? [.isButton, .isSelected] : .isButton)
    }

    private var songAccessibilityLabel: String {
        var label = "\(song.title), \(song.formattedDuration)"
        if isPlaying {
            label = "Now playing: " + label
        }
        return label
    }
}

// MARK: - Download Indicator

private struct DownloadIndicator: View {
    let isDownloaded: Bool
    let downloadProgress: Double?

    var body: some View {
        Group {
            if let progress = downloadProgress {
                // Downloading - show progress
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 14, height: 14)
            } else if isDownloaded {
                // Downloaded - show checkmark
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Not downloaded - show nothing
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        SongRow(song: .placeholder, isPlaying: true)
        Divider()
        SongRow(song: .placeholder)
        Divider()
        SongRow(song: .placeholder, showTrackNumber: false, showAlbumArt: false)
        Divider()
        SongRowCompact(song: .placeholder, isPlaying: true)
    }
    .padding()
    .frame(width: 400)
    .environment(AppState())
}
