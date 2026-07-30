import SwiftUI

struct RecentlyAddedView: View {
    @Environment(AppState.self) private var appState
    @State private var viewState: ViewState = .loading
    @State private var albums: [Album] = []
    @State private var selectedAlbum: Album?

    // Pagination state
    @State private var albumOffset: Int = 0
    @State private var hasMore: Bool = true
    @State private var isLoadingMore: Bool = false
    @State private var loadMoreError: Error?

    private let batchSize = 50

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 20)
    ]

    enum ViewState {
        case loading
        case empty
        case error(String)
        case populated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Apple Music-style page header
            HStack(alignment: .center) {
                Text("Recently Added")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Spacer()

                Menu {
                    Button {
                        Task { await playAll() }
                    } label: {
                        Label("Play All", systemImage: "play")
                    }
                    .disabled(albums.isEmpty)

                    Button {
                        Task { await playAll(shuffled: true) }
                    } label: {
                        Label("Shuffle All", systemImage: "shuffle")
                    }
                    .disabled(albums.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Content
            Group {
                switch viewState {
                case .loading:
                    InlineLoadingStatusView(title: "Loading recently added...")
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                case .empty:
                    CompactStatusView(
                        title: "No Recently Added",
                        systemImage: "clock.badge.checkmark",
                        message: "New albums added to your library will appear here."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .error(let message):
                    CompactStatusView(
                        title: "Failed to Load",
                        systemImage: "exclamationmark.triangle",
                        message: message,
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise"
                    ) {
                        Task { await loadRecentlyAdded() }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .populated:
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(albums) { album in
                                AlbumCard(album: album)
                                    .simultaneousGesture(
                                        TapGesture(count: 2)
                                            .onEnded {
                                                Task {
                                                    await playAlbum(album)
                                                }
                                            }
                                    )
                                    .simultaneousGesture(
                                        TapGesture(count: 1)
                                            .onEnded {
                                                selectedAlbum = album
                                            }
                                    )
                                    .contextMenu {
                                        AlbumContextMenu(album: album)
                                    }
                                    .onAppear {
                                        if album.id == albums.last?.id, hasMore, !isLoadingMore, loadMoreError == nil {
                                            Task { await loadMore() }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)

                        // Loading indicator
                        if isLoadingMore {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Loading more...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(height: 32)
                            .frame(maxWidth: .infinity)
                        }

                        // Error with retry
                        if loadMoreError != nil {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Text("Failed to load more")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Retry") {
                                    loadMoreError = nil
                                    Task { await loadMore() }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                            .frame(height: 32)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
        }
        .task {
            await loadRecentlyAdded()
        }
    }

    private func loadRecentlyAdded() async {
        viewState = .loading
        albums = []
        albumOffset = 0
        hasMore = true
        loadMoreError = nil

        do {
            try await loadBatch()
            viewState = albums.isEmpty ? .empty : .populated
        } catch {
            print("Failed to load recently added: \(error)")
            viewState = .error(error.localizedDescription)
        }
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            try await loadBatch()
        } catch {
            loadMoreError = error
        }
    }

    private func loadBatch() async throws {
        let batch = try await appState.networkActor.fetchAlbums(
            type: .newest,
            size: batchSize,
            offset: albumOffset
        )

        if batch.count < batchSize {
            hasMore = false
        }

        albumOffset += batch.count
        albums.append(contentsOf: batch)
    }

    private func playAlbum(_ album: Album) async {
        do {
            let songs = try await appState.playableAlbumSongs(for: album)
            await appState.playbackManager.play(songs: songs)
        } catch {
            print("Failed to play album: \(error)")
        }
    }

    private func playAll(shuffled: Bool = false) async {
        var allSongs: [Song] = []

        for album in albums {
            do {
                let songs = try await appState.playableAlbumSongs(for: album)
                allSongs.append(contentsOf: songs)
            } catch {
                print("Failed to fetch songs for \(album.name): \(error)")
            }
        }

        if shuffled {
            allSongs.shuffle()
        }

        if !allSongs.isEmpty {
            await appState.playbackManager.play(songs: allSongs)
        }
    }
}

#Preview {
    NavigationStack {
        RecentlyAddedView()
            .environment(AppState())
    }
}
