import SwiftUI

// MARK: - Layout Options

enum GenreLayoutStyle: String, CaseIterable {
    case list = "List"
    case grid = "Grid"

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}

// MARK: - Complete Genre Enumeration

/// Fetches every admitted song of a genre by paging through getSongsByGenre.
/// Subsonic caps each response, so a single fixed-size request silently
/// truncates large genres; enumerate until a short page returns.
/// Main-actor isolated: reads cached admission state off `AppState`, and every
/// caller is a view. Matches `CurationVerbRegistry`.
@MainActor
enum GenreSongsFetcher {
    static func fetchAllAdmitted(appState: AppState, genre: String) async throws -> [Song] {
        guard let serverId = appState.activeServerId else { return [] }
        let admitted = (try? appState.databaseManager.loadLibraryMemberIds(type: .song, serverId: serverId))
            ?? appState.admittedSongIds
        let hidden = (try? appState.databaseManager.loadHiddenIds(type: "song", serverId: serverId))
            ?? appState.hiddenSongIds

        let pageSize = 500
        var collected: [Song] = []
        var seenIds = Set<String>()
        var offset = 0

        while true {
            let page = try await appState.networkActor.fetchSongsByGenre(genre: genre, count: pageSize, offset: offset)
            for song in page
            where admitted.contains(song.id) && !hidden.contains(song.id) && seenIds.insert(song.id).inserted {
                collected.append(song)
            }
            if page.count < pageSize || page.isEmpty { break }
            offset += pageSize
        }
        return collected
    }
}
struct GenresView: View {
    @Environment(AppState.self) private var appState
    @State private var genres: [Genre] = []
    @State private var viewState: ViewState = .loading
    @State private var searchText = ""
    @AppStorage("genreLayoutStyle") private var layoutStyle: GenreLayoutStyle = .grid

    enum ViewState {
        case loading
        case empty
        case error(Error)
        case populated
    }

    private var filteredGenres: [Genre] {
        if searchText.isEmpty {
            return genres
        }
        return genres.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Apple Music-style page header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Genres")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    if !genres.isEmpty {
                        Text("\(genres.count) genres")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Layout picker
                Picker("Layout", selection: $layoutStyle) {
                    ForEach(GenreLayoutStyle.allCases, id: \.self) { style in
                        Image(systemName: style.icon)
                            .tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Change layout style")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Content - conditional rendering (not overlay)
            Group {
                switch viewState {
                case .loading:
                    GenreLoadingView(layoutStyle: layoutStyle)

                case .empty:
                    CompactStatusView(
                        title: "No Genres",
                        systemImage: "guitars",
                        message: "Genres from your library will appear here."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .error:
                    CompactStatusView(
                        title: "Failed to Load Genres",
                        systemImage: "exclamationmark.triangle",
                        message: "There was a problem loading genre summaries.",
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise"
                    ) {
                        Task { await loadGenres() }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .populated:
                    if filteredGenres.isEmpty {
                        CompactStatusView(
                            title: "No Results",
                            systemImage: "magnifyingglass",
                            message: "No genres match \"\(searchText)\"."
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        switch layoutStyle {
                        case .list:
                            GenreListView(genres: filteredGenres)
                        case .grid:
                            GenreGridView(genres: filteredGenres)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .searchable(text: $searchText, prompt: "Search genres")
        .task(id: appState.activeServerId) {
            await loadGenres()
        }
    }

    private func loadGenres() async {
        // Do not leave the previous server's count visible if the new load fails.
        genres = []
        viewState = .loading
        guard let serverId = appState.activeServerId else {
            genres = []
            viewState = .empty
            return
        }

        do {
            let admittedGenres = try appState.databaseManager.loadAdmittedGenreSummaries(serverId: serverId)
            genres = admittedGenres
            viewState = admittedGenres.isEmpty ? .empty : .populated
        } catch {
            viewState = .error(error)
        }
    }
}

// MARK: - Grid Layout

struct GenreGridView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let genres: [Genre]

    @State private var selectedGenreId: String?
    @State private var viewportWidth: CGFloat = 0
    @FocusState private var isGridFocused: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)
    ]

    // Match vertical keyboard movement to the current viewport, including a
    // resized window or an open inspector.
    private var estimatedColumnsPerRow: Int {
        let availableWidth = max(0, viewportWidth - 48)
        return max(1, Int((availableWidth + 20) / 180))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(genres) { genre in
                        GenreCard(
                            genre: genre,
                            isSelected: selectedGenreId == genre.id,
                            onSelect: { selectedGenreId = genre.id },
                            onPlay: {
                                Task { await playGenre(genre) }
                            },
                            onNavigate: {
                                appState.detailNavigationPath.append(genre)
                            }
                        )
                        .id(genre.id)
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
            .onKeyPress(keys: [.return, .space]) { _ in
                openSelectedGenre()
            }
            .onKeyPress(keys: [KeyEquivalent("p")]) { _ in
                if let genreId = selectedGenreId,
                   let genre = genres.first(where: { $0.id == genreId }) {
                    Task { await playGenre(genre) }
                    return .handled
                }
                return .ignored
            }
        }
        .onAppear {
            isGridFocused = true
        }
        .onChange(of: genres.map(\.id), initial: true) { _, visibleIDs in
            if let selectedGenreId, !visibleIDs.contains(selectedGenreId) {
                self.selectedGenreId = nil
            }
        }
    }

    private func handleArrowKey(_ key: KeyEquivalent, proxy: ScrollViewProxy) -> KeyPress.Result {
        let navigator = GridNavigator(itemCount: genres.count, columnsPerRow: estimatedColumnsPerRow)

        let currentIndex: Int?
        if let selectedGenreId {
            currentIndex = genres.firstIndex(where: { $0.id == selectedGenreId })
        } else {
            currentIndex = nil
        }

        if let newIndex = navigator.navigate(from: currentIndex, direction: key),
           newIndex >= 0, newIndex < genres.count {
            let newId = genres[newIndex].id
            selectedGenreId = newId
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                proxy.scrollTo(newId, anchor: .center)
            }
            return .handled
        }
        return .ignored
    }

    /// Opens the selected genre just as Return/Space does for the other grids.
    private func openSelectedGenre() -> KeyPress.Result {
        guard let genre = selectedGenreId.flatMap({ id in genres.first(where: { $0.id == id }) })
                ?? genres.first else { return .ignored }
        selectedGenreId = genre.id
        appState.detailNavigationPath.append(genre)
        return .handled
    }

    private func playGenre(_ genre: Genre) async {
        do {
            let songs = try await GenreSongsFetcher.fetchAllAdmitted(appState: appState, genre: genre.name)
            if !songs.isEmpty {
                await appState.playbackManager.play(songs: songs.shuffled())
            }
        } catch {
            print("Failed to play genre: \(error)")
        }
    }

}

// MARK: - Genre Card (Apple Music Style)

struct GenreCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let genre: Genre
    let isSelected: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onNavigate: () -> Void

    @State private var isHovered = false
    @State private var isPlayButtonHovered = false

    private let size: CGFloat = 160

    /// Generate a consistent gradient for a genre based on its name
    private var genreGradient: LinearGradient {
        let colors = genreColors(for: genre.name)
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Genre icon based on name
    private var genreIcon: String {
        let name = genre.name.lowercased()
        if name.contains("rock") || name.contains("metal") || name.contains("punk") {
            return "guitars.fill"
        } else if name.contains("jazz") || name.contains("blues") {
            return "music.quarternote.3"
        } else if name.contains("classical") || name.contains("orchestra") {
            return "music.note"
        } else if name.contains("electronic") || name.contains("techno") || name.contains("house") || name.contains("edm") {
            return "waveform"
        } else if name.contains("hip") || name.contains("rap") || name.contains("r&b") {
            return "mic.fill"
        } else if name.contains("country") || name.contains("folk") || name.contains("acoustic") {
            return "music.mic"
        } else if name.contains("pop") {
            return "star.fill"
        } else if name.contains("soul") || name.contains("gospel") {
            return "heart.fill"
        } else if name.contains("reggae") || name.contains("ska") {
            return "sun.max.fill"
        } else if name.contains("ambient") || name.contains("chill") {
            return "cloud.fill"
        } else {
            return "music.note.list"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Artwork area with gradient background
            ZStack(alignment: .bottomTrailing) {
                // Gradient background
                genreGradient
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        // Genre icon
                        Image(systemName: genreIcon)
                            .font(.system(size: 44, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .shadow(
                        color: .black.opacity(isHovered ? 0.18 : 0.08),
                        radius: isHovered ? 12 : 8,
                        x: 0,
                        y: isHovered ? 6 : 4
                    )

                // Hover overlay
                if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.15))
                        .frame(width: size, height: size)
                }

                // Play button (only on hover)
                if isHovered {
                    playButton
                        .padding(8)
                        .transition(reduceMotion ? .identity : .scale.combined(with: .opacity))
                }
            }
            .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1.0)
            .animation(reduceMotion ? nil : DesignTokens.Animation.quick, value: isHovered)
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : DesignTokens.Animation.quick) {
                    isHovered = hovering
                }
            }

            // Labels
            VStack(alignment: .leading, spacing: 2) {
                Text(genre.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .help(genre.name)

                Text("\(genre.albumCount) albums")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: size)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !isPlayButtonHovered else { return }
            onSelect()
            onPlay()
        }
        .onTapGesture {
            // The play control is nested inside the card's hit region; don't
            // let its click also push the genre detail route.
            guard !isPlayButtonHovered else { return }
            onSelect()
            onNavigate()
        }
        .contextMenu {
            GenreContextMenu(genre: genre)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(genre.name), \(genre.albumCount) albums, \(genre.songCount) songs")
        .accessibilityHint("Opens genre details.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Play") { onPlay() }
        .accessibilityAction(named: "Open") { onNavigate() }
    }

    @ViewBuilder
    private var playButton: some View {
        Button {
            onPlay()
        } label: {
            ZStack {
                Circle()
                    .fill(.black.opacity(isPlayButtonHovered ? 0.8 : 0.6))
                    .frame(width: 44, height: 44)

                Image(systemName: "play.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .offset(x: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(genre.name)")
        .onHover { isPlayButtonHovered = $0 }
        .scaleEffect(isPlayButtonHovered && !reduceMotion ? 1.1 : 1.0)
        .animation(reduceMotion ? nil : DesignTokens.Animation.quick, value: isPlayButtonHovered)
    }

    /// Generate consistent colors based on genre name
    private func genreColors(for name: String) -> [Color] {
        let lowercased = name.lowercased()

        // Specific genre color mappings
        if lowercased.contains("rock") || lowercased.contains("metal") {
            return [Color(red: 0.3, green: 0.1, blue: 0.1), Color(red: 0.6, green: 0.2, blue: 0.2)]
        } else if lowercased.contains("jazz") || lowercased.contains("blues") {
            return [Color(red: 0.1, green: 0.2, blue: 0.4), Color(red: 0.2, green: 0.4, blue: 0.6)]
        } else if lowercased.contains("classical") {
            return [Color(red: 0.4, green: 0.3, blue: 0.2), Color(red: 0.6, green: 0.5, blue: 0.4)]
        } else if lowercased.contains("electronic") || lowercased.contains("techno") || lowercased.contains("house") {
            return [Color(red: 0.1, green: 0.1, blue: 0.3), Color(red: 0.4, green: 0.2, blue: 0.6)]
        } else if lowercased.contains("hip") || lowercased.contains("rap") {
            return [Color(red: 0.2, green: 0.1, blue: 0.3), Color(red: 0.5, green: 0.2, blue: 0.4)]
        } else if lowercased.contains("pop") {
            return [Color(red: 0.5, green: 0.2, blue: 0.4), Color(red: 0.7, green: 0.4, blue: 0.5)]
        } else if lowercased.contains("country") || lowercased.contains("folk") {
            return [Color(red: 0.4, green: 0.3, blue: 0.1), Color(red: 0.6, green: 0.5, blue: 0.2)]
        } else if lowercased.contains("r&b") || lowercased.contains("soul") {
            return [Color(red: 0.3, green: 0.1, blue: 0.3), Color(red: 0.5, green: 0.3, blue: 0.5)]
        } else if lowercased.contains("reggae") {
            return [Color(red: 0.2, green: 0.4, blue: 0.2), Color(red: 0.4, green: 0.6, blue: 0.3)]
        } else if lowercased.contains("ambient") || lowercased.contains("chill") {
            return [Color(red: 0.2, green: 0.3, blue: 0.4), Color(red: 0.4, green: 0.5, blue: 0.6)]
        }

        // Default: hash-based color
        let hash = abs(name.hashValue)
        let hue1 = Double(hash % 360) / 360.0
        let hue2 = Double((hash + 30) % 360) / 360.0
        return [
            Color(hue: hue1, saturation: 0.5, brightness: 0.3),
            Color(hue: hue2, saturation: 0.5, brightness: 0.5)
        ]
    }
}

// MARK: - List Layout

struct GenreListView: View {
    @Environment(AppState.self) private var appState
    let genres: [Genre]

    var body: some View {
        List(genres) { genre in
            NavigationLink(value: genre) {
                GenreRow(genre: genre)
            }
            .contextMenu {
                GenreContextMenu(genre: genre)
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 240, maxHeight: .infinity)
    }
}

struct GenreRow: View {
    let genre: Genre
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Small genre indicator
            RoundedRectangle(cornerRadius: 4)
                .fill(genreGradient)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "music.note.list")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(genre.name)
                    .font(.body)
                    .fontWeight(.medium)

                Text("\(genre.albumCount) albums - \(genre.songCount) songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { isHovered = $0 }
    }

    private var genreGradient: LinearGradient {
        let hash = abs(genre.name.hashValue)
        let hue1 = Double(hash % 360) / 360.0
        let hue2 = Double((hash + 30) % 360) / 360.0
        return LinearGradient(
            colors: [
                Color(hue: hue1, saturation: 0.5, brightness: 0.4),
                Color(hue: hue2, saturation: 0.5, brightness: 0.5)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Genre Context Menu

struct GenreContextMenu: View {
    @Environment(AppState.self) private var appState
    let genre: Genre

    var body: some View {
        Button {
            Task { await playGenre(shuffled: false) }
        } label: {
            Label("Play", systemImage: "play")
        }

        Button {
            Task { await playGenre(shuffled: true) }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            Task { await addToQueue() }
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }

        Divider()

        Button {
            appState.detailNavigationPath.append(genre)
        } label: {
            Label("View Genre", systemImage: "guitars")
        }
    }

    private func playGenre(shuffled: Bool) async {
        do {
            var songs = try await GenreSongsFetcher.fetchAllAdmitted(appState: appState, genre: genre.name)
            if shuffled {
                songs.shuffle()
            }
            if !songs.isEmpty {
                await appState.playbackManager.play(songs: songs)
            }
        } catch {
            print("Failed to play genre: \(error)")
        }
    }

    private func addToQueue() async {
        do {
            let songs = try await GenreSongsFetcher.fetchAllAdmitted(appState: appState, genre: genre.name)
            appState.playbackManager.addToQueue(songs)
        } catch {
            print("Failed to add genre to queue: \(error)")
        }
    }

}

// MARK: - Loading View

struct GenreLoadingView: View {
    let layoutStyle: GenreLayoutStyle

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)
    ]

    var body: some View {
        switch layoutStyle {
        case .grid:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(0..<12, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(DesignTokens.Placeholder.adaptive)
                                .frame(width: 160, height: 160)

                            VStack(alignment: .leading, spacing: 4) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(DesignTokens.Placeholder.adaptive)
                                    .frame(width: 100, height: 14)

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(DesignTokens.Placeholder.adaptive)
                                    .frame(width: 60, height: 12)
                            }
                        }
                        .redacted(reason: .placeholder)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        case .list:
            List {
                ForEach(0..<10, id: \.self) { _ in
                    HStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(DesignTokens.Placeholder.adaptive)
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading) {
                            Text("Genre Name")
                            RoundedRectangle(cornerRadius: 4)
                                .fill(DesignTokens.Placeholder.adaptive)
                                .frame(width: 60, height: 12)
                        }
                        Spacer()
                    }
                    .redacted(reason: .placeholder)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 240, maxHeight: .infinity)
        }
    }
}

// GenreDetailView moved to GenreDetailView.swift

#Preview {
    NavigationStack {
        GenresView()
            .environment(AppState())
    }
}
