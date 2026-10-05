import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var topPicks: [Album] = []
    @State private var recentlyAdded: [Album] = []
    @State private var recentlyPlayed: [Album] = []
    @State private var randomAlbums: [Album] = []
    @State private var isLoading = true
    @State private var loadError: Error?
    @AppStorage("minAlbumSongCount") private var minAlbumSongCount = 1

    @State private var loadGeneration = UUID()
    @State private var retryGeneration = UUID()
    @State private var randomGeneration = UUID()
    @State private var randomRefreshTask: Task<Void, Never>?

    private struct LoadKey: Equatable {
        let serverID: UUID?
        let connection: ConnectionStatus
        let minimumSongs: Int
        let hiddenAlbumIDs: Set<String>
        let retry: UUID
    }

    private var loadKey: LoadKey {
        LoadKey(serverID: appState.activeServer?.id,
                connection: appState.connectionStatus,
                minimumSongs: minAlbumSongCount,
                hiddenAlbumIDs: appState.hiddenAlbumIds,
                retry: retryGeneration)
    }

    private func applyFilters(_ albums: [Album], key: LoadKey) -> [Album] {
        albums.filter { !key.hiddenAlbumIDs.contains($0.id) && $0.songCount >= key.minimumSongs }
    }

    private func ownsLoad(_ key: LoadKey, generation: UUID) -> Bool {
        !Task.isCancelled && loadGeneration == generation && loadKey == key
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Native05 heading: 95×40 layout, 90×24 raster ink. Public34-bold
                // reproduces the observed glyph shape/size; descriptor and raster
                // color/antialiasing remain unverified. First section gap is20.
                Text("Home")
                    .font(.system(size: 34, weight: .bold))
                    .frame(height: 40, alignment: .top)
                    .padding(.bottom, -12)


                if appState.activeServer == nil {
                    // Normal no-server mode: never show a spinner or fake error here.
                    CompactStatusView(
                        title: "No Server Connected",
                        systemImage: "externaldrive.connected.to.line.below",
                        message: "Connect to a music server to see your library here."
                    )
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if isLoading {
                    InlineLoadingStatusView(title: "Loading Home...")
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
                            retryGeneration = UUID()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    // Top Picks with category labels
                    if !topPicks.isEmpty {
                        HeroSection(
                            albums: topPicks
                        )
                    }

                    // Recently Played first (like Apple Music)
                    if !recentlyPlayed.isEmpty {
                        HomeSection(
                            title: "Recently Played",
                            subtitle: nil,
                            sidebarDestination: .recentlyPlayed,
                            albums: recentlyPlayed
                        )
                    }

                    // Recently Added
                    if !recentlyAdded.isEmpty {
                        HomeSection(
                            title: "Recently Added",
                            subtitle: nil,
                            sidebarDestination: .recentlyAdded,
                            albums: recentlyAdded
                        )
                    }

                    // Random Albums
                    if !randomAlbums.isEmpty {
                        HomeSection(
                            title: "Explore Your Library",
                            subtitle: nil,
                            sidebarDestination: nil,
                            albums: randomAlbums,
                            onRefresh: refreshRandomAlbums
                        )
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 16)
        }
        .navigationTitle("")
        .task(id: loadKey) {
            await loadData(key: loadKey)
        }
        .onDisappear {
            loadGeneration = UUID()
            randomGeneration = UUID()
            randomRefreshTask?.cancel()
            randomRefreshTask = nil
        }
    }

    private func loadData(key: LoadKey) async {
        let generation = UUID()
        loadGeneration = generation
        randomGeneration = UUID()
        randomRefreshTask?.cancel()
        randomRefreshTask = nil
        isLoading = true
        loadError = nil
        topPicks = []
        recentlyAdded = []
        recentlyPlayed = []
        randomAlbums = []

        guard let serverID = key.serverID else {
            isLoading = false
            return
        }

        // Snapshot local history and its server-scoped metadata before suspension.
        // A database failure is a failed section, never a fabricated empty history.
        let historyResult: Result<[Album], Error> = Result {
            try loadRecentlyPlayed(serverID: serverID, key: key)
        }
        async let picksResult = loadAlbums(type: .random, size: 15, key: key)
        async let addedResult = loadAlbums(type: .newest, size: 30, key: key)
        async let randomResult = loadAlbums(type: .random, size: 30, key: key)
        let results = await (picksResult, addedResult, randomResult)
        guard ownsLoad(key, generation: generation) else { return }

        // Child requests return values only. A superseded request cannot publish
        // either albums, errors, or a loading-state reset into its replacement.
        func albums(_ result: Result<[Album], Error>) -> [Album] {
            switch result {
            case .success(let albums): return albums
            case .failure(let error):
                if loadError == nil { loadError = error }
                return []
            }
        }
        topPicks = albums(results.0)
        recentlyAdded = Array(albums(results.1).prefix(10))
        recentlyPlayed = albums(historyResult)
        randomAlbums = Array(albums(results.2).prefix(10))
        isLoading = false
    }

    private func loadAlbums(type: AlbumListType, size: Int, key: LoadKey) async -> Result<[Album], Error> {
        do {
            try Task.checkCancellation()
            let fetched = try await appState.networkActor.fetchAlbums(
                type: type, size: size, expectedServerID: key.serverID
            )
            try Task.checkCancellation()
            return .success(applyFilters(fetched, key: key))
        } catch {
            return .failure(error)
        }
    }

    private func loadRecentlyPlayed(serverID: UUID, key: LoadKey) throws -> [Album] {
        let history = try appState.databaseManager.loadPlayHistory(
            serverId: serverID.uuidString, limit: 100
        )
        // Resolve only history's referenced albums; Home must not load the
        // complete catalog as a side effect of the startup screen.
        let cachedById = try appState.databaseManager.admittedAlbums(
            ids: history.map(\.albumId), serverID: serverID.uuidString
        )
        var seenAlbumIds = Set<String>()
        var albums: [Album] = []
        for item in history {
            guard seenAlbumIds.insert(item.albumId).inserted else { continue }
            if let cached = cachedById[item.albumId] {
                albums.append(cached)
            } else {
                albums.append(Album(
                    id: item.albumId, name: item.album, artist: item.artist,
                    artistId: "", songCount: 0, duration: 0, year: nil,
                    genre: nil, coverArt: item.coverArt
                ))
            }
            if albums.count >= 20 { break }
        }
        return Array(applyFilters(albums, key: key).prefix(10))
    }

    private func refreshRandomAlbums() {
        randomRefreshTask?.cancel()
        let refresh = UUID()
        randomGeneration = refresh
        let key = loadKey
        let generation = loadGeneration
        guard key.serverID != nil else { return }
        randomRefreshTask = Task {
            let result = await loadAlbums(type: .random, size: 30, key: key)
            guard ownsLoad(key, generation: generation), randomGeneration == refresh else { return }
            switch result {
            case .success(let albums): randomAlbums = Array(albums.prefix(10))
            case .failure(let error):
                // Keep the visible shelf when refresh fails.
                if !(error is CancellationError) { loadError = error }
            }
            randomRefreshTask = nil
        }
    }
}

// MARK: - Hero Section

struct HeroSection: View {
    @Environment(AppState.self) private var appState
    let albums: [Album]

    @State private var recentAlbumIds: Set<String> = []

    private func heroLabel(for album: Album) -> String {
        // Factual, library-derived reasons only. Apple editorial categories
        // ("Made for You", subscription picks) must not be fabricated.
        let currentYear = Calendar.current.component(.year, from: Date())
        if album.year == currentYear { return "New Release" }
        if album.starred != nil { return "Favorite" }
        if recentAlbumIds.contains(album.id) { return "Recently Played" }
        return "From Your Library"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Picks")
                .font(.title2)
                .fontWeight(.bold)

            PagingRow(
                items: albums,
                itemWidth: 255,
                spacing: 20,
                chevronCenterY: 169.5,
                itemAlignment: .top,
                contextLabel: "Top Picks",
                shadowOverflow: 24
            ) { album in
                HeroCard(album: album, categoryLabel: heroLabel(for: album))
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
                                appState.detailNavigationPath.append(album)
                            }
                    )
                    .contextMenu {
                        AlbumContextMenu(album: album)
                    }
                    .accessibilityIdentifier("Home.TopPick.\(album.id)")
                    .accessibilityAction { appState.detailNavigationPath.append(album) }
                    .accessibilityAction(named: "Play") {
                        Task {
                            await playAlbum(album)
                        }
                    }
                    .focusable()
                    .onKeyPress(keys: [.return, .space]) { _ in
                        appState.detailNavigationPath.append(album)
                        return .handled
                    }
            }
        }
        .task(id: appState.activeServerId) {
            recentAlbumIds = []
            guard let serverID = appState.activeServerId else { return }
            let history = (try? appState.databaseManager.loadPlayHistory(
                serverId: serverID,
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
    let categoryLabel: String
    @State private var backing = HeroArtworkBacking.fallback

    // Both album treatments are visible in the saved native Home capture.
    // Editorial motion art is not available from a Subsonic library. Use the
    // full-bleed release treatment only for our truthful New Release category.
    private var isFullBleed: Bool { categoryLabel == "New Release" && album.coverArt != nil }

    var body: some View {
        // Observed card envelope: 255×339, corner 8, one-point 10% black edge.
        // The palette and soft shadow below reconstruct the screenshot treatment;
        // they are not a recovered Apple palette algorithm or shadow filter.
        ZStack(alignment: .topLeading) {
            isFullBleed ? Color.black : backing

            EnvironmentAlbumArtView(
                coverArtId: album.coverArt,
                size: .extraLarge,
                flexible: true,
                onImageLoaded: { backing = HeroArtworkBacking.color(from: $0) }
            )
            .frame(width: isFullBleed ? 255 : 223, height: isFullBleed ? 255 : 222)
            .clipShape(RoundedRectangle(cornerRadius: isFullBleed ? 0 : 8))
            .offset(x: isFullBleed ? 0 : 16, y: isFullBleed ? 0 : 16)

            if isFullBleed {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.65), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 115)
                .offset(y: 224)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(categoryLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(isFullBleed ? 0.65 : 1))
                    .lineLimit(1)

                Text(album.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(album.artist)
                    .font(.system(size: 11))
                    .lineLimit(2)
            }
            .frame(width: 223, height: 307, alignment: .bottomLeading)
            .offset(x: 16, y: 16)
        }
        .foregroundStyle(.white)
        .frame(width: 255, height: 339)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.name) by \(album.artist)")
        .accessibilityHint("Opens the album.")
        .accessibilityAddTraits(.isButton)
    }
}

/// Small, deterministic artwork-derived backing, using the already-loaded image.
/// Transparent/missing artwork has a neutral fallback. This is our reconstruction,
/// not a claim that Apple's editorial palettes are computed by this formula.
private enum HeroArtworkBacking {
    static let fallback = Color(.sRGB, red: 0.30, green: 0.31, blue: 0.33, opacity: 1)

    static func color(from image: NSImage?) -> Color {
        guard let image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return fallback }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return fallback }

        var red = 0.0, green = 0.0, blue = 0.0, totalWeight = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = Double(pixels[index]) / 255 / alpha
            let g = Double(pixels[index + 1]) / 255 / alpha
            let b = Double(pixels[index + 2]) / 255 / alpha
            // Keep colored artwork from being overwhelmed by white borders or
            // black lettering; grayscale covers still produce a neutral backing.
            let chroma = max(r, g, b) - min(r, g, b)
            let weight = alpha * (0.2 + chroma)
            red += r * weight; green += g * weight; blue += b * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else { return fallback }
        let mean = NSColor(srgbRed: red / totalWeight, green: green / totalWeight,
                           blue: blue / totalWeight, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        mean.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(nsColor: NSColor(
            calibratedHue: hue,
            saturation: min(0.65, saturation * 0.8),
            brightness: min(0.62, max(0.28, brightness * 0.95)), alpha: 1
        ))
    }
}

// MARK: - Home Section

struct HomeSection: View {
    @Environment(AppState.self) private var appState
    let title: String
    var subtitle: String? = nil
    let sidebarDestination: SidebarItem?
    let albums: [Album]
    var onRefresh: (() -> Void)?

    private var shelfIdentifier: String {
        "Home.Shelf.\(sidebarDestination?.rawValue ?? "explore")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    if let destination = sidebarDestination {
                        Button {
                            appState.selectedSidebarItem = destination
                        } label: {
                            HStack(spacing: 5) {
                                Text(title)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.headline)
                        .accessibilityIdentifier("\(shelfIdentifier).OpenAll")
                    } else {
                        Text(title).font(.headline)
                    }

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

            }

            PagingRow(
                items: albums,
                itemWidth: 204,
                spacing: 20,
                chevronCenterY: 100,
                contextLabel: title,
                controlStyle: sidebarDestination == .recentlyPlayed ? .capturedRecentlyPlayed : .circular
            ) { album in
                AlbumCardActionSurface(
                    album: album,
                    onPlay: { Task { await playAlbum(album) } },
                    playGlyphSize: 44
                ) { artworkHoverChanged in
                    Button {
                        appState.detailNavigationPath.append(album)
                    } label: {
                        AlbumCardLarge(
                            album: album,
                            showsHoverPlayButton: false,
                            onArtworkHoverChange: artworkHoverChanged
                        )
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded { Task { await playAlbum(album) } }
                    )
                    .accessibilityIdentifier("\(shelfIdentifier).Album.\(album.id)")
                }
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
