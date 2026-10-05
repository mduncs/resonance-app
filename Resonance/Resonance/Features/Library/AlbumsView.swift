import SwiftUI
import AppKit

struct AlbumsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewState: ViewState = .loading
    @State private var sortOrder: LibraryAlbumSort = .name
    @State private var queryStore: LibraryAlbumQueryStore?
    @State private var isSyncing = false
    @State private var searchText = ""
    @State private var selectedAlbumID: String?
    @State private var loadGeneration = UUID()
    @State private var albumSyncTask: Task<Void, Never>?
    @State private var attemptedAutomaticSync = Set<ServerIdentity>()
    @AppStorage("minAlbumSongCount") private var minAlbumSongCount = 1

    private struct ServerIdentity: Hashable {
        let id: UUID?
        let url: URL?
        let username: String?
    }

    private struct LoadKey: Hashable {
        let server: ServerIdentity
        let searchText: String
        let minimumSongCount: Int
        let sort: LibraryAlbumSort
        let membershipRevision: UInt64
    }

    private var serverIdentity: ServerIdentity {
        ServerIdentity(id: appState.activeServer?.id,
                       url: appState.activeServer?.url,
                       username: appState.activeServer?.username)
    }

    private var loadKey: LoadKey {
        LoadKey(server: serverIdentity,
                searchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                minimumSongCount: minAlbumSongCount,
                sort: sortOrder,
                membershipRevision: appState.libraryMembershipRevision)
    }

    private var visibleAlbums: [Album] {
        _ = appState.albumPresentationRevision
        return (queryStore?.albums ?? []).map(appState.presentedAlbum)
    }

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

    private var albumCountDescription: String {
        let count = queryStore?.totalCount ?? 0
        return "\(count) albums"
    }

    private var toolbarTitle: some View {
        Text("Albums")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                        Task { await loadAlbums(key: loadKey) }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .populated:
                    if visibleAlbums.isEmpty {
                        CompactStatusView(
                            title: "No Albums",
                            systemImage: "square.stack",
                            message: "No albums match the current filters."
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        VStack(spacing: 0) {
                            AlbumGridView(
                                albums: visibleAlbums,
                                onNeedsMore: loadNextPage,
                                selectedAlbumId: $selectedAlbumID
                            )
                            if let moreError = queryStore?.moreError {
                                Button("Retry loading more albums") {
                                    Task { await queryStore?.loadNextPage() }
                                }
                                .help(moreError)
                                .padding(8)
                            } else if queryStore?.isLoadingMore == true {
                                ProgressView().controlSize(.small).padding(8)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Albums")
        .searchable(text: $searchText, prompt: "Find in Albums")
        .background(LibrarySearchFieldMetrics().frame(width: 0, height: 0))
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { toolbarTitle }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { toolbarTitle }
            }
            ToolbarItem(placement: .principal) { Spacer() }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Text(albumCountDescription).disabled(true)
                    if isSyncing { Text("Syncing albums…").disabled(true) }
                    Divider()
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(LibraryAlbumSort.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    Divider()
                    Button("Refresh Albums") { startAlbumSync() }
                        .disabled(isSyncing || appState.activeServer == nil)
                } label: {
                    Label("Sort Albums", systemImage: "line.3.horizontal.decrease")
                }
                .menuIndicator(.hidden)
                .help(albumCountDescription)
                .accessibilityValue(isSyncing ? "\(albumCountDescription), syncing" : albumCountDescription)
            }
            if isSyncing {
                ToolbarItem(placement: .status) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Syncing albums")
                }
            }
        }
        .task(id: loadKey) { await loadAlbums(key: loadKey) }
        .onChange(of: serverIdentity) { _, _ in
            albumSyncTask?.cancel()
            albumSyncTask = nil
            isSyncing = false
        }
        .onDisappear {
            loadGeneration = UUID()
            albumSyncTask?.cancel()
            albumSyncTask = nil
            queryStore?.cancel()
            isSyncing = false
        }
    }

    private func isCurrentLoad(_ generation: UUID, identity: ServerIdentity) -> Bool {
        !Task.isCancelled && generation == loadGeneration && identity == serverIdentity
    }

    private func loadAlbums(key: LoadKey) async {
        let generation = UUID()
        loadGeneration = generation
        if key.server != serverIdentity { return }
        queryStore?.cancel()
        guard let serverID = key.server.id else {
            queryStore = nil
            viewState = .empty
            return
        }
        let store = LibraryAlbumQueryStore(database: appState.databaseManager)
        queryStore = store
        viewState = .loading
        await store.loadFirstPage(matching: LibraryAlbumQuery(
            serverID: serverID.uuidString,
            searchText: key.searchText,
            minimumSongCount: key.minimumSongCount,
            sort: key.sort
        ))
        guard isCurrentLoad(generation, identity: key.server), loadKey == key else { return }
        switch store.state {
        case .loaded:
            if store.totalCount == 0 && appState.admittedAlbumIds.isEmpty && key.searchText.isEmpty
                && !attemptedAutomaticSync.contains(key.server) {
                attemptedAutomaticSync.insert(key.server)
                await syncAlbums(generation: generation, identity: key.server)
            } else {
                viewState = store.totalCount == 0 && key.searchText.isEmpty && key.minimumSongCount <= 1
                    ? .empty : .populated
            }
        case .failed:
            viewState = .error(.networkUnavailable)
        case .loading, .idle:
            break
        }
    }

    private func loadNextPage(after albumID: String) {
        guard let store = queryStore, store.shouldLoadMore(afterVisibleAlbumID: albumID) else { return }
        Task { await store.loadNextPage() }
    }

    private func startAlbumSync() {
        albumSyncTask?.cancel()
        let identity = serverIdentity
        let generation = UUID()
        loadGeneration = generation
        albumSyncTask = Task { @MainActor in
            await syncAlbums(generation: generation, identity: identity)
            if loadGeneration == generation { albumSyncTask = nil }
        }
    }

    private func syncAlbums(generation: UUID, identity: ServerIdentity) async {
        guard isCurrentLoad(generation, identity: identity), let serverID = identity.id else { return }
        isSyncing = true
        let albumPresentationRevisionAtStart = appState.albumPresentationRevision
        var allAlbums: [Album] = []
        let pageSize = 500
        var offset = 0
        do {
            while true {
                try Task.checkCancellation()
                let batch = try await appState.networkActor.fetchAlbums(
                    size: pageSize, offset: offset, expectedServerID: serverID
                )
                guard isCurrentLoad(generation, identity: identity) else { return }
                allAlbums.append(contentsOf: batch)
                if batch.count < pageSize { break }
                offset += batch.count
            }
            guard isCurrentLoad(generation, identity: identity) else { return }
            try appState.databaseManager.saveAlbums(allAlbums, serverId: serverID.uuidString)
            appState.refreshLibraryMembershipIds()
            appState.reconcileAlbumPresentationOverrides(through: albumPresentationRevisionAtStart)
            appState.invalidateFullAlbumCatalog()
            guard isCurrentLoad(generation, identity: identity) else { return }
            await loadAlbums(key: loadKey)
        } catch {
            guard isCurrentLoad(generation, identity: identity) else { return }
            if queryStore?.albums.isEmpty ?? true {
                viewState = .error(error as? ResonanceError ?? .networkUnavailable)
            }
        }
        if identity == serverIdentity { isSyncing = false }
    }
}

struct AlbumGridView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let albums: [Album]
    var onNeedsMore: (String) -> Void = { _ in }
    @Binding var selectedAlbumId: String?
    @FocusState private var isGridFocused: Bool

    @State private var contentWidth: CGFloat = 0

    // Current AMPGridLayoutModel, cross-checked against all 53 native samples.
    // Width is measured inside the native-matched trailing scroll-content margin.
    private var availableWidth: CGFloat { max(0, contentWidth - 60) }
    private var columnsPerRow: Int {
        3 + [CGFloat(619), 999, 1319, 1680].filter { availableWidth >= $0 }.count
    }
    private var cellWidth: CGFloat {
        max(10, ceil((min(availableWidth, 1680) - 10 * CGFloat(columnsPerRow - 1)) / CGFloat(columnsPerRow)))
    }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cellWidth), spacing: 10, alignment: .top), count: columnsPerRow)
    }
    private var renderedGridWidth: CGFloat {
        CGFloat(columnsPerRow) * cellWidth + CGFloat(columnsPerRow - 1) * 10
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(albums) { album in
                        AlbumCardActionSurface(
                            album: album,
                            onPlay: { Task { await playAlbum(album) } }
                        ) { artworkHoverChanged in
                            NavigationLink(value: album) {
                                AlbumCard(
                                    album: album,
                                    titleLineLimit: 2,
                                    libraryCellWidth: cellWidth,
                                    showsHoverPlayButton: false,
                                    onArtworkHoverChange: artworkHoverChanged
                                )
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(
                                TapGesture(count: 1).onEnded { selectedAlbumId = album.id }
                            )
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    Task { await playAlbum(album) }
                                }
                            )
                        }
                        .id(album.id)
                        .overlay {
                            if selectedAlbumId == album.id {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor, lineWidth: 3)
                            }
                        }
                        .contextMenu {
                            AlbumContextMenu(album: album)
                        }
                        .onAppear { onNeedsMore(album.id) }
                    }
                }
                .frame(width: renderedGridWidth, alignment: .top)
                // Let the viewport shrink before recomputing fixed cell sizes.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .top)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { contentWidth = geometry.size.width }
                            .onChange(of: geometry.size.width) { _, width in
                                contentWidth = width
                            }
                    }
                }
                .padding(.top, 25)
                .padding(.bottom, 24)
            }
            // Native populated Albums reserves one system scroller width
            // between its collection and the trailing edge of the viewport.
            .contentMargins(.trailing, NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay), for: .scrollContent)
            .focusable()
            .focused($isGridFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                handleArrowKey(press.key, proxy: proxy)
            }
            .onKeyPress(keys: [.return, .space]) { press in
                openSelectedAlbum()
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
        let navigator = GridNavigator(itemCount: albums.count, columnsPerRow: columnsPerRow)

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
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                proxy.scrollTo(newId, anchor: .center)
            }
            return .handled
        }
        return .ignored
    }

    /// Opens the selected album through the shared detail path so keyboard
    /// activation matches clicking a card (same navigationDestination route).
    private func openSelectedAlbum() -> KeyPress.Result {
        guard let album = selectedAlbumId.flatMap({ id in albums.first(where: { $0.id == id }) })
                ?? albums.first else { return .ignored }
        selectedAlbumId = album.id
        appState.detailNavigationPath.append(album)
        return .handled
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
        GridItem(.adaptive(minimum: 200, maximum: 200), spacing: 16, alignment: .top)
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
