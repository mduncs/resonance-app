import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var topPicks: [Album] = []
    @State private var recentlyAdded: [Album] = []
    @State private var recentlyPlayed: [Album] = []
    @State private var randomAlbums: [Album] = []
    @State private var isLoading = true
    @State private var selectedAlbum: Album?
    @State private var loadError: Error?
    @AppStorage("minAlbumSongCount") private var minAlbumSongCount = 1

    private func applyFilters(_ albums: [Album]) -> [Album] {
        albums.filter {
            !appState.hiddenAlbumIds.contains($0.id)
            && $0.songCount >= minAlbumSongCount
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Large "Home" title like Apple Music
                Text("Home")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.top, 8)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let error = loadError, topPicks.isEmpty && recentlyAdded.isEmpty && recentlyPlayed.isEmpty && randomAlbums.isEmpty {
                    // Show error only when ALL sections failed to load
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Failed to Load")
                            .font(.headline)
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task {
                                await loadData()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    // Top Picks with category labels
                    if !topPicks.isEmpty {
                        HeroSection(
                            albums: topPicks,
                            selectedAlbum: $selectedAlbum
                        )
                    }

                    // Recently Played first (like Apple Music)
                    if !recentlyPlayed.isEmpty {
                        HomeSection(
                            title: "Recently Played",
                            subtitle: nil,
                            sidebarDestination: .recentlyPlayed,
                            albums: recentlyPlayed,
                            selectedAlbum: $selectedAlbum
                        )
                    }

                    // Recently Added
                    if !recentlyAdded.isEmpty {
                        HomeSection(
                            title: "Recently Added",
                            subtitle: nil,
                            sidebarDestination: .recentlyAdded,
                            albums: recentlyAdded,
                            selectedAlbum: $selectedAlbum
                        )
                    }

                    // Random Albums
                    if !randomAlbums.isEmpty {
                        HomeSection(
                            title: "For You",
                            subtitle: nil,
                            sidebarDestination: nil,
                            albums: randomAlbums,
                            selectedAlbum: $selectedAlbum,
                            onRefresh: refreshRandomAlbums
                        )
                    }
                }
            }
            .padding()
        }
        .navigationTitle("")
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
        }
        .task {
            await loadData()
        }
        .onChange(of: appState.activeServerId) { _, _ in
            Task {
                await loadData()
            }
        }
        .onChange(of: appState.connectionStatus) { _, status in
            guard status == .connected else { return }
            Task {
                await loadData()
            }
        }
    }

    private func loadData() async {
        isLoading = true
        loadError = nil

        guard appState.activeServer != nil else {
            topPicks = []
            recentlyAdded = []
            recentlyPlayed = []
            randomAlbums = []
            isLoading = false
            return
        }

        async let topPicksTask = loadTopPicks()
        async let recentlyAddedTask = loadRecentlyAdded()
        async let recentlyPlayedTask = loadRecentlyPlayed()
        async let randomTask = loadRandomAlbums()

        (topPicks, recentlyAdded, recentlyPlayed, randomAlbums) = await (
            topPicksTask,
            recentlyAddedTask,
            recentlyPlayedTask,
            randomTask
        )

        isLoading = false
    }

    private func loadTopPicks() async -> [Album] {
        do {
            let fetched = try await appState.networkActor.fetchAlbums(type: .random, size: 15)
            return Array(applyFilters(fetched).prefix(5))
        } catch {
            print("Failed to load top picks: \(error)")
            loadError = error
            return []
        }
    }

    private func loadRecentlyAdded() async -> [Album] {
        do {
            let fetched = try await appState.networkActor.fetchAlbums(type: .newest, size: 30)
            return Array(applyFilters(fetched).prefix(10))
        } catch {
            print("Failed to load recently added: \(error)")
            return []
        }
    }

    private func loadRecentlyPlayed() async -> [Album] {
        let history = (try? appState.databaseManager.loadPlayHistory(
            serverId: appState.activeServerId,
            limit: 100
        )) ?? []

        // Build lookup from cached albums for full metadata
        let cachedById = Dictionary(uniqueKeysWithValues: appState.albums.map { ($0.id, $0) })

        // Get unique album IDs from history, preserving order
        var seenAlbumIds = Set<String>()
        var albums: [Album] = []

        for item in history {
            guard !seenAlbumIds.contains(item.albumId) else { continue }
            seenAlbumIds.insert(item.albumId)

            // Prefer cached album (has full metadata incl. songCount), fall back to history data
            if let cached = cachedById[item.albumId] {
                albums.append(cached)
            } else {
                albums.append(Album(
                    id: item.albumId,
                    name: item.album,
                    artist: item.artist,
                    artistId: "",
                    songCount: 0,
                    duration: 0,
                    year: nil,
                    genre: nil,
                    coverArt: item.coverArt
                ))
            }

            if albums.count >= 20 { break }
        }

        return Array(applyFilters(albums).prefix(10))
    }

    private func loadRandomAlbums() async -> [Album] {
        do {
            let fetched = try await appState.networkActor.fetchAlbums(type: .random, size: 30)
            return Array(applyFilters(fetched).prefix(10))
        } catch {
            print("Failed to load random albums: \(error)")
            return []
        }
    }

    private func refreshRandomAlbums() {
        Task {
            randomAlbums = await loadRandomAlbums()
        }
    }
}

// MARK: - Hero Section

struct HeroSection: View {
    @Environment(AppState.self) private var appState
    let albums: [Album]
    @Binding var selectedAlbum: Album?

    @State private var recentAlbumIds: Set<String> = []

    private func heroLabel(for album: Album) -> String {
        let currentYear = Calendar.current.component(.year, from: Date())
        if album.year == currentYear { return "New Release" }
        if album.starred != nil { return "Favorites" }
        if recentAlbumIds.contains(album.id) { return "Listen Again" }
        return "Made for You"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Picks for You")
                .font(.title2)
                .fontWeight(.bold)

            PagingRow(
                items: Array(albums.prefix(5)),
                itemWidth: 300,
                spacing: 16,
                chevronCenterY: 150,
                itemAlignment: .top,
                contextLabel: "Top Picks for You"
            ) { album in
                VStack(alignment: .leading, spacing: 8) {
                    // Category label above each card
                    Text(heroLabel(for: album))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    HeroCard(album: album)
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
                }
            }
        }
        .task {
            let history = (try? appState.databaseManager.loadPlayHistory(
                serverId: appState.activeServerId,
                limit: 100
            )) ?? []
            var ids = Set<String>()
            for item in history {
                ids.insert(item.albumId)
                if ids.count >= 20 { break }
            }
            recentAlbumIds = ids
        }
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

struct HeroCard: View {
    let album: Album
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            EnvironmentAlbumArtView(coverArtId: album.coverArt, size: .extraLarge)
                .frame(width: 300, height: 300)

            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(height: 120)
            .frame(maxHeight: .infinity, alignment: .bottom)

            VStack(alignment: .leading, spacing: 4) {
                Text(album.name)
                    .font(.headline)
                    .fontWeight(.bold)
                    .lineLimit(2)
                Text(album.artist)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding()
        }
        .frame(width: 300, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .shadow(color: .black.opacity(isHovered ? 0.2 : 0.1), radius: isHovered ? 16 : 10, x: 0, y: isHovered ? 8 : 5)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Top pick: \(album.name) by \(album.artist)")
        .accessibilityHint("Double tap to view album")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Home Section

struct HomeSection: View {
    @Environment(AppState.self) private var appState
    let title: String
    var subtitle: String? = nil
    let sidebarDestination: SidebarItem?
    let albums: [Album]
    @Binding var selectedAlbum: Album?
    var onRefresh: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3)
                        .fontWeight(.bold)

                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let onRefresh {
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh")
                }

                if let destination = sidebarDestination {
                    Button("See All") {
                        appState.selectedSidebarItem = destination
                    }
                    .buttonStyle(.plain)
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                }
            }

            PagingRow(
                items: albums,
                itemWidth: 204,
                spacing: 20,
                chevronCenterY: 100,
                contextLabel: title
            ) { album in
                AlbumCardLarge(album: album)
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
            }
        }
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

#Preview {
    NavigationStack {
        HomeView()
            .environment(AppState())
    }
}
