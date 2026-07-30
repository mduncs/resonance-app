import SwiftUI

struct AlbumsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewState: ViewState = .loading
    @State private var sortOrder: AlbumSortOrder = .name
    @State private var sortedAlbums: [Album] = []
    @State private var isSyncing = false

    /// Cached sanitized albums - only recomputed when appState.albums changes
    @State private var sanitizedAlbums: [Album] = []
    @AppStorage("minAlbumSongCount") private var minAlbumSongCount = 1

    enum ViewState: Equatable {
        case loading
        case empty
        case error(ResonanceError)
        case populated

        static func == (lhs: ViewState, rhs: ViewState) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading), (.empty, .empty), (.populated, .populated): return true
            case (.error, .error): return true
            default: return false
            }
        }
    }

    enum AlbumSortOrder: String, CaseIterable {
        case name = "Name"
        case artist = "Artist"
        case year = "Year"
        case recentlyAdded = "Recently Added"
    }

    /// Total unfiltered album count (from appState, which is populated by cache or sync)
    private var totalAlbumCount: Int {
        appState.albums.count
    }

    private func updateSortedAlbums(from albums: [Album]) {
        let filtered = minAlbumSongCount > 1
            ? albums.filter { $0.songCount >= minAlbumSongCount }
            : albums

        switch sortOrder {
        case .name:
            sortedAlbums = filtered.sorted { $0.name < $1.name }
        case .artist:
            sortedAlbums = filtered.sorted { $0.artist < $1.artist }
        case .year:
            sortedAlbums = filtered.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .recentlyAdded:
            sortedAlbums = filtered.reversed()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Apple Music-style page header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Albums")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    if totalAlbumCount > 0 || !sortedAlbums.isEmpty {
                        HStack(spacing: 6) {
                            if minAlbumSongCount > 1 && sortedAlbums.count < totalAlbumCount {
                                Text("\(sortedAlbums.count) of \(totalAlbumCount) albums")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("\(totalAlbumCount) albums")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if isSyncing {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            }
                        }
                    }
                }

                Spacer()

                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(AlbumSortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
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
                    LoadingGridView()

                case .empty:
                    CompactStatusView(
                        title: "No Albums",
                        systemImage: "square.stack",
                        message: "Albums from your library will appear here."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .error(let error):
                    CompactStatusView(
                        title: error.errorTitle,
                        systemImage: error.systemImage,
                        message: error.errorDescription,
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise"
                    ) {
                        Task { await syncAlbums() }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .populated:
                    if sortedAlbums.isEmpty {
                        CompactStatusView(
                            title: "No Albums",
                            systemImage: "square.stack",
                            message: "No albums match the current filters."
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        AlbumGridView(albums: sortedAlbums)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .task {
            await loadAlbums()
        }
        .onChange(of: appState.albums) { _, newAlbums in
            sanitizedAlbums = AlbumSanitizer.sanitize(newAlbums)
            updateSortedAlbums(from: sanitizedAlbums)
            if viewState == .loading && !sanitizedAlbums.isEmpty {
                viewState = .populated
            }
        }
        .onChange(of: sortOrder) { _, _ in
            updateSortedAlbums(from: sanitizedAlbums)
        }
        .onChange(of: minAlbumSongCount) { _, _ in
            updateSortedAlbums(from: sanitizedAlbums)
        }
    }

    private func loadAlbums() async {
        // Use whatever appState.albums already has (populated from cache at startup)
        if !appState.albums.isEmpty {
            sanitizedAlbums = AlbumSanitizer.sanitize(appState.albums)
            updateSortedAlbums(from: sanitizedAlbums)
            viewState = sanitizedAlbums.isEmpty ? .empty : .populated
            await restoreQueueIfNeeded()
            return
        }

        // Cache is empty — need to fetch from network
        await syncAlbums()
    }

    /// Full network sync — only called when cache is empty or on manual refresh
    private func syncAlbums() async {
        if appState.albums.isEmpty { viewState = .loading }
        isSyncing = true

        var allAlbums: [Album] = []
        var seenIds = Set<String>()
        let pageSize = 500
        var offset = 0

        do {
            while true {
                let batch = try await appState.networkActor.fetchAlbums(size: pageSize, offset: offset)
                let newAlbums = batch.filter { seenIds.insert($0.id).inserted }
                allAlbums.append(contentsOf: newAlbums)

                if batch.count < pageSize || newAlbums.isEmpty { break }
                offset += batch.count
            }

            // Save to GRDB
            if let serverId = appState.activeServerId {
                do {
                    try appState.databaseManager.saveAlbums(allAlbums, serverId: serverId)
                    appState.refreshLibraryMembershipIds()
                    allAlbums = (try? appState.databaseManager.loadAdmittedAlbums(serverId: serverId)) ?? allAlbums
                } catch {
                    print("[AlbumsView] GRDB save failed: \(error)")
                }
            }

            // Update app state — triggers onChange which updates the grid
            appState.albums = allAlbums
            await restoreQueueIfNeeded()
        } catch {
            if appState.albums.isEmpty {
                viewState = .error(error as? ResonanceError ?? .networkUnavailable)
            }
        }
        isSyncing = false
    }

    private func restoreQueueIfNeeded() async {
        guard appState.queueManager.isEmpty else { return }
        await MainActor.run {
            appState.restorePersistedQueue()
        }
    }
}

struct AlbumGridView: View {
    @Environment(AppState.self) private var appState
    let albums: [Album]

    @State private var selectedAlbumId: String?
    @FocusState private var isGridFocused: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)
    ]

    // Estimate columns based on typical content area width (screen - sidebar - margins)
    private var estimatedColumnsPerRow: Int {
        let estimatedContentWidth = (NSScreen.main?.frame.width ?? 1200) * 0.7
        return max(1, Int(estimatedContentWidth / 240))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            AlbumCard(album: album)
                        }
                        .buttonStyle(.plain)
                        .id(album.id)
                        .overlay {
                            if selectedAlbumId == album.id {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor, lineWidth: 3)
                            }
                        }
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                Task { await playAlbum(album) }
                            }
                        )
                        .contextMenu {
                            AlbumContextMenu(album: album)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .focusable()
            .focused($isGridFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                handleArrowKey(press.key, proxy: proxy)
            }
            .onKeyPress(keys: [KeyEquivalent("p")]) { press in
                if let albumId = selectedAlbumId,
                   let album = albums.first(where: { $0.id == albumId }) {
                    Task { await playAlbum(album) }
                    return .handled
                }
                return .ignored
            }
        }
        .onAppear {
            isGridFocused = true
        }
    }

    private func handleArrowKey(_ key: KeyEquivalent, proxy: ScrollViewProxy) -> KeyPress.Result {
        let navigator = GridNavigator(itemCount: albums.count, columnsPerRow: estimatedColumnsPerRow)

        let currentIndex: Int?
        if let selectedAlbumId {
            currentIndex = albums.firstIndex(where: { $0.id == selectedAlbumId })
        } else {
            currentIndex = nil
        }

        if let newIndex = navigator.navigate(from: currentIndex, direction: key),
           newIndex >= 0, newIndex < albums.count {
            let newId = albums[newIndex].id
            selectedAlbumId = newId
            withAnimation {
                proxy.scrollTo(newId, anchor: .center)
            }
            return .handled
        }
        return .ignored
    }

    private func playAlbum(_ album: Album) async {
        do {
            let songs = try await appState.playableAlbumSongs(for: album)
            await appState.playbackManager.play(songs: songs)
        } catch {
            print("Failed to play album: \(error)")
        }
    }
}

struct LoadingGridView: View {
    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(0..<12, id: \.self) { _ in
                    AlbumCard(album: .placeholder)
                        .redacted(reason: .placeholder)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

#Preview {
    AlbumsView()
        .environment(AppState())
}
