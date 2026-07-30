import SwiftUI

/// A sheet view that displays and plays songs similar to a seed song.
/// Acts as a "station" based on the selected track.
struct SimilarSongsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let seedSong: Song

    @State private var songs: [Song] = []
    @State private var viewState: ViewState = .loading

    private let defaultCount = 50

    enum ViewState {
        case loading
        case empty
        case error(ResonanceError)
        case populated
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewState {
                case .loading:
                    loadingView

                case .empty:
                    emptyView

                case .error(let error):
                    ErrorView(error: error) {
                        await loadSimilarSongs()
                    }

                case .populated:
                    songListView
                }
            }
            .navigationTitle("Station")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task {
                            await playAll()
                        }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(songs.isEmpty)
                    .help("Play All")

                    Button {
                        Task {
                            await playAll(shuffled: true)
                        }
                    } label: {
                        Image(systemName: "shuffle")
                    }
                    .disabled(songs.isEmpty)
                    .help("Shuffle")
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .frame(idealWidth: 600, idealHeight: 500)
        .task {
            await loadSimilarSongs()
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Finding similar songs...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "No Similar Songs Found",
            systemImage: "waveform",
            description: Text("Could not find songs similar to \"\(seedSong.title)\"")
        )
    }

    private var songListView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header showing seed song
                stationHeader

                Divider()
                    .padding(.horizontal)

                // Song list
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        SongRow(
                            song: song,
                            showTrackNumber: false,
                            showAlbumArt: true,
                            isPlaying: appState.nowPlaying?.id == song.id
                        )
                        .onTapGesture(count: 2) {
                            Task {
                                await appState.playbackManager.play(songs: songs, startingAt: index)
                            }
                        }
                        .contextMenu {
                            SongContextMenu(song: song)
                        }

                        if index < songs.count - 1 {
                            Divider()
                                .padding(.leading, 60)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var stationHeader: some View {
        HStack(spacing: 16) {
            // Seed song artwork
            EnvironmentAlbumArtView(coverArtId: seedSong.coverArt, size: .medium)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("Based on")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(seedSong.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text(seedSong.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("\(songs.count) similar songs")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(spacing: 8) {
                Button {
                    Task {
                        await playAll()
                    }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(songs.isEmpty)

                Button {
                    Task {
                        await playAll(shuffled: true)
                    }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.bordered)
                .disabled(songs.isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: - Actions

    private func loadSimilarSongs() async {
        viewState = .loading

        do {
            let fetchedSongs = try await appState.networkActor.getSimilarSongs(
                id: seedSong.id,
                count: defaultCount
            )
            let visibleSongs = appState.visibleSongsForPlayback(fetchedSongs)

            if visibleSongs.isEmpty {
                viewState = .empty
            } else {
                songs = visibleSongs
                viewState = .populated
            }
        } catch let error as ResonanceError {
            viewState = .error(error)
        } catch {
            viewState = .error(.networkUnavailable)
        }
    }

    private func playAll(shuffled: Bool = false) async {
        var songsToPlay = songs
        if shuffled {
            songsToPlay.shuffle()
        }
        await appState.playbackManager.play(songs: songsToPlay)
        dismiss()
    }
}

#Preview {
    SimilarSongsView(seedSong: .placeholder)
        .environment(AppState())
}
