import SwiftUI

struct RecentlyAddedView: View {
    @Environment(AppState.self) private var appState
    @State private var viewState: ViewState = .loading
    @State private var albums: [Album] = []
    @State private var selectedAlbum: Album?
    @State private var searchText = ""

    // Pagination state
    @State private var albumOffset: Int = 0
    @State private var hasMore: Bool = true
    @State private var isLoadingMore: Bool = false
    @State private var loadMoreError: Error?

    @State private var loadGeneration = UUID()
    @State private var loadedServerID: UUID?
    @State private var seenAlbumIDs = Set<String>()

    private let batchSize = 50

    /// Same admitted-library rule as HomeView so both surfaces agree.
    @AppStorage("minAlbumSongCount") private var minAlbumSongCount = 1

    private let columns = [
        GridItem(.adaptive(minimum: 247, maximum: 247), spacing: 10)
    ]

    enum ViewState {
        case loading
        case noServer
        case empty
        case error(String)
        case populated
    }

    private struct DateSection: Identifiable {
        let id: Int
        let title: String
        let albums: [Album]
    }

    private var dateSections: [DateSection] {
        // Native captures prove these visible buckets, not their exact boundary
        // algorithm. Use local calendar boundaries; never infer dates from year.
        let now = DeterministicCaptureFixture.isEnabled
            ? Date(timeIntervalSince1970: 1789819200) : Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let month = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let titles = ["Today", "Yesterday", "This Week", "This Month", "Earlier", "Date Unavailable"]
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = albums.filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.artist.localizedStandardContains(query)
        }
        let grouped = Dictionary(grouping: matches) { album -> Int in
            guard let date = album.addedAt else { return 5 }
            if calendar.isDate(date, inSameDayAs: now) { return 0 }
            if date >= yesterday && date < today { return 1 }
            if date >= week && date < today { return 2 }
            if date >= month && date < today { return 3 }
            return date < today ? 4 : 5
        }
        return titles.indices.compactMap { index in
            guard let items = grouped[index], !items.isEmpty else { return nil }
            return DateSection(id: index, title: titles[index], albums: items)
        }
    }

    private var groupToolbarTitle: some View {
        Text(dateSections.first?.title ?? "Recently Added")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var playbackMenu: some View {
                Menu {
                    Button {
                        Task { await playAll() }
                    } label: {
                        Label(searchText.isEmpty ? "Play All" : "Play Matching Albums", systemImage: "play")
                    }
                    .disabled(dateSections.isEmpty)

                    Button {
                        Task { await playAll(shuffled: true) }
                    } label: {
                        Label(searchText.isEmpty ? "Shuffle All" : "Shuffle Matching Albums", systemImage: "shuffle")
                    }
                    .disabled(dateSections.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Content
            Group {
                switch viewState {
                case .noServer:
                    CompactStatusView(
                        title: "No Server Connected",
                        systemImage: "externaldrive.connected.to.line.below",
                        message: "Connect to a music server to browse new additions."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

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
                        if dateSections.isEmpty && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            CompactStatusView(
                                title: loadMoreError != nil ? "Search Incomplete" : (hasMore ? "Finding Albums…" : "No Matching Albums"),
                                systemImage: "magnifyingglass",
                                message: loadMoreError != nil ? "Some additions could not be searched. Retry below." : (hasMore ? "Searching the remaining additions." : "Try a different album or artist name.")
                            )
                            .padding(24)
                        }
                        LazyVStack(alignment: .leading, spacing: 28) {
                            ForEach(dateSections) { section in
                                VStack(alignment: .leading, spacing: 28) {
                                    if section.id != dateSections.first?.id {
                                        Text(section.title)
                                            .font(.title3.weight(.semibold))
                                            .accessibilityAddTraits(.isHeader)
                                    }
                                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                                        ForEach(section.albums) { album in
                                            AlbumCardActionSurface(
                                                album: album,
                                                onPlay: { Task { await playAlbum(album) } }
                                            ) { artworkHoverChanged in
                                                Button {
                                                    selectedAlbum = album
                                                } label: {
                                                    AlbumCard(
                                                        album: album,
                                                        titleLineLimit: 2,
                                                        libraryCellWidth: 247,
                                                        showsHoverPlayButton: false,
                                                        onArtworkHoverChange: artworkHoverChanged
                                                    )
                                                }
                                                .buttonStyle(.plain)
                                                .simultaneousGesture(
                                                    TapGesture(count: 2)
                                                        .onEnded { Task { await playAlbum(album) } }
                                                )
                                                .accessibilityHint("Opens the album.")
                                                .accessibilityAction(named: "Play") {
                                                    Task { await playAlbum(album) }
                                                }
                                            }
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
                                }
                            }
                        }
                        .padding(.horizontal, 29)
                        .padding(.top, 29)
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
        .searchable(text: $searchText, prompt: "Find in Recently Added")
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { groupToolbarTitle }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { groupToolbarTitle }
            }
            ToolbarItem(placement: .principal) { Spacer() }
            ToolbarItem(placement: .primaryAction) { playbackMenu }
        }
        .onChange(of: searchText) {
            guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await loadMore() }
        }
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
        }
        .task(id: "\(appState.activeServerId ?? "none"):\(appState.connectionStatus == .connected):\(minAlbumSongCount)") {
            await loadRecentlyAdded()
        }
        .onDisappear {
            // Invalidate unstructured load-more/retry tasks as well as the view task.
            loadGeneration = UUID()
            isLoadingMore = false
        }
    }

    private func isCurrentLoad(_ generation: UUID, serverID: UUID) -> Bool {
        !Task.isCancelled && generation == loadGeneration && appState.activeServer?.id == serverID
    }

    private struct IncompleteRecentAlbums: LocalizedError {
        var errorDescription: String? {
            "Recently added albums are incomplete because the server repeatedly returned the same albums. Try again."
        }
    }

    private func loadRecentlyAdded() async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        loadGeneration = generation
        isLoadingMore = false
        albums = []
        selectedAlbum = nil
        albumOffset = 0
        seenAlbumIDs = []
        hasMore = true
        loadMoreError = nil
        loadedServerID = appState.activeServer?.id
        guard let serverID = loadedServerID else {
            viewState = .noServer
            return
        }
        viewState = .loading

        do {
            try await loadBatch(serverID: serverID, generation: generation)
            guard isCurrentLoad(generation, serverID: serverID) else { return }
            viewState = albums.isEmpty ? .empty : .populated
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await loadMore() }
        } catch {
            guard isCurrentLoad(generation, serverID: serverID) else { return }
            viewState = .error(error.localizedDescription)
        }
    }

    private func loadMore() async {
        guard case .populated = viewState else { return }
        guard hasMore, !isLoadingMore, let serverID = loadedServerID else { return }
        let generation = loadGeneration
        guard isCurrentLoad(generation, serverID: serverID) else { return }
        isLoadingMore = true
        defer {
            if generation == loadGeneration { isLoadingMore = false }
        }

        do {
            repeat {
                try await loadBatch(serverID: serverID, generation: generation)
                guard isCurrentLoad(generation, serverID: serverID) else { return }
            } while hasMore && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            loadMoreError = nil
        } catch {
            guard isCurrentLoad(generation, serverID: serverID) else { return }
            loadMoreError = error
        }
    }

    private func loadBatch(serverID: UUID, generation: UUID) async throws {
        guard isCurrentLoad(generation, serverID: serverID) else { return }
        // Policy read failures must not publish the unfiltered server catalog.
        let admittedIDs = try appState.databaseManager.loadLibraryMemberIds(type: .album, serverId: serverID.uuidString)
        let hiddenIDs = try appState.databaseManager.loadHiddenIds(type: "album", serverId: serverID.uuidString)
        let minimumSongs = minAlbumSongCount
        // An explicitly empty admitted library has no eligible server results.
        guard !admittedIDs.isEmpty else {
            hasMore = false
            albums = []
            return
        }
        var offset = albumOffset
        var seen = seenAlbumIDs
        var visible: [Album] = []
        var exhausted = false
        var duplicatePages = 0

        // Server page caps may be lower than our requested size. Only an empty
        // raw page proves exhaustion; a fully filtered page must keep walking.
        while visible.count < batchSize {
            let batch = try await appState.networkActor.fetchAlbums(
                type: .newest, size: batchSize, offset: offset, expectedServerID: serverID
            )
            guard isCurrentLoad(generation, serverID: serverID) else { return }
            if batch.isEmpty {
                exhausted = true
                break
            }
            offset += batch.count
            let unique = batch.filter { seen.insert($0.id).inserted }
            duplicatePages = unique.isEmpty ? duplicatePages + 1 : 0
            guard duplicatePages < 3 else { throw IncompleteRecentAlbums() }
            visible.append(contentsOf: unique.filter {
                admittedIDs.contains($0.id) && !hiddenIDs.contains($0.id) && $0.songCount >= minimumSongs
            })
        }
        guard isCurrentLoad(generation, serverID: serverID) else { return }
        // Commit cursor and results together; a failed walk retries without gaps.
        albumOffset = offset
        seenAlbumIDs = seen
        hasMore = !exhausted
        albums.append(contentsOf: visible)
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

        for album in dateSections.flatMap(\.albums) {
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
