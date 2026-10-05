import SwiftUI
import AppKit

struct SongsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewState: ViewState = .loading
    @State private var queryStore: LibrarySongQueryStore?
    @State private var sortColumn: SongSortColumn = .title
    @State private var sortAscending = true
    @State private var tableSortOrder: [KeyPathComparator<Song>] = [KeyPathComparator(\Song.title)]
    @State private var selection = Set<String>()
    @State private var syncProgress: Int = 0
    @State private var isSyncing = false
    @State private var loadGeneration = UUID()
    @State private var loadedServerID: UUID?
    @State private var loadedSelectionScope: SelectionScope?
    @State private var searchText = ""
    @State private var selectionGeneration = UUID()
    @State private var infoHydrationTask: Task<Void, Never>?
    @State private var playbackPreparationTask: Task<Void, Never>?
    @State private var playbackPreparationGeneration = UUID()

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

    typealias SongSortColumn = LibrarySongSort

    private struct SelectionScope: Hashable {
        let serverID: String
        let searchText: String
        let libraryMembershipRevision: UInt64
        let hiddenSongs: Set<String>
        let hiddenAlbums: Set<String>
        let hiddenArtists: Set<String>
    }

    private struct LoadKey: Hashable {
        let query: LibrarySongQuery?
        let scope: SelectionScope?
    }

    /// Comparator for one column/direction. Mirrors the native Table header
    /// state so header-click indicators and the localized sort stay in
    /// agreement in both directions.
    static func headerComparators(for column: SongSortColumn, ascending: Bool) -> [KeyPathComparator<Song>] {
        let order: SortOrder = ascending ? .forward : .reverse
        switch column {
        case .title: return [KeyPathComparator(\Song.title, order: order)]
        case .artist: return [KeyPathComparator(\Song.artist, order: order)]
        case .album: return [KeyPathComparator(\Song.album, order: order)]
        case .duration: return [KeyPathComparator(\Song.duration, order: order)]
        case .plays: return [KeyPathComparator(\Song.playCount, order: order)]
        case .dateAdded: return [KeyPathComparator(\Song.addedAt, order: order)]
        case .releaseDate: return [KeyPathComparator(\Song.releaseDate, order: order)]
        case .grouping: return [KeyPathComparator(\Song.groupingDisplay, order: order)]
        }
    }

    private var query: LibrarySongQuery? {
        guard let serverID = appState.activeServerId else { return nil }
        return LibrarySongQuery(
            serverID: serverID,
            searchText: searchText,
            sort: sortColumn,
            ascending: sortAscending
        )
    }

    private var selectionScope: SelectionScope? {
        guard let query else { return nil }
        return SelectionScope(
            serverID: query.serverID,
            searchText: query.normalizedSearchText,
            libraryMembershipRevision: appState.libraryMembershipRevision,
            hiddenSongs: appState.hiddenSongIds,
            hiddenAlbums: appState.hiddenAlbumIds,
            hiddenArtists: appState.hiddenArtistIds
        )
    }

    private var loadKey: LoadKey {
        LoadKey(query: query, scope: selectionScope)
    }

    /// Translates a native header sort (any direction) into the localized
    /// sort and refreshes the visible rows.
    private func applyHeaderSort(_ comparators: [KeyPathComparator<Song>]) {
        guard let first = comparators.first else { return }
        for column in SongSortColumn.allCases {
            for ascending in [true, false]
            where Self.headerComparators(for: column, ascending: ascending).first == first {
                sortColumn = column
                sortAscending = ascending
                return
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Native Songs capture12 starts with column headers, not a page
            // title/action banner. Sorting remains on the table headers;
            // library-wide playback actions remain in the empty-selection menu.
            Group {
                switch viewState {
                case .loading:
                    InlineLoadingStatusView(title: isSyncing ? "Syncing songs: \(syncProgress)…" : "Loading songs...")
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                case .empty:
                    CompactStatusView(
                        title: "No Songs",
                        systemImage: "music.note.list",
                        message: "Songs from your library will appear here."
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
                        Task { await loadSongs(for: loadKey) }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .populated:
                    if queryStore?.songs.isEmpty == true {
                        CompactStatusView(
                            title: "No Songs",
                            systemImage: "music.note.list",
                            message: "No songs match the current filters."
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        VStack(spacing: 0) {
                            SongTableView(
                                songs: queryStore?.songs ?? [],
                                selection: $selection,
                                nowPlayingId: appState.nowPlaying?.id,
                                cacheActor: appState.cacheActor,
                                networkActor: appState.networkActor,
                                onPlay: { song in
                                    startPlaybackPreparation(.starting(song))
                                },
                                onPlayAll: { shuffled in
                                    startPlaybackPreparation(.all(shuffled: shuffled))
                                },
                                onRowVisible: { songID in
                                    guard let store = queryStore,
                                          store.shouldLoadMore(afterVisibleSongID: songID) else { return }
                                    Task { await store.loadNextPage() }
                                },
                                onSelectAll: {
                                    Task { await selectAllMatchingSongs() }
                                },
                                selectedSongProvider: {
                                    try await resolveBulkSelection()
                                },
                                expectedServerID: queryStore?.context?.query.serverID,
                                totalMatchingCount: queryStore?.totalCount ?? 0,
                                tableSortOrder: $tableSortOrder,
                                isPlaybackActive: appState.playbackState == .playing
                            )
                            if let store = queryStore,
                               store.isLoadingMore || store.moreError != nil {
                                HStack(spacing: 10) {
                                    if store.isLoadingMore {
                                        ProgressView().controlSize(.small)
                                        Text("Loading more songs…")
                                            .foregroundStyle(.secondary)
                                    } else if let message = store.moreError {
                                        Text(message)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        Button("Try Again") {
                                            Task { await store.retryNextPage() }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    Spacer()
                                }
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.bar)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .searchable(text: $searchText, prompt: "Find in Songs")
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
                    Picker("Sort By", selection: $sortColumn) {
                        ForEach(SongSortColumn.allCases, id: \.self) { column in
                            Text(column.rawValue).tag(column)
                        }
                    }
                    Toggle("Ascending", isOn: $sortAscending)
                    Divider()
                    Button(isSyncing ? "Refreshing Songs…" : "Refresh Songs") {
                        guard let serverID = appState.activeServer?.id else { return }
                        let generation = UUID()
                        loadGeneration = generation
                        Task { await syncSongs(serverID: serverID, generation: generation) }
                    }
                    .disabled(isSyncing || appState.activeServer == nil)
                } label: {
                    Label("Sort Songs", systemImage: "line.3.horizontal.decrease")
                }
                .menuIndicator(.hidden)
            }
        }
        .task(id: loadKey) {
            cancelPlaybackPreparation()
            if !(query?.normalizedSearchText.isEmpty ?? true) {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            await loadSongs(for: loadKey)
        }
        .onDisappear {
            loadGeneration = UUID()
            queryStore?.cancel()
            infoHydrationTask?.cancel()
            cancelPlaybackPreparation()
            appState.songsInfoSelection = []
            #if DEBUG
            ParityControlBridge.shared.songPagingSnapshot = nil
            #endif
        }
        .onChange(of: tableSortOrder) { _, newOrder in
            applyHeaderSort(newOrder)
        }
        .onChange(of: sortColumn) { _, _ in updateSortOrder() }
        .onChange(of: sortAscending) { _, _ in updateSortOrder() }
        .onChange(of: selection) { _, _ in
            selectionGeneration = UUID()
            hydrateInfoSelection()
        }
    }

    private var toolbarTitle: some View {
        Text("Songs")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
    }

    private func updateSortOrder() {
        let newOrder = Self.headerComparators(for: sortColumn, ascending: sortAscending)
        if tableSortOrder != newOrder { tableSortOrder = newOrder }
    }

    private func loadSongs(for key: LoadKey) async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        loadGeneration = generation
        isSyncing = false
        syncProgress = 0
        guard let query = key.query, let scope = key.scope,
              let serverID = UUID(uuidString: query.serverID) else {
            queryStore = nil
            selection = []
            loadedServerID = nil
            loadedSelectionScope = nil
            viewState = .empty
            return
        }

        let serverChanged = loadedServerID != serverID
        let selectionScopeChanged = loadedSelectionScope != scope
        if serverChanged || queryStore == nil {
            queryStore = LibrarySongQueryStore(database: appState.databaseManager)
            selection = []
        }
        loadedServerID = serverID
        loadedSelectionScope = scope
        viewState = .loading
        guard let store = queryStore else { return }
        #if DEBUG
        if DeterministicCaptureFixture.isAtlasEnabled {
            ParityControlBridge.shared.songPagingSnapshot = { [weak store] in
                guard let store, store.context != nil else { return nil }
                return ["loadedSongs": store.songs.count, "totalMatches": store.totalCount,
                        "consumedRawOffset": store.consumedRawOffset,
                        "pageRequests": store.diagnosticPageRequestCount]
            }
        }
        #endif
        await store.loadFirstPage(matching: query)
        guard isCurrentLoad(generation, serverID: serverID), store.context?.query == query else { return }

        switch store.state {
        case .failed(let message):
            viewState = .error(.unknown(NSError(
                domain: "LibrarySongQuery",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )))
            return
        case .idle, .loading:
            return
        case .loaded:
            break
        }

        if selectionScopeChanged, !serverChanged, !selection.isEmpty,
           let context = store.context {
            do {
                if let valid = try await store.validIDs(selection, in: context) {
                    selection = valid
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentLoad(generation, serverID: serverID) else { return }
                viewState = .error((error as? ResonanceError) ?? .unknown(error))
                return
            }
        }

        if serverChanged, query.normalizedSearchText.isEmpty, store.totalCount == 0 {
            do {
                let hasCachedSongs = try await appState.databaseManager.hasAdmittedLibrarySongs(
                    serverID: query.serverID
                )
                guard isCurrentLoad(generation, serverID: serverID) else { return }
                if !hasCachedSongs {
                    await syncSongs(serverID: serverID, generation: generation)
                    return
                }
            } catch {
                guard isCurrentLoad(generation, serverID: serverID) else { return }
                viewState = .error((error as? ResonanceError) ?? .unknown(error))
                return
            }
        }
        viewState = query.normalizedSearchText.isEmpty && store.totalCount == 0 ? .empty : .populated
    }

    private func isCurrentLoad(_ generation: UUID, serverID: UUID) -> Bool {
        !Task.isCancelled && generation == loadGeneration && appState.activeServer?.id == serverID
    }

    private struct IncompleteSongSync: LocalizedError {
        let reason: String
        var errorDescription: String? { "Song sync is incomplete. \(reason)" }
    }

    /// Initial sync publishes only a successful admitted-library reread.
    private func syncSongs(serverID: UUID, generation: UUID) async {
        guard isCurrentLoad(generation, serverID: serverID) else { return }
        isSyncing = true
        syncProgress = 0
        defer {
            if generation == loadGeneration {
                isSyncing = false
                syncProgress = 0
            }
        }
        var seenIds = Set<String>()
        let pageSize = 500
        var offset = 0
        var walker = LibraryPageWalker(pageSize: pageSize, label: "song")

        do {
            pageLoop: while true {
                let batch = try await appState.networkActor.fetchSongPage(
                    offset: offset, pageSize: pageSize, expectedServerID: serverID
                )
                guard isCurrentLoad(generation, serverID: serverID) else { return }
                let newSongs = batch.filter { seenIds.insert($0.id).inserted }
                if !newSongs.isEmpty {
                    try appState.databaseManager.saveSongs(newSongs, serverId: serverID.uuidString)
                    syncProgress += newSongs.count
                }
                switch walker.step(batchCount: batch.count, newItemCount: newSongs.count,
                                   offset: offset, totalSoFar: syncProgress) {
                case .advance:
                    offset += batch.count
                case .stop(let outcome):
                    if let reason = outcome.truncationReason {
                        throw IncompleteSongSync(reason: reason)
                    }
                    break pageLoop
                }
            }

            appState.refreshLibraryMembershipIds()
            guard let query, let store = queryStore else { return }
            await store.loadFirstPage(matching: query)
            guard isCurrentLoad(generation, serverID: serverID) else { return }
            viewState = store.totalCount == 0 ? .empty : .populated
        } catch {
            guard isCurrentLoad(generation, serverID: serverID) else { return }
            viewState = .error((error as? ResonanceError) ?? .unknown(error))
        }
    }

    private enum PlaybackPreparation {
        case all(shuffled: Bool)
        case starting(Song)
    }

    private func startPlaybackPreparation(_ request: PlaybackPreparation) {
        let previous = playbackPreparationTask
        previous?.cancel()
        let generation = UUID()
        playbackPreparationGeneration = generation
        playbackPreparationTask = Task { @MainActor in
            defer {
                if playbackPreparationGeneration == generation {
                    playbackPreparationTask = nil
                }
            }
            // SQLite row decoding is synchronous inside the database pool read.
            // Wait for the canceled request to unwind before starting another
            // full query, so repeated Play All clicks cannot decode in parallel.
            await previous?.value
            guard !Task.isCancelled, playbackPreparationGeneration == generation else { return }
            do {
                try await preparePlayback(request)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, playbackPreparationGeneration == generation else { return }
                appState.showFeedback(
                    message: "Couldn't prepare the songs",
                    detail: error.localizedDescription,
                    style: .error,
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    private func cancelPlaybackPreparation() {
        playbackPreparationGeneration = UUID()
        playbackPreparationTask?.cancel()
        playbackPreparationTask = nil
    }

    private func preparePlayback(_ request: PlaybackPreparation) async throws {
        guard let store = queryStore, let context = store.context else { return }
        guard var songsToPlay = try await store.materializeSongs(in: context) else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        guard store.context == context,
              query == context.query,
              appState.activeServerId == context.query.serverID else {
            throw CancellationError()
        }

        let startingIndex: Int
        switch request {
        case .all(let shuffled):
            if shuffled { songsToPlay.shuffle() }
            startingIndex = 0
        case .starting(let song):
            guard let index = songsToPlay.firstIndex(where: { $0.id == song.id }) else {
                throw CancellationError()
            }
            startingIndex = index
        }
        try Task.checkCancellation()
        guard query == context.query,
              appState.activeServerId == context.query.serverID else {
            throw CancellationError()
        }
        await appState.playbackManager.play(songs: songsToPlay, startingAt: startingIndex)
    }

    private func selectAllMatchingSongs() async {
        guard let store = queryStore, let context = store.context else { return }
        let requestSelectionGeneration = selectionGeneration
        guard let ids = try? await store.allIDs(in: context) else { return }
        guard store.context == context,
              query == context.query,
              requestSelectionGeneration == selectionGeneration,
              appState.activeServerId == context.query.serverID else { return }
        selection = Set(ids)
    }

    private struct StaleSongSelection: LocalizedError {
        var errorDescription: String? { "The Songs selection changed. Try the action again." }
    }

    private func resolveBulkSelection() async throws -> [Song] {
        guard let store = queryStore, let context = store.context else { throw StaleSongSelection() }
        let selectedIDs = selection
        let requestSelectionGeneration = selectionGeneration
        let serverID = appState.activeServerId
        guard let songs = try await store.resolveSongs(selectedIDs, in: context),
              requestSelectionGeneration == selectionGeneration,
              selectedIDs == selection,
              serverID == appState.activeServerId else { throw StaleSongSelection() }
        return songs
    }

    private func hydrateInfoSelection() {
        infoHydrationTask?.cancel()
        appState.songsInfoSelection = []
        guard selection.count == 1, let selectedID = selection.first,
              let store = queryStore, let context = store.context else { return }
        let requestSelectionGeneration = selectionGeneration
        if let loaded = store.songs.first(where: { $0.id == selectedID }) {
            appState.songsInfoSelection = [loaded]
            return
        }
        infoHydrationTask = Task {
            guard let resolved = try? await store.resolveSongs([selectedID], in: context),
                  !Task.isCancelled,
                  requestSelectionGeneration == selectionGeneration,
                  selection == Set([selectedID]) else { return }
            appState.songsInfoSelection = resolved
        }
    }
}

struct SongTableView: View {
    @Environment(AppState.self) private var appState
    let songs: [Song]
    @Binding var selection: Set<String>
    let nowPlayingId: String?
    let cacheActor: CacheActor
    let networkActor: NetworkActor
    let onPlay: (Song) -> Void
    var onPlayAll: (Bool) -> Void = { _ in }
    var onRowVisible: (String) -> Void = { _ in }
    var onSelectAll: () -> Void = {}
    var selectedSongProvider: (@MainActor () async throws -> [Song])? = nil
    var expectedServerID: String? = nil
    var totalMatchingCount: Int = 0
    @Binding var tableSortOrder: [KeyPathComparator<Song>]
    var isPlaybackActive: Bool = false

    @State private var downloadedSongIds = Set<String>()
    @State private var columnCustomization = TableColumnCustomization<Song>()
    @State private var didLoadColumnCustomization = false

    private struct DownloadStatusKey: Equatable {
        let serverID: UUID?
        let revision: UInt64
    }

    private var downloadStatusKey: DownloadStatusKey {
        let serverID = appState.activeServer?.id
        return DownloadStatusKey(
            serverID: serverID,
            revision: serverID.map { cacheActor.downloadProgress.manifestRevisions[$0, default: 0] } ?? 0
        )
    }

    @State private var focusedSongId: String?
    @State private var previousSelection: Set<String> = []
    @State private var tableSelection = Set<String>()

    @FocusState private var isTableFocused: Bool

    private var nativeTableSelection: Binding<Set<String>> {
        Binding(
            get: { tableSelection },
            set: { acceptNativeTableSelection($0) }
        )
    }

    @TableColumnBuilder<Song, KeyPathComparator<Song>>
    private var identityColumns: some TableColumnContent<Song, KeyPathComparator<Song>> {
        TableColumn(Text("").accessibilityLabel("Playback status")) { song in
            if nowPlayingId == song.id {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                    .opacity(isPlaybackActive ? 1 : 0.45)
                    .accessibilityLabel(isPlaybackActive ? "Now playing" : "Paused")
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear { onRowVisible(song.id) }
        }
        .width(9)
        .customizationID("playback")
        .disabledCustomizationBehavior(.all)

        TableColumn("Title", sortUsing: KeyPathComparator(\Song.title)) { song in
            // Music 1.7's captured Songs table uses text-only title cells.
            // Do not force an artwork-sized row or fetch artwork per row.
            HStack(spacing: 4) {
                Text(song.title)
                    .fontWeight(nowPlayingId == song.id ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(song.title)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Capture12 has a persistent trailing ellipsis in every
                // title cell. Ink bounds are known, not native hit bounds.
                Menu {
                    SongContextMenu(song: song)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More for \(song.title)")
                .help("More")
            }
        }
        .width(min: 160, ideal: 240, max: 320)
        .customizationID("title")
        .disabledCustomizationBehavior(.visibility)

        // Native Songs capture12 places the cloud/status column here.
        // Rendered width27px; point width and exact glyph remain unverified.
        TableColumn(Text(Image(systemName: "icloud")).accessibilityLabel("Download status")) { song in
            if downloadedSongIds.contains(song.id) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Downloaded for offline playback")
                    .accessibilityLabel("Downloaded for offline playback")
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }
        .width(12)
        .customizationID("download")

        TableColumn("Time", sortUsing: KeyPathComparator(\Song.duration)) { song in
            Text(song.formattedDuration)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .width(40)
        .alignment(.numeric)
        .customizationID("time")
    }

    @TableColumnBuilder<Song, KeyPathComparator<Song>>
    private var metadataColumns: some TableColumnContent<Song, KeyPathComparator<Song>> {
        TableColumn("Artist", value: \.artist)
            .width(min: 80, ideal: 113, max: 240)
            .customizationID("artist")

        TableColumn("Album", value: \.album)
            .width(min: 80, ideal: 97, max: 240)
            .customizationID("album")

        TableColumn("Genre") { song in
            Text(song.genre ?? "")
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .width(min: 50, ideal: 65, max: 180)
        .customizationID("genre")

        TableColumn(Text("☆").accessibilityLabel("Favorite")) { song in
            if song.starred != nil {
                Image(systemName: "star.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                    .accessibilityLabel("Favorite")
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .width(15)
        .customizationID("favorite")
    }

    @TableColumnBuilder<Song, KeyPathComparator<Song>>
    private var dateColumns: some TableColumnContent<Song, KeyPathComparator<Song>> {
        // Native capture12 places Plays immediately after Favorite.
        // Unknown server metadata stays blank, distinct from a known zero.
        TableColumn("Plays", sortUsing: KeyPathComparator(\Song.playCount)) { song in
            Text(song.playCount.map(String.init) ?? "")
                .monospacedDigit()
                .lineLimit(1)
        }
        .width(min: 40, ideal: 40, max: 65)
        .alignment(.numeric)
        .customizationID("plays")

        // Server Child.created only; never cache or local admission time.
        TableColumn("Date Added", sortUsing: KeyPathComparator(\Song.addedAt)) { song in
            if let addedAt = song.addedAt {
                Text(addedAt.formatted(Date.FormatStyle(date: .numeric, time: .shortened).year(.twoDigits)))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("")
            }
        }
        .width(min: 103, ideal: 103, max: 140)
        .customizationID("date-added")

        TableColumn("Release Date", sortUsing: KeyPathComparator(\Song.releaseDate)) { song in
            Text(song.releaseDate?.displayValue ?? "")
                .lineLimit(1)
                .help(song.releaseDate?.storageValue ?? "Release date unavailable")
        }
        .width(min: 75, ideal: 79, max: 150)
        .customizationID("release-date")

        TableColumn("Grouping", sortUsing: KeyPathComparator(\Song.groupingDisplay)) { song in
            Text(song.groupingDisplay)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(song.groupingDisplay)
        }
        .width(min: 100, ideal: 150)
        .customizationID("grouping")
    }

    var body: some View {
        Table(songs, selection: nativeTableSelection, sortOrder: $tableSortOrder,
              columnCustomization: $columnCustomization) {
            identityColumns
            metadataColumns
            dateColumns
        }
        .onAppear {
            guard !didLoadColumnCustomization else { return }
            let data: Data?
            if DeterministicCaptureFixture.isEnabled {
                data = fixtureColumnCustomizationURL.flatMap { try? Data(contentsOf: $0) }
            } else {
                data = UserDefaults.standard.data(forKey: "songsColumnCustomization")
            }
            if let data,
               let saved = try? JSONDecoder().decode(TableColumnCustomization<Song>.self, from: data) {
                columnCustomization = saved
            }
            didLoadColumnCustomization = true
        }
        .onChange(of: columnCustomization) { _, value in
            guard didLoadColumnCustomization,
                  let data = try? JSONEncoder().encode(value) else { return }
            if DeterministicCaptureFixture.isEnabled {
                // Exercise the same Codable state without touching live preferences.
                if let url = fixtureColumnCustomizationURL { try? data.write(to: url, options: .atomic) }
            } else {
                UserDefaults.standard.set(data, forKey: "songsColumnCustomization")
            }
        }
        .task(id: downloadStatusKey) {
            let key = downloadStatusKey
            downloadedSongIds = []
            guard let serverID = key.serverID else { return }
            // One manifest enumeration per server/revision, not per-row
            // network/artwork requests. Incidental playback cache is excluded.
            let downloaded = await cacheActor.enumerateDownloadedSongs(serverId: serverID)
            guard !Task.isCancelled, key == downloadStatusKey else { return }
            downloadedSongIds = Set(downloaded.map(\.songId))
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .background(SongTableRowMetrics())
        .frame(minHeight: 240, maxHeight: .infinity)
        .focusable()
        .focused($isTableFocused)
        .focusEffectDisabled()
        .onChange(of: songs, initial: true) { _, _ in configureControlSelection() }
        .onDisappear {
            appState.songsInfoSelection = []
            #if DEBUG
            ParityControlBridge.shared.selectSongs = nil
            #endif
        }
        .contextMenu(forSelectionType: String.self) { selectedIds in
            let selectedSongs = songs.filter { selectedIds.contains($0.id) }
            let targetsCurrentSelection = LibraryTableSelection.contextTargetsGlobalSelection(
                nativeTarget: selectedIds,
                tableSelection: tableSelection,
                globalSelection: selection
            )
            if targetsCurrentSelection, selection.count > 1, let selectedSongProvider {
                BulkSongContextMenu(
                    selectedCount: selection.count,
                    expectedServerID: expectedServerID,
                    songProvider: selectedSongProvider
                )
            } else if let song = selectedSongs.first {
                SongContextMenu(song: song)
            } else {
                Button("Play All") { onPlayAll(false) }
                    .disabled(totalMatchingCount == 0)
                Button("Shuffle All") { onPlayAll(true) }
                    .disabled(totalMatchingCount == 0)
            }
        } primaryAction: { selectedIds in
            if let song = actionSong(in: selectedIds) {
                onPlay(song)
            }
        }
        .onKeyPress(.return) {
            if let song = actionSong(in: selection) {
                onPlay(song)
                return .handled
            }
            return .ignored
        }
        .onKeyPress("a", phases: .down) { keyPress in
            guard keyPress.modifiers == .command else { return .ignored }
            onSelectAll()
            return .handled
        }
        .onAppear {
            isTableFocused = true
        }
        .onChange(of: songs.map(\.id), initial: true) { _, visibleIDs in
            let loadedIDs = Set(visibleIDs)
            tableSelection = selection.intersection(loadedIDs)
            if let focusedSongId, !selection.contains(focusedSongId) {
                self.focusedSongId = nil
            }
            previousSelection = tableSelection
        }
        .onChange(of: selection) { _, newSelection in
            let loadedIDs = Set(songs.map(\.id))
            let projected = newSelection.intersection(loadedIDs)
            if tableSelection != projected { tableSelection = projected }
        }
    }

    private func acceptNativeTableSelection(_ newSelection: Set<String>) {
        let loadedIDs = Set(songs.map(\.id))
        let modifiers = NSApp.currentEvent?.modifierFlags
            .intersection(.deviceIndependentFlagsMask) ?? []
        let updated = LibraryTableSelection.applyingNativeSelection(
            global: selection,
            loadedIDs: loadedIDs,
            table: newSelection,
            isAdditive: modifiers.contains(.command)
        )
        tableSelection = newSelection
        if selection != updated { selection = updated }

        let added = newSelection.subtracting(previousSelection)
        // A single added identity identifies a new focus candidate; a
        // range/discontiguous set does not identify its native focus edge.
        if added.count == 1 {
            focusedSongId = added.first
        } else if let focusedSongId, !newSelection.contains(focusedSongId) {
            self.focusedSongId = nil
        }
        previousSelection = newSelection
    }

    private func actionSong(in selectedIDs: Set<String>) -> Song? {
        if let focusedSongId, selectedIDs.contains(focusedSongId),
           let focused = songs.first(where: { $0.id == focusedSongId }) {
            return focused
        }
        // Deterministic visible-order fallback, not arbitrary Set iteration.
        return songs.first(where: { selectedIDs.contains($0.id) })
    }

    private var fixtureColumnCustomizationURL: URL? {
        DeterministicCaptureFixture.configuration?.scratchRoot?
            .appendingPathComponent("songs-column-customization.json")
    }

    private func configureControlSelection() {
        #if DEBUG
        guard DeterministicCaptureFixture.isAtlasEnabled else { return }
        ParityControlBridge.shared.selectSongs = { indices in
            guard indices.allSatisfy({ songs.indices.contains($0) }) else {
                throw NSError(domain: "ParityControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Visible Songs rows changed"])
            }
            selection = Set(indices.map { songs[$0].id })
        }
        #endif
    }
}

#Preview {
    SongsView()
        .environment(AppState())
}

// Captured Songs stripe pitch is22px at1x. SwiftUI resets rowHeight during
// updates; retain this measured pitch without replacing its delegate/data source.
private struct SongTableRowMetrics: NSViewRepresentable {
    func makeNSView(context: Context) -> MetricView { MetricView() }
    func updateNSView(_ nsView: MetricView, context: Context) { nsView.scheduleConfiguration() }

    final class MetricView: NSView {
        private weak var observedTable: NSTableView?
        private var heightObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                heightObservation = nil
                observedTable = nil
                return
            }
            scheduleConfiguration()
        }
        override func layout() {
            super.layout()
            scheduleConfiguration()
        }
        func scheduleConfiguration() {
            DispatchQueue.main.async { [weak self] in self?.configureTable() }
        }
        private func configureTable() {
            guard window != nil else { return }
            var container = superview
            while let current = container {
                let tables = Self.tables(in: current)
                if tables.count == 1, let table = tables.first {
                    if observedTable !== table {
                        observedTable = table
                        heightObservation = table.observe(\.rowHeight, options: [.new]) { [weak self] _, _ in
                            Task { @MainActor [weak self] in self?.configureTable() }
                        }
                    }
                    if table.usesAutomaticRowHeights || table.rowHeight != 22 {
                        table.usesAutomaticRowHeights = false
                        table.rowSizeStyle = .custom
                        table.rowHeight = 22
                        table.needsLayout = true
                    }
                    // Captured TrackDisplayHeader is 23 points, not AppKit's
                    // default 28-point SwiftUI table header allocation.
                    if let header = table.headerView, header.frame.height != 23 {
                        header.setFrameSize(NSSize(width: header.frame.width, height: 23))
                        table.enclosingScrollView?.tile()
                    }
                    return
                }
                if tables.count > 1 { return }
                container = current.superview
            }
        }
        private static func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView {
                return table.numberOfColumns > 1 ? [table] : []
            }
            return view.subviews.flatMap { tables(in: $0) }
        }
    }
}
