import SwiftUI

// MARK: - Layout Options

enum ArtistLayoutStyle: String, CaseIterable {
    case browser = "Browser"
    case list = "List"
    case grid = "Grid"
    case compact = "Compact"

    var icon: String {
        switch self {
        case .browser: return "sidebar.left"
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        case .compact: return "rectangle.grid.1x2"
        }
    }
}

struct ArtistsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewState: ViewState = .loading
    @State private var searchText = ""
    @State private var loadGeneration = UUID()
    @AppStorage("artistLayoutStyle") private var layoutStyle: ArtistLayoutStyle = .browser
    @AppStorage("minArtistAlbumCount") private var minArtistAlbumCount = 1

    enum ViewState {
        case loading
        case empty
        case error(ResonanceError)
        case populated
    }

    private var filteredArtists: [Artist] {
        var result = appState.artists
        if minArtistAlbumCount > 1 {
            result = result.filter { $0.albumCount >= minArtistAlbumCount }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return result
    }

    private var groupedArtists: [(String, [Artist])] {
        let grouped = Dictionary(grouping: filteredArtists) { artist in
            let firstChar = artist.name.prefix(1).uppercased()
            return firstChar.first?.isLetter == true ? firstChar : "#"
        }
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Content
            Group {
                switch viewState {
                case .loading:
                    InlineLoadingStatusView(title: "Loading artists...")
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                case .empty:
                    CompactStatusView(
                        title: "No Artists",
                        systemImage: "music.mic",
                        message: "Artists from your library will appear here."
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
                        Task { await loadArtists() }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .populated:
                    if filteredArtists.isEmpty {
                        Group {
                            if searchText.isEmpty {
                                CompactStatusView(
                                    title: "No Artists",
                                    systemImage: "music.mic",
                                    message: "Artists from your library will appear here."
                                )
                            } else {
                                CompactStatusView(
                                    title: "No Results",
                                    systemImage: "magnifyingglass",
                                    message: "No artists match \"\(searchText)\"."
                                )
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        switch layoutStyle {
                        case .browser:
                            ArtistBrowserView(artists: filteredArtists)
                        case .list:
                            ArtistListView(groupedArtists: groupedArtists)
                        case .grid:
                            ArtistGridView(artists: filteredArtists)
                        case .compact:
                            ArtistCompactView(groupedArtists: groupedArtists)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Artists")
        .searchable(text: $searchText, prompt: "Find in Artists")
        .toolbar {
            // Native Aug22 Artists puts its title and Find above the rail,
            // not in an additional large in-content header. Exact title/search
            // metrics are not exposed by that capture's hierarchy.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { Text("Artists") }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { Text("Artists") }
            }
            ToolbarItem(placement: .principal) { Spacer() }
            ToolbarItem(placement: .primaryAction) {
                // Preserve Resonance's saved layouts without presenting them
                // as a reconstruction of Music's captured filter control.
                Menu {
                    Picker("Layout", selection: $layoutStyle) {
                        ForEach(ArtistLayoutStyle.allCases, id: \.self) { style in
                            Label(style.rawValue, systemImage: style.icon)
                                .tag(style)
                        }
                    }
                } label: {
                    Label("Layout", systemImage: layoutStyle.icon)
                }
                .help("Change artist layout")
                .accessibilityIdentifier("Artists.Layout")
                .accessibilityLabel("Artist layout")
                .accessibilityValue(layoutStyle.rawValue)
            }
        }
        .task(id: appState.activeServerId) {
            await loadArtists()
        }
        .onDisappear {
            loadGeneration = UUID()
        }
    }

    private func loadArtists() async {
        let generation = UUID()
        loadGeneration = generation
        guard let serverId = appState.activeServerId,
              let serverUUID = UUID(uuidString: serverId) else {
            appState.artists = []
            viewState = .empty
            return
        }

        // Publish only admitted cached artists from this server, including an
        // empty result; never leave the previous server's collection visible.
        let cached = (try? appState.databaseManager.loadAdmittedArtists(serverId: serverId)) ?? []
        appState.artists = cached
        viewState = cached.isEmpty ? .loading : .populated

        do {
            let artists = try await appState.networkActor.fetchArtists(expectedServerID: serverUUID)
            guard !Task.isCancelled, generation == loadGeneration,
                  appState.activeServerId == serverId else { return }

            try appState.databaseManager.saveArtists(artists, serverId: serverId)
            let admitted = try appState.databaseManager.loadAdmittedArtists(serverId: serverId)
            appState.refreshLibraryMembershipIds()
            appState.artists = admitted
            viewState = admitted.isEmpty ? .empty : .populated
        } catch {
            guard !Task.isCancelled, generation == loadGeneration,
                  appState.activeServerId == serverId else { return }
            if appState.artists.isEmpty {
                viewState = .error((error as? ResonanceError) ?? .networkUnavailable)
            }
        }
    }

}

// MARK: - Captured artist browser structure

private struct ArtistBrowserView: View {
    @Environment(AppState.self) private var appState
    let artists: [Artist]
    @State private var selectedArtistID: String?

    var body: some View {
        // Aug22 Artists: rail width300, adjacent detail starts301. Native
        // resize constraints and selected-detail rendering remain unrecovered.
        HStack(spacing: 0) {
            List(selection: $selectedArtistID) {
                ForEach(artists) { artist in
                    ArtistRow(artist: artist, showsAlbumCount: false)
                        .help("\(artist.name), \(artist.albumCount) albums")
                        .tag(artist.id)
                        .contextMenu {
                            LibraryArtistContextMenu(artist: artist)
                        }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .controlBackgroundColor))
            .frame(width: 300)
            .accessibilityLabel("Artists")

            Divider()
                .frame(width: 1)

            Group {
                if let selectedArtistID,
                   let artist = artists.first(where: { $0.id == selectedArtistID }) {
                    ArtistDetailView(artist: artist)
                        .id(artist.id)
                } else {
                    Text("Select an Artist")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: appState.activeServerId) { _, _ in
            selectedArtistID = nil
        }
    }
}

// MARK: - List Layout (original)

struct ArtistListView: View {
    let groupedArtists: [(String, [Artist])]

    var body: some View {
        List {
            ForEach(groupedArtists, id: \.0) { section, artists in
                Section(section) {
                    ForEach(artists) { artist in
                        NavigationLink(value: artist) {
                            ArtistRow(artist: artist)
                        }
                        .contextMenu {
                            LibraryArtistContextMenu(artist: artist)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 240, maxHeight: .infinity)
    }
}

// MARK: - Grid Layout (circular photos)

struct ArtistGridView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let artists: [Artist]

    @State private var selectedArtistId: String?
    @State private var viewportWidth: CGFloat = 0
    @FocusState private var isGridFocused: Bool

    private let cardPitch: CGFloat = 156 // 140pt card + 16pt spacing
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 140), spacing: 16)
    ]

    // Base vertical movement on the live viewport so narrow windows and an open
    // inspector do not skip or undershoot rows.
    private var estimatedColumnsPerRow: Int {
        let availableWidth = max(0, viewportWidth - 48)
        return max(1, Int((availableWidth + 16) / cardPitch))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(artists) { artist in
                        NavigationLink(value: artist) {
                            ArtistGridCard(artist: artist, isSelected: selectedArtistId == artist.id)
                        }
                        .buttonStyle(.plain)
                        .id(artist.id)
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded { selectedArtistId = artist.id }
                        )
                        .contextMenu {
                            LibraryArtistContextMenu(artist: artist)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { viewportWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in
                            viewportWidth = width
                        }
                }
            }
            .focusable()
            .focused($isGridFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                handleArrowKey(press.key, proxy: proxy)
            }
            .onKeyPress(keys: [.return, .space]) { press in
                openSelectedArtist()
            }
        }
        .onAppear {
            isGridFocused = true
        }
        .onChange(of: artists.map(\.id), initial: true) { _, visibleIDs in
            if let selectedArtistId, !visibleIDs.contains(selectedArtistId) {
                self.selectedArtistId = nil
            }
        }
    }

    private func handleArrowKey(_ key: KeyEquivalent, proxy: ScrollViewProxy) -> KeyPress.Result {
        let navigator = GridNavigator(itemCount: artists.count, columnsPerRow: estimatedColumnsPerRow)

        let currentIndex: Int?
        if let selectedArtistId {
            currentIndex = artists.firstIndex(where: { $0.id == selectedArtistId })
        } else {
            currentIndex = nil
        }

        if let newIndex = navigator.navigate(from: currentIndex, direction: key),
           newIndex >= 0, newIndex < artists.count {
            let newId = artists[newIndex].id
            selectedArtistId = newId
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                proxy.scrollTo(newId, anchor: .center)
            }
            return .handled
        }
        return .ignored
    }

    /// Opens the selected artist through the shared detail path so keyboard
    /// activation matches clicking a card.
    private func openSelectedArtist() -> KeyPress.Result {
        guard let artist = selectedArtistId.flatMap({ id in artists.first(where: { $0.id == id }) })
                ?? artists.first else { return .ignored }
        selectedArtistId = artist.id
        appState.detailNavigationPath.append(artist)
        return .handled
    }
}

struct ArtistGridCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let artist: Artist
    var isSelected: Bool = false
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 8) {
            // Circular artist image
            ArtistImageView(artistId: artist.id, coverArt: artist.coverArt)
                .frame(width: 120, height: 120)
                .overlay {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                }
                .shadow(color: .black.opacity(isHovered ? 0.2 : 0.1), radius: isHovered ? 8 : 4)
                .scaleEffect(isHovered && !reduceMotion ? 1.03 : 1.0)

            // Name
            Text(artist.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)

            // Album count
            Text("\(artist.albumCount) albums")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(artist.name), \(artist.albumCount) albums")
    }
}

// MARK: - Compact Multi-Column Layout

struct ArtistCompactView: View {
    let groupedArtists: [(String, [Artist])]

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(groupedArtists, id: \.0) { section, artists in
                    // Section header
                    Text(section)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    // Multi-column grid for this section
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(artists) { artist in
                            NavigationLink(value: artist) {
                                CompactArtistRow(artist: artist)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                LibraryArtistContextMenu(artist: artist)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

struct CompactArtistRow: View {
    let artist: Artist
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Small circular image
            ArtistImageView(artistId: artist.id, coverArt: artist.coverArt)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(artist.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text("\(artist.albumCount) alb")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(artist.name), \(artist.albumCount) albums")
    }
}

private struct LibraryArtistContextMenu: View {
    @Environment(AppState.self) private var appState
    let artist: Artist

    var body: some View {
        Button {
            Task {
                await playArtist()
            }
        } label: {
            Label("Play", systemImage: "play")
        }

        Button {
            Task {
                await playArtist(shuffled: true)
            }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            Task {
                await addArtistToQueue()
            }
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }

        Divider()

        Button {
            appState.getInfoContent = .artist(artist)
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }
    }

    private func playArtist(shuffled: Bool = false) async {
        do {
            var songs = try await fetchAdmittedArtistSongs()
            if shuffled {
                songs.shuffle()
            }
            if !songs.isEmpty {
                await appState.playbackManager.play(songs: songs)
            }
        } catch {
            print("Failed to play artist: \(error)")
        }
    }

    private func addArtistToQueue() async {
        do {
            let songs = try await fetchAdmittedArtistSongs()
            for song in songs {
                appState.playbackManager.addToQueue(song)
            }
        } catch {
            print("Failed to add artist to queue: \(error)")
        }
    }

    private func fetchAdmittedArtistSongs() async throws -> [Song] {
        let detail = try await appState.networkActor.fetchArtist(id: artist.id)
        let admittedAlbumIds = loadLibraryMemberIds(type: .album, fallback: appState.admittedAlbumIds)
        let admittedSongIds = loadLibraryMemberIds(type: .song, fallback: appState.admittedSongIds)
        let hiddenSongIds = loadHiddenIds(type: "song", fallback: appState.hiddenSongIds)
        var allSongs: [Song] = []

        for album in detail.albums where admittedAlbumIds.contains(album.id) {
            let songs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
            allSongs.append(contentsOf: songs.filter {
                admittedSongIds.contains($0.id) && !hiddenSongIds.contains($0.id)
            })
        }

        return allSongs
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
}

struct ArtistDetailView: View {
    @Environment(AppState.self) private var appState
    let artist: Artist

    @State private var artistDetail: ArtistDetail?
    @State private var viewState: ViewState = .loading
    @State private var topSongs: [Song] = []
    @State private var isLoadingTopSongs = true
    @State private var isStarred: Bool

    init(artist: Artist) {
        self.artist = artist
        self._isStarred = State(initialValue: artist.starred != nil)
    }

    enum ViewState {
        case loading
        case error(ResonanceError)
        case populated
    }

    private var isArtistAdmitted: Bool {
        appState.admittedArtistIds.contains(artist.id)
    }

    private var albums: [Album] {
        (artistDetail?.albums ?? []).filter {
            !appState.hiddenAlbumIds.contains($0.id) &&
            (!isArtistAdmitted || appState.admittedAlbumIds.contains($0.id))
        }
    }

    /// Latest release (most recent by year)
    private var latestRelease: Album? {
        albums
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            .first
    }

    private var displayName: String {
        artistDetail?.name ?? artist.name
    }

    /// Use artist coverArt, or fallback to first album's cover art
    private var displayCoverArt: String? {
        artistDetail?.coverArt ?? artist.coverArt ?? albums.first?.coverArt
    }

    private var displayAlbumCount: Int {
        isArtistAdmitted ? albums.count : (artistDetail?.albumCount ?? artist.albumCount)
    }

    private var totalSongCount: Int {
        albums.reduce(0) { $0 + $1.songCount }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                ArtistHeaderView(
                    name: displayName,
                    coverArt: displayCoverArt,
                    albumCount: displayAlbumCount,
                    songCount: totalSongCount,
                    onPlay: { Task { await playAll(shuffle: false) } },
                    onShuffle: { Task { await playAll(shuffle: true) } },
                    isDisabled: albums.isEmpty
                )

                if !isArtistAdmitted {
                    ReleaseShadowBanner(
                        title: "Artist Shadow",
                        detail: "\(displayName) is outside Library",
                        actionTitle: "Admit"
                    ) {
                        Task {
                            await admitArtist()
                        }
                    }
                    .padding(.horizontal)
                }

                // Content based on state
                switch viewState {
                case .loading:
                    ArtistDetailLoadingView()

                case .error(let error):
                    CompactStatusView(
                        title: error.errorTitle,
                        systemImage: error.systemImage,
                        message: error.errorDescription,
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise"
                    ) {
                        Task { await loadArtistDetail() }
                    }
                    .padding(.horizontal, 24)

                case .populated:
                    if albums.isEmpty {
                        CompactStatusView(
                            title: "No Albums",
                            systemImage: "square.stack",
                            message: "No albums found for this artist."
                        )
                        .padding(.horizontal, 24)
                    } else {
                        VStack(alignment: .leading, spacing: 32) {
                            // Latest Release
                            if albums.count > 1, let latest = latestRelease {
                                LatestReleaseSection(
                                    album: latest,
                                    onPlay: {
                                        await playAlbum(latest)
                                    },
                                    onShuffle: {
                                        await playAlbum(latest, shuffled: true)
                                    },
                                    onAddToQueue: {
                                        await addAlbumToQueue(latest)
                                    }
                                )
                            }

                            // Top Songs
                            if !topSongs.isEmpty {
                                TopSongsSection(
                                    songs: topSongs,
                                    isLoading: isLoadingTopSongs,
                                    allAlbumSongs: { try await fetchAllSongs() }
                                )
                            } else if isLoadingTopSongs {
                                TopSongsSection(
                                    songs: [],
                                    isLoading: true,
                                    allAlbumSongs: { try await fetchAllSongs() }
                                )
                            }

                            ArtistAlbumsSection(
                                title: "Releases",
                                albums: albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) },
                                onPlayAlbum: playAlbum,
                                onAddAlbumToQueue: addAlbumToQueue
                            )
                        }
                        .padding(.horizontal, 28)
                    }
                }
            }
            .padding(.bottom, 100)
        }
        .navigationTitle(displayName)
        .toolbar {
            // .primaryAction keeps these trailing; without an explicit placement
            // .automatic drops them next to the back chevron, where they read as
            // a second transport cluster competing with the floating bar.
            // Play/Shuffle live in ArtistHeaderView, so they are not repeated here.
            ToolbarItemGroup(placement: .primaryAction) {
                if !isArtistAdmitted {
                    Button {
                        Task {
                            await admitArtist()
                        }
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .help("Admit Artist")
                }

                Menu {
                    Button {
                        Task { await addToQueue() }
                    } label: {
                        Label("Add to Queue", systemImage: "text.badge.plus")
                    }

                    Button {
                        Task { await playNext() }
                    } label: {
                        Label("Play Next", systemImage: "text.insert")
                    }

                    Divider()

                    Button {
                        Task { await toggleArtistStar() }
                    } label: {
                        Label(
                            isStarred ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: isStarred ? "heart.fill" : "heart"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await loadArtistDetail()
        }
    }

    private func loadArtistDetail() async {
        viewState = .loading
        isLoadingTopSongs = true

        do {
            let detail = try await appState.networkActor.fetchArtist(id: artist.id)
            await MainActor.run {
                artistDetail = detail
                viewState = .populated
            }

            // Load top songs after we have albums
            await loadTopSongs()
        } catch let error as ResonanceError {
            viewState = .error(error)
        } catch {
            viewState = .error(.networkUnavailable)
        }
    }

    private func loadTopSongs() async {
        isLoadingTopSongs = true
        do {
            let allSongs = try await fetchAllSongs()
            // Take first 5 unique songs as "top songs"
            // Could be enhanced with play count data if available
            let uniqueSongs = Array(allSongs.prefix(5))
            await MainActor.run {
                topSongs = uniqueSongs
                isLoadingTopSongs = false
            }
        } catch {
            await MainActor.run {
                isLoadingTopSongs = false
            }
        }
    }

    private func fetchAllSongs() async throws -> [Song] {
        var allSongs: [Song] = []
        for album in albums {
            let songs = try await loadPlayableAlbumSongs(album)
            allSongs.append(contentsOf: songs)
        }
        return allSongs
    }

    private func playAlbum(_ album: Album, shuffled: Bool = false) async {
        do {
            var songs = try await loadPlayableAlbumSongs(album)
            if shuffled {
                songs.shuffle()
            }
            if !songs.isEmpty {
                await appState.playbackManager.play(songs: songs)
            }
        } catch {
            // Error handled silently
        }
    }

    private func addAlbumToQueue(_ album: Album) async {
        do {
            let songs = try await loadPlayableAlbumSongs(album)
            for song in songs {
                appState.playbackManager.addToQueue(song)
            }
        } catch {
            // Error handled silently
        }
    }

    private func loadPlayableAlbumSongs(_ album: Album) async throws -> [Song] {
        let hiddenSongIds = loadHiddenIds(type: "song", fallback: appState.hiddenSongIds)
        let admittedSongIds = loadLibraryMemberIds(type: .song, fallback: appState.admittedSongIds)
        let albumSongs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
        return albumSongs.filter {
            !hiddenSongIds.contains($0.id) &&
            (!isArtistAdmitted || admittedSongIds.contains($0.id))
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

    private func admitArtist() async {
        guard let serverId = appState.activeServerId else { return }

        do {
            try appState.databaseManager.saveArtists([artist], serverId: serverId)
            try appState.databaseManager.admitToLibrary(
                id: artist.id,
                type: .artist,
                serverId: serverId,
                admittedBy: .manual,
                sourceDetail: "artist_detail"
            )

            for album in artistDetail?.albums ?? [] {
                try appState.databaseManager.admitToLibrary(
                    id: album.id,
                    type: .album,
                    serverId: serverId,
                    admittedBy: .manual,
                    sourceDetail: "artist_detail"
                )
                let albumSongs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
                try appState.databaseManager.saveSongs(albumSongs, serverId: serverId)
                for song in albumSongs {
                    try appState.databaseManager.admitSongAndRelated(
                        song,
                        serverId: serverId,
                        admittedBy: .manual,
                        sourceDetail: "artist_detail"
                    )
                    try appState.databaseManager.upsertWaitingRoomItem(
                        song: song,
                        serverId: serverId,
                        state: .admitted,
                        source: "artist_detail_admit"
                    )
                    try appState.databaseManager.setWaitingRoomState(
                        songId: song.id,
                        serverId: serverId,
                        state: .admitted
                    )
                }
            }
            appState.refreshLibraryMembershipIds()
            await loadArtistDetail()
        } catch {
            print("Failed to admit artist: \(error)")
        }
    }

    private func playAll(shuffle: Bool) async {
        do {
            var songs = try await fetchAllSongs()
            if shuffle {
                songs.shuffle()
            }
            await appState.playbackManager.play(songs: songs)
        } catch {
            // Error handled silently - could add error toast later
        }
    }

    private func addToQueue() async {
        do {
            let songs = try await fetchAllSongs()
            for song in songs {
                appState.playbackManager.addToQueue(song)
            }
        } catch {
            // Error handled silently
        }
    }

    private func playNext() async {
        do {
            let songs = try await fetchAllSongs()
            for song in songs.reversed() {
                appState.playbackManager.playNext(song)
            }
        } catch {
            // Error handled silently
        }
    }

    private func toggleArtistStar() async {
        do {
            if isStarred {
                try await appState.networkActor.unstar(id: artist.id, type: .artist)
                isStarred = false
            } else {
                try await appState.networkActor.star(id: artist.id, type: .artist)
                isStarred = true
            }
        } catch {
            // Error handled silently
        }
    }
}

// MARK: - Artist Header View

struct ArtistHeaderView: View {
    let name: String
    let coverArt: String?
    let albumCount: Int
    let songCount: Int
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let isDisabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            // Artist image (circular, using album art as fallback)
            EnvironmentAlbumArtView(coverArtId: coverArt, size: .large)
                .frame(width: 144, height: 144)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("ARTIST")
                    .font(.caption.weight(.medium))
                    .tracking(1)
                    .foregroundStyle(.secondary)

                Text(name)
                    .font(.largeTitle)
                    .fontWeight(.bold)

                HStack(spacing: 8) {
                    Text("\(albumCount) \(albumCount == 1 ? "release" : "releases")")
                    Text("·")
                    Text("\(songCount) \(songCount == 1 ? "song" : "songs") in your library")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button(action: onPlay) {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDisabled)

                    Button(action: onShuffle) {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDisabled)
                }
                .padding(.top, 12)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 28)
    }
}

// MARK: - Latest Release Section

struct LatestReleaseSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let album: Album
    let onPlay: () async -> Void
    let onShuffle: () async -> Void
    let onAddToQueue: () async -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Latest Release")
                .font(.title2)
                .fontWeight(.semibold)

            HStack(spacing: 20) {
                NavigationLink(value: album) {
                    EnvironmentAlbumArtView(coverArtId: album.coverArt, size: .large)
                        .frame(width: 112, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(isHovered ? 0.15 : 0.08), radius: isHovered ? 12 : 8)
                        .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1.0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)

                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 8) {
                    Text(album.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        if let year = album.year {
                            Text(String(year))
                        }
                        if album.songCount > 0 {
                            Text("·")
                            Text("\(album.songCount) \(album.songCount == 1 ? "song" : "songs")")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button {
                            Task { await onPlay() }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        NavigationLink("View Album", value: album)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                Spacer()
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .contextMenu {
                Button {
                    Task {
                        await onPlay()
                    }
                } label: {
                    Label("Play", systemImage: "play")
                }

                Button {
                    Task {
                        await onShuffle()
                    }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }

                Button {
                    Task {
                        await onAddToQueue()
                    }
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }
            }
        }
    }
}

// MARK: - Top Songs Section

struct TopSongsSection: View {
    @Environment(AppState.self) private var appState
    let songs: [Song]
    let isLoading: Bool
    let allAlbumSongs: () async throws -> [Song]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top Songs")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if !songs.isEmpty {
                    Button {
                        Task { await playAllTopSongs() }
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            VStack(spacing: 0) {
                if isLoading {
                    ForEach(0..<5, id: \.self) { _ in
                        SongRow(song: .placeholder, showTrackNumber: false)
                            .redacted(reason: .placeholder)
                        Divider()
                            .padding(.leading, 52)
                    }
                } else {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        TopSongRow(song: song, index: index + 1)
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
                                .padding(.leading, 52)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .overlay(alignment: .top) { Divider() }
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func playAllTopSongs() async {
        await appState.playbackManager.play(songs: songs)
    }
}

struct TopSongRow: View {
    let song: Song
    let index: Int
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 24, alignment: .trailing)

            EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .small)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .lineLimit(1)

                Text(song.album)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(song.formattedDuration)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Top song \(index): \(song.title) by \(song.artist) from \(song.album), \(song.formattedDuration)")
    }
}

// MARK: - Artist Albums Section

struct ArtistAlbumsSection: View {
    let title: String
    let albums: [Album]
    let onPlayAlbum: (Album, Bool) async -> Void
    let onAddAlbumToQueue: (Album) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 20) {
                ForEach(albums) { album in
                    AlbumCardActionSurface(
                        album: album,
                        onPlay: { Task { await onPlayAlbum(album, false) } }
                    ) { artworkHoverChanged in
                        NavigationLink(value: album) {
                            AlbumCard(
                                album: album,
                                showsHoverPlayButton: false,
                                onArtworkHoverChange: artworkHoverChanged
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .contextMenu {
                        Button {
                            Task {
                                await onPlayAlbum(album, false)
                            }
                        } label: {
                            Label("Play", systemImage: "play")
                        }

                        Button {
                            Task {
                                await onPlayAlbum(album, true)
                            }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }

                        Button {
                            Task {
                                await onAddAlbumToQueue(album)
                            }
                        } label: {
                            Label("Add to Queue", systemImage: "text.badge.plus")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Loading View

struct ArtistDetailLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            // Latest Release placeholder - use redacted modifier for shimmer effect
            VStack(alignment: .leading, spacing: 12) {
                Text("Latest Release")
                    .font(.title2)
                    .fontWeight(.semibold)

                HStack(spacing: 16) {
                    EnvironmentAlbumArtView(coverArtId: nil, size: .medium)
                        .frame(width: 160, height: 160)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Album Title Here")
                            .font(.headline)

                        Text("2024")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()
                    }
                    Spacer()
                }
                .padding()
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial)
                }
                .redacted(reason: .placeholder)
            }

            // Albums placeholder
            VStack(alignment: .leading, spacing: 12) {
                Text("Albums")
                    .font(.title2)
                    .fontWeight(.semibold)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 20) {
                    ForEach(0..<6, id: \.self) { _ in
                        AlbumCard(album: .placeholder)
                            .redacted(reason: .placeholder)
                    }
                }
            }
        }
        .padding(.horizontal)
    }
}

#Preview {
    NavigationStack {
        ArtistsView()
            .environment(AppState())
    }
}
