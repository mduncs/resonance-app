import SwiftUI
import AppKit

// MARK: - Sequence Extension

private extension Sequence where Element: Hashable {
    /// Returns an array with duplicate elements removed, preserving order.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Album Detail View

struct AlbumDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let album: Album

    @State private var songs: [Song] = []
    @State private var viewState: ViewState = .loading
    @State private var moreByArtist: [Album] = []
    @State private var isLoadingMore = false
    @State private var moreByArtistError: ResonanceError?
    @State private var songsLoadGeneration = UUID()
    @State private var moreLoadGeneration = UUID()
    @State private var loadRetry = 0
    @State private var presentationState: AlbumDetailPresentationState

    private struct PointMetadataKey: Hashable {
        let serverID: String?
        let albumID: String
        let libraryRevision: UInt64
    }

    private var pointMetadataKey: PointMetadataKey {
        PointMetadataKey(serverID: appState.activeServerId, albumID: album.id,
                         libraryRevision: appState.libraryMembershipRevision)
    }

    private var displayedAlbum: Album {
        _ = appState.albumPresentationRevision
        return presentationState.displayed(using: appState.albumPresentationStore)
    }

    private var isStarred: Bool { displayedAlbum.starred != nil }

    private struct LoadIdentity: Equatable {
        let serverId: String?
        let albumId: String
        let artistId: String
        let retry: Int
    }

    private var loadIdentity: LoadIdentity {
        LoadIdentity(serverId: appState.activeServerId, albumId: album.id,
                     artistId: displayedAlbum.artistId, retry: loadRetry)
    }
    @State private var selectedArtist: Artist?
    @State private var artistNavigationTask: Task<Void, Never>?
    @State private var selectedGenre: String?
    @State private var cachedSongsByDisc: [(disc: Int, songs: [Song])] = []
    @State private var searchText: String = ""
    @State private var trackSelection = OrderedItemSelection<String>()
    @State private var displayedTrackIDs: [String] = []
    @State private var selectedTrackSongs: [Song] = []
    @State private var playbackIndexByTrackID: [String: Int] = [:]
    /// Captured on init to persist highlight even after AppState clears it
    @State private var highlightSongId: String?

    enum ViewState: Equatable {
        case loading
        case error(ResonanceError)
        case populated

        static func == (lhs: ViewState, rhs: ViewState) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading), (.populated, .populated):
                return true
            case (.error, .error):
                return true  // Compare by case only, not error details
            default:
                return false
            }
        }
    }

    init(album: Album) {
        self.album = album
        self._presentationState = State(initialValue: AlbumDetailPresentationState(navigation: album))
    }

    /// Current song ID from playback for highlighting
    private var currentSongId: String? {
        appState.queueManager.currentItem?.song.id
    }

    /// Songs grouped by disc number (cached to avoid recomputing on every render)
    private var songsByDisc: [(disc: Int, songs: [Song])] {
        cachedSongsByDisc
    }

    private func updateSongsByDisc() {
        let grouped = Dictionary(grouping: songs) { $0.effectiveAlbumDiscNumber }
        cachedSongsByDisc = grouped.keys.sorted().map { (disc: $0, songs: grouped[$0]!.sortedForAlbum()) }
        refreshTrackProjection()
    }

    /// Whether to show disc separators (only if multiple discs)
    private var hasMultipleDiscs: Bool {
        songsByDisc.count > 1
    }

    private var isAlbumAdmitted: Bool {
        appState.admittedAlbumIds.contains(album.id)
    }

    /// Songs filtered by search text
    private var filteredSongs: [Song] {
        guard !searchText.isEmpty else { return songs }
        let query = searchText.lowercased()
        return songs.filter {
            $0.title.lowercased().contains(query) ||
            $0.artist.lowercased().contains(query)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    AlbumHeaderView(
                    album: displayedAlbum,
                    songs: songs,
                    isStarred: isStarred,
                    onPlay: {
                        Task {
                            await appState.playbackManager.play(songs: songs)
                        }
                    },
                    onShuffle: {
                        Task {
                            await appState.playbackManager.play(songs: songs.shuffled())
                        }
                    },
                    onToggleStar: {
                        Task {
                            await toggleAlbumStar()
                        }
                    },
                    onArtistTap: {
                        navigateToArtist()
                    },
                    onGenreTap: { genre in
                        selectedGenre = genre
                    }
                )

                if !isAlbumAdmitted {
                    ReleaseShadowBanner(
                        title: "Release Shadow",
                        detail: "\(displayedAlbum.name) is outside Library",
                        actionTitle: "Admit"
                    ) {
                        Task {
                            await admitAlbum()
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }

                // Track list
                switch viewState {
                case .loading:
                    let placeholderCount = max(3, min(album.songCount, 15))
                    ForEach(0..<placeholderCount, id: \.self) { _ in
                        SongRow(song: .placeholder)
                            .redacted(reason: .placeholder)
                    }
                    .padding(.horizontal)

                case .error(let error):
                    CompactStatusView(
                        title: error.errorTitle,
                        systemImage: error.systemImage,
                        message: error.errorDescription,
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise"
                    ) {
                        loadRetry += 1
                    }
                    .padding(.horizontal)

                case .populated:
                    trackListView
                        .padding(.trailing, NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay))

                    // Available release metadata and track summary
                    creditsSection

                    // More by Artist section
                    moreByArtistSection
                }
            }
        }
        .onChange(of: viewState) { _, newState in
            // Scroll to highlighted song after songs load
            if case .populated = newState, let songId = highlightSongId {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                        proxy.scrollTo(songId, anchor: .center)
                    }
                }
            }
        }
        .onChange(of: trackSelection.focusedID) { _, id in
            guard let id else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        }
        .navigationTitle(displayedAlbum.name)
        .searchable(text: $searchText, prompt: "Find in Album")
        .background(LibrarySearchFieldMetrics().frame(width: 0, height: 0))
        .toolbar {
            ToolbarItem(placement: .principal) { Spacer() }
            // .primaryAction keeps these trailing; without an explicit placement
            // .automatic drops them next to the back chevron, where they read as
            // a second transport cluster competing with the floating bar.
            // Play/Shuffle live in AlbumHeaderView, so they are not repeated here.
            ToolbarItemGroup(placement: .primaryAction) {
                if !isAlbumAdmitted {
                    Button {
                        Task {
                            await admitAlbum()
                        }
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .help("Admit Album")
                }

                Menu {
                    Button {
                        // Add to queue
                        songs.forEach { appState.playbackManager.addToQueue($0) }
                    } label: {
                        Label("Add to Queue", systemImage: "text.badge.plus")
                    }

                    Button {
                        // Play next
                        songs.reversed().forEach { appState.playbackManager.playNext($0) }
                    } label: {
                        Label("Play Next", systemImage: "text.insert")
                    }

                    Divider()

                    Button {
                        Task {
                            await toggleAlbumStar()
                        }
                    } label: {
                        Label(isStarred ? "Remove from Favorites" : "Add to Favorites",
                              systemImage: isStarred ? "star.fill" : "star")
                    }

                    // Rating picker
                    RatingPicker(currentRating: displayedAlbum.rating) { newRating in
                        setRating(newRating)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
            }
        }
        .task(id: loadIdentity) {
            await loadSongs(identity: loadIdentity)
        }
        .task(id: pointMetadataKey) {
            await loadPointMetadata(key: pointMetadataKey)
        }
        .onChange(of: appState.albumPresentationRevision) { _, _ in
            presentationState.absorbAcknowledged(appState.albumPresentationStore)
        }
        .task(id: loadIdentity) {
            await loadMoreByArtist(identity: loadIdentity)
        }
        .onAppear {
#if DEBUG
            if DeterministicCaptureFixture.isAtlasEnabled {
                ParityControlBridge.shared.detailSelectionSnapshot = { [self] in
                    let ordered = displayedTrackIDs
                    return ["kind": "album", "orderedSongIDs": ordered,
                            "selectedIndices": ordered.indices.filter { trackSelection.selectedIDs.contains(ordered[$0]) },
                            "focusedIndex": trackSelection.focusedID.flatMap { ordered.firstIndex(of: $0) } ?? NSNull() as Any]
                }
            }
#endif
            // Capture the highlight song ID from AppState (set by NowPlayingBar navigation)
            if let songId = appState.navigationTargetSongId {
                highlightSongId = songId
                appState.navigationTargetSongId = nil  // Clear after capturing
            }
        }
        .onChange(of: selectedGenre) { _, genre in
            if let genre {
                appState.detailNavigationPath.append(
                    Genre(
                        name: genre,
                        songCount: songs.filter { $0.genre == genre }.count,
                        albumCount: albumsMatchingGenre(genre).count
                    )
                )
                selectedGenre = nil
            }
        }
        .onChange(of: searchText) { _, _ in
            refreshTrackProjection()
        }
        .onDisappear {
            artistNavigationTask?.cancel()
#if DEBUG
            if DeterministicCaptureFixture.isAtlasEnabled {
                ParityControlBridge.shared.detailSelectionSnapshot = nil
            }
#endif
        }
    }

    // MARK: - Track List View

    @ViewBuilder
    private var trackListView: some View {
        let songsToDisplay = filteredSongs
        let isSearching = !searchText.isEmpty

        LazyVStack(spacing: 0) {
            if songs.isEmpty {
                CompactStatusView(
                    title: "No Songs",
                    systemImage: "music.note",
                    message: "No tracks found for this album."
                )
                .padding(.vertical, 40)
            } else if isSearching {
                // Flat list when searching
                if songsToDisplay.isEmpty {
                    CompactStatusView(
                        title: "No Results",
                        systemImage: "magnifyingglass",
                        message: "No tracks match \"\(searchText)\"."
                    )
                        .padding(.vertical, 40)
                } else {
                    ForEach(Array(songsToDisplay.enumerated()), id: \.element.id) { index, song in
                        trackRow(song: song, index: songs.firstIndex(of: song) ?? index)
                            .id(song.id)

                            .overlay(alignment: .bottom) {
                                if index < songsToDisplay.count - 1 {
                                    Divider()
                                        .padding(.leading, 50)
                                }
                            }
                    }
                }
            } else if hasMultipleDiscs {
                ForEach(songsByDisc, id: \.disc) { discGroup in
                    // Disc header
                    HStack {
                        Text("Disc \(discGroup.disc)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, discGroup.disc == 1 ? 8 : 24)
                    .padding(.bottom, 8)

                    // Songs in this disc
                    ForEach(Array(discGroup.songs.enumerated()), id: \.element.id) { index, song in
                        trackRow(song: song, index: songs.firstIndex(of: song) ?? index)
                            .id(song.id)

                            .overlay(alignment: .bottom) {
                                if index < discGroup.songs.count - 1 {
                                    Divider()
                                        .padding(.leading, 50)
                                }
                            }
                    }
                }
            } else {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    trackRow(song: song, index: index)
                        .id(song.id)

                        .overlay(alignment: .bottom) {
                            if index < songs.count - 1 {
                                Divider()
                                    .padding(.leading, 50)
                            }
                        }
                }
            }
        }
    }

    /// This is the actual visual ordering (including disc groups), rather than
    /// the transport order returned by the server.
    private var displaySongIDs: [String] { displayedTrackIDs }

    private func refreshTrackProjection() {
        let ids = searchText.isEmpty
            ? (hasMultipleDiscs ? songsByDisc.flatMap { $0.songs.map(\.id) } : songs.map(\.id))
            : filteredSongs.map(\.id)
        displayedTrackIDs = ids
        playbackIndexByTrackID = Dictionary(uniqueKeysWithValues: songs.enumerated().map { ($0.element.id, $0.offset) })
        trackSelection.prune(to: ids)
        let songsByID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        selectedTrackSongs = trackSelection.idsInDisplayOrder(ids).compactMap { songsByID[$0] }
    }

    private func selectTrack(_ id: String, modifiers: NSEvent.ModifierFlags) {
        trackSelection.click(id, in: displayedTrackIDs, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
        refreshTrackProjection()
    }

    private func moveTrackSelection(_ offset: Int, modifiers: NSEvent.ModifierFlags) {
        _ = trackSelection.moveFocus(by: offset, in: displayedTrackIDs, extending: modifiers.contains(.shift))
        refreshTrackProjection()
    }

    private func playFocusedTrack() {
        guard let id = trackSelection.focusedID, let index = playbackIndexByTrackID[id] else { return }
        Task { await appState.playbackManager.play(songs: songs, startingAt: index) }
    }

    @ViewBuilder
    private func trackRow(song: Song, index: Int) -> some View {
        let isPlaying = song.id == currentSongId
        let isHighlighted = song.id == highlightSongId

        AlbumTrackRow(
            song: song,
            albumArtist: album.artist,
            isPlaying: isPlaying,
            isHighlighted: isHighlighted,
            isSelected: trackSelection.selectedIDs.contains(song.id),
            selectedSongs: selectedTrackSongs,
            onSelect: { modifiers in
                selectTrack(song.id, modifiers: modifiers)
            },
            onFocus: { trackSelection.focus(song.id, in: displayedTrackIDs) },
            onMove: { offset, modifiers in
                moveTrackSelection(offset, modifiers: modifiers)
            },
            onSelectAll: { trackSelection.selectAll(in: displaySongIDs); refreshTrackProjection() },
            onActivateFocused: { playFocusedTrack() },
            onDoubleTap: {
                Task {
                    await appState.playbackManager.play(songs: songs, startingAt: index)
                }
            }
        )
        .contextMenu {
            if trackSelection.selectedIDs.contains(song.id), selectedTrackSongs.count > 1 {
                BulkSongContextMenu(songs: selectedTrackSongs)
            } else {
                SongContextMenu(song: song)
            }
        }
    }

    // MARK: - Album Summary

    private var creditsSection: some View {
        // Native places a plain multiline summary below the tracks, not an
        // About heading and a material card. Only show metadata we actually have.
        Text(albumSummary)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 51)
            .padding(.trailing, 34)
            .padding(.top, 28)
            .padding(.bottom, 55)
            .accessibilityIdentifier("summary")
    }

    private var albumSummary: String {
        var lines: [String] = []
        if let releaseDate = displayedAlbum.releaseDate, releaseDate.storageValue != nil {
            lines.append(releaseDate.summaryDisplayValue)
        } else if let year = displayedAlbum.year {
            // A known year is shown at its actual precision, not a guessed day.
            lines.append(String(year))
        }
        let stats = AlbumFooterStats(songs: songs)
        lines.append("\(stats.songCount) \(stats.songCount == 1 ? "song" : "songs"), \(stats.formattedDuration)")
        return lines.joined(separator: "\n")
    }

    private func albumsMatchingGenre(_ genre: String) -> Set<String> {
        Set(songs.filter { $0.genre == genre }.map(\.albumId))
    }

    // MARK: - More by Artist Section

    @ViewBuilder
    private var moreByArtistSection: some View {
        let otherAlbums = moreByArtist.filter { $0.id != album.id }

        if !otherAlbums.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Native shelf header occupies 47 points, with its navigation
                // button 34 points from the collection edge and 15 from the top.
                Button {
                    navigateToArtist()
                } label: {
                    HStack(spacing: 4) {
                        Text("More By \(displayedAlbum.artist)")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More By \(displayedAlbum.artist)")
                .accessibilityIdentifier("MoreByArtist")
                .padding(.top, 15)
                .padding(.horizontal, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 47, alignment: .topLeading)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(otherAlbums.prefix(10)) { otherAlbum in
                            AlbumCardActionSurface(
                                album: otherAlbum,
                                onPlay: { Task { await playAlbum(otherAlbum) } }
                            ) { artworkHoverChanged in
                                Button {
                                    appState.detailNavigationPath.append(otherAlbum)
                                } label: {
                                    // Current native More By shelf: artwork180,
                                    // column pitch200, two-line title and year.
                                    AlbumCard(
                                        album: otherAlbum,
                                        titleLineLimit: 2,
                                        artworkSize: 180,
                                        subtitleOverride: otherAlbum.year.map(String.init) ?? "",
                                        libraryTypography: true,
                                        showsHoverPlayButton: false,
                                        onArtworkHoverChange: artworkHoverChanged
                                    )
                                    .frame(height: 232, alignment: .top)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("MoreByAlbum-\(otherAlbum.id)")
                            }
                            .contextMenu {
                                Button {
                                    Task {
                                        await playAlbum(otherAlbum)
                                    }
                                } label: {
                                    Label("Play", systemImage: "play")
                                }

                                Button {
                                    Task {
                                        await playAlbum(otherAlbum, shuffled: true)
                                    }
                                } label: {
                                    Label("Shuffle", systemImage: "shuffle")
                                }

                                Button {
                                    Task {
                                        await addAlbumToQueue(otherAlbum)
                                    }
                                } label: {
                                    Label("Add to Queue", systemImage: "text.badge.plus")
                                }

                                Divider()

                                Button {
                                    appState.getInfoContent = .album(otherAlbum)
                                } label: {
                                    Label("Get Info", systemImage: "info.circle")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 34)
                }
            }
            .padding(.bottom, 12)
            .padding(.trailing, NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay))
        } else if let error = moreByArtistError {
            CompactStatusView(
                title: "Couldn’t Load More by Artist",
                systemImage: error.systemImage,
                message: error.errorDescription,
                actionTitle: "Retry",
                actionSystemImage: "arrow.clockwise"
            ) {
                loadRetry += 1
            }
            .padding(.horizontal)
        } else if isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        }
    }

    // MARK: - Actions

    private func ownsSongsLoad(_ generation: UUID, identity: LoadIdentity) -> Bool {
        !Task.isCancelled && generation == songsLoadGeneration && identity == loadIdentity
    }

    private func ownsMoreLoad(_ generation: UUID, identity: LoadIdentity) -> Bool {
        !Task.isCancelled && generation == moreLoadGeneration && identity == loadIdentity
    }

    private func loadPointMetadata(key: PointMetadataKey) async {
        guard let serverID = key.serverID else { return }
        do {
            let fresh = try await appState.databaseManager.cachedAlbum(
                id: key.albumID, serverID: serverID
            )
            guard !Task.isCancelled, key == pointMetadataKey else { return }
            presentationState.updatePoint(fresh, store: appState.albumPresentationStore)
        } catch is CancellationError {
            return
        } catch {
            // The navigation payload remains usable if a point cache read fails.
        }
    }

    private func loadSongs(identity: LoadIdentity) async {
        guard !Task.isCancelled, identity == loadIdentity else { return }
        let generation = UUID()
        songsLoadGeneration = generation
        songs = []
        cachedSongsByDisc = []
        viewState = .loading
        guard let serverId = identity.serverId else {
            viewState = .error(.notConfigured)
            return
        }

        do {
            let fetchedSongs = try await appState.networkActor.fetchAlbumSongs(albumId: identity.albumId, expectedServerID: UUID(uuidString: serverId))
            guard ownsSongsLoad(generation, identity: identity) else { return }
            // Read the captured server's policy, never a new server's sets or a
            // fail-open fallback after a suspended request.
            let admittedSongIds = try appState.databaseManager.loadLibraryMemberIds(type: .song, serverId: serverId)
            let hiddenSongIds = try appState.databaseManager.loadHiddenIds(type: "song", serverId: serverId)
            let albumIsAdmitted = try appState.databaseManager.isInLibrary(id: identity.albumId, type: .album, serverId: serverId)
            songs = fetchedSongs.filter {
                !hiddenSongIds.contains($0.id) &&
                (!albumIsAdmitted || admittedSongIds.contains($0.id))
            }
            updateSongsByDisc()
            viewState = .populated
        } catch {
            guard ownsSongsLoad(generation, identity: identity) else { return }
            viewState = .error((error as? ResonanceError) ?? .unknown(error))
        }
    }

    private func loadMoreByArtist(identity: LoadIdentity) async {
        guard !Task.isCancelled, identity == loadIdentity else { return }
        let generation = UUID()
        moreLoadGeneration = generation
        moreByArtist = []
        selectedArtist = nil
        moreByArtistError = nil
        isLoadingMore = false
        guard let serverId = identity.serverId, !identity.artistId.isEmpty else { return }

        isLoadingMore = true
        defer {
            if ownsMoreLoad(generation, identity: identity) { isLoadingMore = false }
        }

        do {
            let artistDetail = try await appState.networkActor.fetchArtist(id: identity.artistId, expectedServerID: UUID(uuidString: serverId))
            guard ownsMoreLoad(generation, identity: identity) else { return }
            selectedArtist = Artist(id: artistDetail.id, name: artistDetail.name,
                                    albumCount: artistDetail.albumCount, coverArt: artistDetail.coverArt,
                                    starred: artistDetail.starred)
            let admittedAlbumIds = try appState.databaseManager.loadLibraryMemberIds(type: .album, serverId: serverId)
            let hiddenAlbumIds = try appState.databaseManager.loadHiddenIds(type: "album", serverId: serverId)
            let albumIsAdmitted = try appState.databaseManager.isInLibrary(id: identity.albumId, type: .album, serverId: serverId)
            moreByArtist = artistDetail.albums.filter {
                !hiddenAlbumIds.contains($0.id) &&
                (!albumIsAdmitted || admittedAlbumIds.contains($0.id))
            }
        } catch {
            guard ownsMoreLoad(generation, identity: identity) else { return }
            moreByArtistError = (error as? ResonanceError) ?? .unknown(error)
        }
    }

    private func admitAlbum() async {
        guard let serverId = appState.activeServerId else { return }

        do {
            let songsToAdmit: [Song]
            if songs.isEmpty {
                let fetchedSongs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
                songsToAdmit = fetchedSongs
                songs = fetchedSongs.filter { !appState.hiddenSongIds.contains($0.id) }
                updateSongsByDisc()
            } else {
                songsToAdmit = songs
            }

            try appState.databaseManager.saveAlbums([album], serverId: serverId)
            try appState.databaseManager.saveSongs(songsToAdmit, serverId: serverId)
            try appState.databaseManager.admitToLibrary(
                id: album.id,
                type: .album,
                serverId: serverId,
                admittedBy: .manual,
                sourceDetail: "album_detail"
            )
            if !album.artistId.isEmpty {
                try appState.databaseManager.admitToLibrary(
                    id: album.artistId,
                    type: .artist,
                    serverId: serverId,
                    admittedBy: .manual,
                    sourceDetail: "album_detail"
                )
            }
            for song in songsToAdmit {
                try appState.databaseManager.admitSongAndRelated(
                    song,
                    serverId: serverId,
                    admittedBy: .manual,
                    sourceDetail: "album_detail"
                )
                try appState.databaseManager.upsertWaitingRoomItem(
                    song: song,
                    serverId: serverId,
                    state: .admitted,
                    source: "album_detail_admit"
                )
                try appState.databaseManager.setWaitingRoomState(
                    songId: song.id,
                    serverId: serverId,
                    state: .admitted
                )
            }
            appState.refreshLibraryMembershipIds()
            viewState = .populated
        } catch {
            print("Failed to admit album: \(error)")
        }
    }

    private func playAlbum(_ candidate: Album, shuffled: Bool = false) async {
        do {
            var albumSongs = try await loadPlayableAlbumSongs(candidate)
            if shuffled {
                albumSongs.shuffle()
            }
            if !albumSongs.isEmpty {
                await appState.playbackManager.play(songs: albumSongs)
            }
        } catch {
            print("Failed to play album: \(error)")
        }
    }

    private func addAlbumToQueue(_ candidate: Album) async {
        do {
            let albumSongs = try await loadPlayableAlbumSongs(candidate)
            for song in albumSongs {
                appState.playbackManager.addToQueue(song)
            }
        } catch {
            print("Failed to add album to queue: \(error)")
        }
    }

    private func loadPlayableAlbumSongs(_ candidate: Album) async throws -> [Song] {
        let candidateIsAdmitted = loadIsInLibrary(
            id: candidate.id,
            type: .album,
            fallback: appState.admittedAlbumIds.contains(candidate.id)
        )
        let admittedSongIds = loadLibraryMemberIds(type: .song, fallback: appState.admittedSongIds)
        let hiddenSongIds = loadHiddenIds(type: "song", fallback: appState.hiddenSongIds)
        let fetchedSongs = try await appState.networkActor.fetchAlbumSongs(albumId: candidate.id)
        return fetchedSongs.filter {
            !hiddenSongIds.contains($0.id) &&
            (!candidateIsAdmitted || admittedSongIds.contains($0.id))
        }
    }

    private func loadLibraryMemberIds(type: LibraryItemType, fallback: Set<String>) -> Set<String> {
        guard let serverId = appState.activeServerId else {
            return fallback
        }
        return (try? appState.databaseManager.loadLibraryMemberIds(type: type, serverId: serverId)) ?? fallback
    }

    private func loadHiddenIds(type: String, fallback: Set<String>) -> Set<String> {
        guard let serverId = appState.activeServerId else {
            return fallback
        }
        return (try? appState.databaseManager.loadHiddenIds(type: type, serverId: serverId)) ?? fallback
    }

    private func loadIsInLibrary(id: String, type: LibraryItemType, fallback: Bool) -> Bool {
        guard let serverId = appState.activeServerId else {
            return fallback
        }
        return (try? appState.databaseManager.isInLibrary(id: id, type: type, serverId: serverId)) ?? fallback
    }

    private func toggleAlbumStar() async {
        do {
            if isStarred {
                try await appState.networkActor.unstar(id: album.id, type: .album)
                appState.updateAlbumStarred(id: album.id, starred: nil)
                presentationState.absorbAcknowledged(appState.albumPresentationStore)
            } else {
                let now = Date()
                try await appState.networkActor.star(id: album.id, type: .album)
                appState.updateAlbumStarred(id: album.id, starred: now)
                presentationState.absorbAcknowledged(appState.albumPresentationStore)
            }
        } catch {
            // API call failed, don't update local state
        }
    }

    private func setRating(_ rating: Int) {
        let newRating = rating == 0 ? nil : rating

        // Optimistic update
        let actionRevision = appState.updateAlbumRating(id: album.id, rating: newRating)

        Task {
            do {
                try await appState.networkActor.setRating(id: album.id, rating: rating)
                appState.confirmAlbumRating(id: album.id, actionRevision: actionRevision)
                presentationState.absorbAcknowledged(appState.albumPresentationStore)
            } catch {
                appState.rejectAlbumRating(id: album.id, actionRevision: actionRevision)
                presentationState.absorbAcknowledged(appState.albumPresentationStore)
            }
        }
    }

    private func navigateToArtist() {
        guard !displayedAlbum.artistId.isEmpty else { return }
        // Use the artist returned with this shelf instead of a sidebar deep
        // link, which used to silently fail when that artist was not cached.
        if let artist = selectedArtist ?? appState.artists.first(where: { $0.id == displayedAlbum.artistId }) {
            appState.detailNavigationPath.append(artist)
            return
        }
        artistNavigationTask?.cancel()
        let identity = loadIdentity
        let origin = appState.detailNavigationPath
        artistNavigationTask = Task { @MainActor in
            do {
                let detail = try await appState.networkActor.fetchArtist(id: identity.artistId,
                    expectedServerID: identity.serverId.flatMap(UUID.init(uuidString:)))
                guard !Task.isCancelled, identity == loadIdentity,
                      appState.detailNavigationPath == origin else { return }
                appState.detailNavigationPath.append(Artist(id: detail.id, name: detail.name,
                    albumCount: detail.albumCount, coverArt: detail.coverArt, starred: detail.starred))
            } catch {
                guard !Task.isCancelled, identity == loadIdentity else { return }
                appState.feedback = AppFeedback(message: "Couldn’t open artist", detail: error.localizedDescription,
                    style: .error, systemImage: "exclamationmark.triangle", actionTitle: nil, action: nil)
            }
        }
    }
}

/// Footer totals deliberately describe the fetched, policy-visible track list.
/// Album metadata can be stale or aggregate historic rows that the server did
/// not return for this album request.
struct AlbumFooterStats: Equatable {
    let songCount: Int
    let totalDuration: Int

    init(songs: [Song]) {
        songCount = songs.count
        totalDuration = songs.reduce(into: 0) { $0 += $1.duration }
    }

    var formattedDuration: String {
        let hours = totalDuration / 3600
        let minutes = (totalDuration % 3600) / 60
        return hours > 0 ? "\(hours) hr \(minutes) min" : "\(minutes) min"
    }
}

// MARK: - Album Track Row

/// Specialized track row for album detail view
struct AlbumTrackRow: View {
    @Environment(AppState.self) private var appState
    @State private var downloaded = false
    @State private var downloadedURL: URL?
    @State private var downloadedKey: DownloadStatusKey?
    let song: Song
    let albumArtist: String
    var isPlaying: Bool = false
    var isHighlighted: Bool = false
    var isSelected: Bool = false
    var selectedSongs: [Song] = []
    var onSelect: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onFocus: () -> Void = {}
    var onMove: (Int, NSEvent.ModifierFlags) -> Void = { _, _ in }
    var onSelectAll: () -> Void = {}
    var onActivateFocused: () -> Void = {}
    var onDoubleTap: () -> Void

    private struct DownloadStatusKey: Hashable {
        let serverId: UUID?
        let songId: String
        let revision: UInt64
    }

    private var downloadStatusKey: DownloadStatusKey {
        let serverId = appState.activeServerId.flatMap(UUID.init(uuidString:))
        return DownloadStatusKey(serverId: serverId, songId: song.id,
                                 revision: serverId.map { appState.cacheActor.downloadProgress.manifestRevisions[$0, default: 0] } ?? 0)
    }

    private var hasDownloadedAudio: Bool {
        downloadedKey == downloadStatusKey && downloaded
    }

    var body: some View {
        HStack(spacing: 0) {
            AlbumTrackRowSelectionControl(
                song: song,
                albumArtist: albumArtist,
                isPlaying: isPlaying,
                isHighlighted: isHighlighted,
                isSelected: isSelected,
                isDownloaded: hasDownloadedAudio,
                onSelect: onSelect,
                onFocus: onFocus,
                onMove: onMove,
                onSelectAll: onSelectAll,
                onActivateFocused: onActivateFocused,
                onDoubleTap: onDoubleTap
            )

            Menu {
                if isSelected, selectedSongs.count > 1 {
                    BulkSongContextMenu(songs: selectedSongs)
                } else {
                    SongContextMenu(song: song, downloadState: downloadedKey == downloadStatusKey
                                    ? downloadedURL.map { .downloaded($0) } ?? .absent : nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("More for \(song.title)")
            .help("More")
            .padding(.leading, 9)
            .frame(width: 84, height: 46, alignment: .leading)
            .contentShape(Rectangle())
        }
        // Native trackTable AXRow height46 at both1000/1500 window widths.
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted || isSelected ? Color.accentColor.opacity(0.1) : .clear)
        )
        .task(id: downloadStatusKey) {
            let key = downloadStatusKey
            guard let serverId = key.serverId else {
                downloaded = false
                downloadedURL = nil
                downloadedKey = key
                return
            }
            let path = await appState.cacheActor.getDownloadedAudioPath(for: key.songId, serverId: serverId)
            guard !Task.isCancelled, key == downloadStatusKey else { return }
            downloaded = path != nil
            downloadedURL = path
            downloadedKey = key
        }
    }

    private var accessibilityLabel: String {
        var label = "Track \(song.track ?? 0): \(song.title)"
        if isPlaying {
            label = "Now playing: " + label
        }
        label += ", \(song.formattedDuration)"
        if song.starred != nil {
            label += ", loved"
        }
        if song.isExplicit {
            label += ", explicit"
        }
        return label
    }
}

/// The focus and keyboard-modifier chain is isolated from the download menu so
/// SwiftUI does not have to infer one deeply nested button/menu expression.
private struct AlbumTrackRowSelectionControl: View {
    @FocusState private var isFocused: Bool
    let song: Song
    let albumArtist: String
    let isPlaying: Bool
    let isHighlighted: Bool
    let isSelected: Bool
    let isDownloaded: Bool
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onFocus: () -> Void
    let onMove: (Int, NSEvent.ModifierFlags) -> Void
    let onSelectAll: () -> Void
    let onActivateFocused: () -> Void
    let onDoubleTap: () -> Void

    var body: some View {
        Button(action: selectCurrentTrack) {
            AlbumTrackRowContent(
                song: song,
                albumArtist: albumArtist,
                isPlaying: isPlaying,
                isHighlighted: isHighlighted,
                isDownloaded: isDownloaded
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onTapGesture(count: 2, perform: onDoubleTap)
        .onKeyPress(.return) { activateFocusedTrack() }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in moveFocus(press) }
        .onKeyPress("a", phases: .down) { press in selectAllIfCommand(press) }
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("AlbumDetail.Track.\(song.id)")
        .accessibilityHint(isSelected ? "Selected. Press Return or double click to play." : "Select track. Press Return or double click to play.")
        .accessibilityAddTraits(isPlaying || isSelected ? [.isSelected] : [])
        .accessibilityAction { onSelect([]) }
        .accessibilityAction(named: "Play") { onDoubleTap() }
    }

    private func selectCurrentTrack() {
        onSelect(NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
    }

    private func activateFocusedTrack() -> KeyPress.Result {
        onActivateFocused()
        return .handled
    }

    private func moveFocus(_ press: KeyPress) -> KeyPress.Result {
        onMove(press.key == .upArrow ? -1 : 1,
               press.modifiers.contains(.shift) ? .shift : [])
        return .handled
    }

    private func selectAllIfCommand(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers == .command else { return .ignored }
        onSelectAll()
        return .handled
    }

    private var accessibilityLabel: String {
        var label = "Track \(song.track ?? 0): \(song.title)"
        if isPlaying { label = "Now playing: " + label }
        label += ", \(song.formattedDuration)"
        if song.starred != nil { label += ", loved" }
        if song.isExplicit { label += ", explicit" }
        return label
    }
}

private struct AlbumTrackRowContent: View {
    let song: Song
    let albumArtist: String
    let isPlaying: Bool
    let isHighlighted: Bool
    let isDownloaded: Bool

    var body: some View {
        HStack(spacing: 0) {
            Group { if song.starred != nil { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Color.accentColor) } else { Color.clear } }
                .frame(width: 40)
            trackIndicator.frame(width: 40)
            songInfo.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 3)
            RatingIndicator(rating: song.rating)
            Group { if isDownloaded { Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor) } else { Color.clear } }
                .frame(width: 16)
            Text(song.formattedDuration).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit().frame(width: 45)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
    }

    @ViewBuilder private var trackIndicator: some View {
        if isPlaying { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor).symbolEffect(.variableColor.iterative, isActive: true) }
        else { Text(String(song.track ?? 0)).foregroundStyle(.secondary) }
    }

    private var songInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(song.title).font(.body).fontWeight(isPlaying || isHighlighted ? .semibold : .regular)
                    .foregroundStyle(isPlaying || isHighlighted ? Color.accentColor : .primary).lineLimit(1)
                if song.isExplicit { Text("E").font(.caption2).fontWeight(.bold).padding(.horizontal, 4).background(.quaternary).cornerRadius(2) }
            }
            if song.artist != albumArtist { Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

struct AlbumHeaderView: View {
    let album: Album
    let songs: [Song]
    let isStarred: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onToggleStar: () -> Void
    var onArtistTap: (() -> Void)? = nil
    var onGenreTap: ((String) -> Void)? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 31) {
            // Album art with shadow
            ZStack(alignment: .bottomTrailing) {
                EnvironmentAlbumArtView(coverArtId: album.coverArt, size: .large, flexible: true)
                    .frame(width: 270, height: 270)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
            }

            // Info
            VStack(alignment: .leading, spacing: 27) {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(album.name)
                            // Current AMPAlbumHeaderLockup title1Field default.
                            .font(.system(size: 26, weight: .semibold))
                            .lineLimit(2)

                        // Clickable artist name (accent color for better affordance)
                        Button {
                            onArtistTap?()
                        } label: {
                            Text(album.artist)
                                // Current AMPAlbumHeaderLockup title2Field default.
                                .font(.system(size: 26, weight: .regular))
                                .lineLimit(2)
                                .foregroundStyle(onArtistTap != nil ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(onArtistTap == nil)

                    }

                    // Captured native caption: genre, separator, year, then
                    // capability metadata when available. Do not invent Lossless.
                    let captionGenre = album.genre ?? songs.compactMap(\.genre).first
                    HStack(spacing: 4) {
                        if let genre = captionGenre {
                            if let onGenreTap {
                                Button(genre) {
                                    onGenreTap(genre)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text(genre)
                            }
                        }

                        if let year = album.year {
                            if captionGenre != nil {
                                Text("·")
                            }
                            Text(String(year))
                        }
                    }
                    // AMPAlbumHeaderLockup calloutField factory value.
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                // Live native AX: shuffle38, gap10, play132, all38 high.
                // Bordered style adds24 horizontal/8 vertical to these labels.
                // Native material rendering is not yet certified.
                HStack(spacing: 10) {
                    Button(action: onShuffle) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 14, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityLabel("Shuffle")
                    .accessibilityIdentifier("AlbumDetail.Shuffle")
                    .help("Shuffle")
                    .disabled(songs.isEmpty)

                    Button(action: onPlay) {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                            Text("Play")
                        }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 108, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityLabel("Play")
                    .accessibilityIdentifier("AlbumDetail.Play")
                    .tint(.accentColor)
                    .disabled(songs.isEmpty)

                    Spacer()

                    // Retain the server favorite action with Music's star glyph.
                    Button(action: onToggleStar) {
                        Image(systemName: isStarred ? "star.fill" : "star")
                            .font(.system(size: 15))
                            .foregroundStyle(isStarred ? Color.accentColor : .secondary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isStarred ? "Remove album from Favorites" : "Add album to Favorites")
                    .accessibilityIdentifier("AlbumDetail.Favorite")
                    .help(isStarred ? "Remove from Favorites" : "Add to Favorites")
                }
                .font(.system(size: 15, weight: .semibold))
                .frame(height: 38)
                // Native AX action bounds extend1pt below the artwork bottom.
                .offset(y: 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 270)
        }
        // Current native album-detail AX at widths1000/1500: artwork270,
        // leading40 below toolbar, metadata leading341 (31pt artwork gap).
        // Text metrics and metadata vertical placement remain unverified.
        .padding(.horizontal, 40)
        .padding(.bottom, 20)
    }

    private var formattedDuration: String {
        let totalSeconds = album.duration
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }
}

#Preview {
    NavigationStack {
        AlbumDetailView(album: .placeholder)
            .environment(AppState())
    }
}
