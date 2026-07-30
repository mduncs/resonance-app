import SwiftUI
import UniformTypeIdentifiers

// MARK: - Group Kind

enum SidebarGroupKind: Int {
    case regular = 0      // Standard items (Home, Songs, Albums, etc.)
    case library = 1      // Library section header
    case playlists = 2    // Playlists section
    case pins = 3         // Pinned items section
}

// MARK: - Main Sidebar View

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    // Sidebar visibility settings
    @AppStorage("showSidebarListen") private var showListen = true
    @AppStorage("showSidebarHome") private var showHome = true
    @AppStorage("showSidebarWaitingRoom") private var showWaitingRoom = true
    @AppStorage("showSidebarProjects") private var showProjects = true
    @AppStorage("showSidebarUnclassified") private var showUnclassified = true
    @AppStorage("showSidebarArtists") private var showArtists = true
    @AppStorage("showSidebarAlbums") private var showAlbums = true
    @AppStorage("showSidebarSongs") private var showSongs = true
    @AppStorage("showSidebarGenres") private var showGenres = true
    @AppStorage("showSidebarFolders") private var showFolders = true
    @AppStorage("showSidebarFavorites") private var showFavorites = true
    @AppStorage("showSidebarRecentlyPlayed") private var showRecentlyPlayed = true
    @AppStorage("showSidebarNewMusic") private var showNewMusic = true
    @AppStorage("showSidebarRecentlyAdded") private var showRecentlyAdded = true
    @AppStorage("showSidebarDownloads") private var showDownloads = true
    @AppStorage("showSidebarRadio") private var showRadio = true
    @AppStorage(FetcherContractSettings.isEnabledKey) private var enableFetcherSourceBrowser = false
    @AppStorage("enableOnePlane") private var enableOnePlane = false

    // Collapsed sections persistence (stored as comma-separated string for AppStorage)
    @AppStorage("sidebarCollapsedGroups") private var collapsedGroupsString: String = ""

    // Sidebar width persistence
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 200

    private var collapsedGroups: Set<String> {
        get {
            Set(collapsedGroupsString.split(separator: ",").map(String.init))
        }
    }

    private func toggleSection(_ section: String) {
        var groups = collapsedGroups
        if groups.contains(section) {
            groups.remove(section)
        } else {
            groups.insert(section)
        }
        collapsedGroupsString = groups.joined(separator: ",")
    }

    private func isCollapsed(_ section: String) -> Bool {
        collapsedGroups.contains(section)
    }

    private var visibleLibraryItems: [SidebarItem] {
        var items: [SidebarItem] = []
        if showArtists { items.append(.artists) }
        if showAlbums { items.append(.albums) }
        if showSongs { items.append(.songs) }
        if showGenres { items.append(.genres) }
        if showFolders { items.append(.folders) }
        return items
    }

    private var allSidebarItemsHidden: Bool {
        !showHome && !showArtists && !showAlbums && !showSongs && !showGenres &&
        !showFolders && !showFavorites && !showRecentlyPlayed && !showNewMusic && !showRecentlyAdded &&
        !showDownloads && !showRadio && !showListen && !showWaitingRoom &&
        !showProjects && !showUnclassified &&
        !enableFetcherSourceBrowser && !enableOnePlane
    }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            // Search field at very top
            SidebarSearchField()
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if allSidebarItemsHidden && appState.pinnedItems.isEmpty && appState.playlists.isEmpty {
                emptyStateView
            } else {
                List(selection: $state.selectedSidebarItem) {
                    // Top-level nav items (no section header, like Apple Music)
                    topLevelItemsSection

                    // Pins section (only if there are pins)
                    if !appState.pinnedItems.isEmpty {
                        pinsSection
                    }

                    // Library section
                    librarySection

                    // Playlists section
                    playlistsSection
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(.ultraThinMaterial)
        .frame(minWidth: 180, idealWidth: sidebarWidth)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "sidebar.left")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No items visible")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Enable items in Settings > General")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Button("Open Settings") {
                UserDefaults.standard.set(SettingsTab.general.rawValue, forKey: SettingsTab.storageKey)
                openSettings()
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Top Level Items

    @ViewBuilder
    private var topLevelItemsSection: some View {
        Group {
            if showListen {
                SidebarItemCell(
                    label: "Listen",
                    icon: "play.circle.fill",
                    item: .listen,
                    selection: appState.selectedSidebarItem
                )
                .tag(SidebarItem.listen)
            }

            if enableOnePlane {
                SidebarItemCell(
                    label: "Plane",
                    icon: "square.stack.3d.down.right.fill",
                    item: .plane,
                    selection: appState.selectedSidebarItem
                )
                .tag(SidebarItem.plane)
            }

            if showHome {
                SidebarItemCell(
                    label: "Home",
                    icon: "house.fill",
                    item: .home,
                    selection: appState.selectedSidebarItem
                )
                .tag(SidebarItem.home)
            }

            if showNewMusic {
                SidebarItemCell(
                    label: "New Music",
                    icon: "sparkles",
                    item: .newMusic,
                    selection: appState.selectedSidebarItem,
                    badgeCount: appState.unseenDiscoveryCount
                )
                .tag(SidebarItem.newMusic)
            }

            if showRecentlyAdded {
                SidebarItemCell(
                    label: "Recently Added",
                    icon: "clock.badge.checkmark",
                    item: .recentlyAdded,
                    selection: appState.selectedSidebarItem
                )
                .tag(SidebarItem.recentlyAdded)
            }

            if showWaitingRoom {
                SidebarItemCell(
                    label: "Waiting Room",
                    icon: "tray.fill",
                    item: .waitingRoom,
                    selection: appState.selectedSidebarItem
                )
                .tag(SidebarItem.waitingRoom)
            }

            if showProjects {
                SidebarItemCell(
                    label: "Projects",
                    icon: "tray.full.fill",
                    item: .projects,
                    selection: appState.selectedSidebarItem
                )
                .tag(SidebarItem.projects)
            }

            if showUnclassified && appState.unclassifiedCount > 0 {
                SidebarItemCell(
                    label: "Unclassified",
                    icon: "rectangle.dashed",
                    item: .unclassified,
                    selection: appState.selectedSidebarItem,
                    badgeCount: appState.unclassifiedCount
                )
                .tag(SidebarItem.unclassified)
            }

            if enableFetcherSourceBrowser {
                SidebarItemCell(
                    label: "Sources",
                    icon: "tray.and.arrow.down.fill",
                    item: .fetcherSources,
                    selection: appState.selectedSidebarItem
                )
                .tag(SidebarItem.fetcherSources)
            }

            if showRadio {
                SidebarItemCell(
                    label: "Radio",
                    icon: "antenna.radiowaves.left.and.right",
                    item: .radio,
                    selection: appState.selectedSidebarItem
                )
                .tag(SidebarItem.radio)
            }
        }
    }

    // MARK: - Pins Section

    @ViewBuilder
    private var pinsSection: some View {
        Section {
            if !isCollapsed("pins") {
                ForEach(appState.pinnedItems) { pin in
                    SidebarPinCell(pin: pin)
                }
                .onMove { source, destination in
                    appState.movePins(from: source, to: destination)
                }
            }
        } header: {
            SidebarHeaderCell(
                title: "Pins",
                isCollapsed: isCollapsed("pins"),
                onToggle: { toggleSection("pins") }
            )
        }
    }

    // MARK: - Library Section

    @ViewBuilder
    private var librarySection: some View {
        Section {
            if !isCollapsed("library") {
                ForEach(visibleLibraryItems, id: \.self) { item in
                    SidebarItemCell(
                        label: item.label,
                        icon: item.filledIcon,
                        item: item,
                        selection: appState.selectedSidebarItem
                    )
                    .tag(item)
                }

                if showFavorites {
                    SidebarItemCell(
                        label: "Liked Songs",
                        icon: "heart.fill",
                        item: .favorites,
                        selection: appState.selectedSidebarItem
                    )
                    .tag(SidebarItem.favorites)
                }

                if showRecentlyPlayed {
                    SidebarItemCell(
                        label: "Recently Played",
                        icon: "clock.fill",
                        item: .recentlyPlayed,
                        selection: appState.selectedSidebarItem
                    )
                    .tag(SidebarItem.recentlyPlayed)
                }

                if showDownloads {
                    SidebarItemCell(
                        label: "Downloads",
                        icon: "arrow.down.circle.fill",
                        item: .downloads,
                        selection: appState.selectedSidebarItem
                    )
                    .tag(SidebarItem.downloads)
                }
            }
        } header: {
            SidebarHeaderCell(
                title: "Library",
                isCollapsed: isCollapsed("library"),
                onToggle: { toggleSection("library") }
            )
        }
    }

    // MARK: - Playlists Section

    @ViewBuilder
    private var playlistsSection: some View {
        Section {
            if !isCollapsed("playlists") {
                SidebarItemCell(
                    label: "All Playlists",
                    icon: "music.note.list",
                    item: .playlists,
                    selection: appState.selectedSidebarItem
                )
                .tag(SidebarItem.playlists)

                ForEach(appState.playlists) { playlist in
                    SidebarPlaylistCell(playlist: playlist)
                }

                ForEach(appState.smartPlaylists) { smartPlaylist in
                    SidebarSmartPlaylistCell(smartPlaylist: smartPlaylist)
                }

                Button {
                    appState.createPlaylistSongIds = []
                    appState.showCreatePlaylistSheet = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(height: 28)

                Button {
                    appState.editSmartPlaylistTarget = nil
                    appState.showSmartPlaylistEditor = true
                } label: {
                    Label("New Smart Playlist", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(height: 28)
            }
        } header: {
            SidebarHeaderCell(
                title: "Playlists",
                isCollapsed: isCollapsed("playlists"),
                onToggle: { toggleSection("playlists") }
            )
        }
    }
}

// MARK: - Sidebar Smart Playlist Cell

struct SidebarSmartPlaylistCell: View {
    @Environment(AppState.self) private var appState
    let smartPlaylist: SmartPlaylist

    var body: some View {
        Button {
            appState.selectedSidebarItem = .playlists
            appState.detailNavigationPath.append(smartPlaylist)
        } label: {
            Label(smartPlaylist.name, systemImage: "wand.and.stars")
        }
        .buttonStyle(.plain)
        .frame(height: 28)
        .contextMenu {
            Button {
                appState.editSmartPlaylistTarget = smartPlaylist
                appState.showSmartPlaylistEditor = true
            } label: {
                Label("Edit Rules", systemImage: "slider.horizontal.3")
            }

            Button(role: .destructive) {
                guard let serverId = appState.activeServerId else { return }
                try? appState.databaseManager.deleteSmartPlaylist(id: smartPlaylist.id)
                appState.smartPlaylists = (try? appState.databaseManager.loadSmartPlaylists(serverId: serverId)) ?? []
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Sidebar Header Cell (Collapsible Section Headers)

struct SidebarHeaderCell: View {
    let title: String
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.top, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) section, \(isCollapsed ? "collapsed" : "expanded")")
        .accessibilityHint("Double tap to \(isCollapsed ? "expand" : "collapse")")
    }
}

// MARK: - Sidebar Item Cell (Regular Items)

struct SidebarItemCell: View {
    let label: String
    let icon: String
    let item: SidebarItem
    let selection: SidebarItem?
    var badgeCount: Int = 0

    private var isSelected: Bool {
        selection == item
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 20)

            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? .primary : .primary)

            if badgeCount > 0 {
                Spacer()
                Text("\(badgeCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.blue))
            }
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("sidebar-\(item.rawValue)")
    }
}

// MARK: - Sidebar Pin Cell (Pinned Items)

struct SidebarPinCell: View {
    @Environment(AppState.self) private var appState
    let pin: PinnedItem

    var body: some View {
        Button {
            navigateToPin()
        } label: {
            HStack(spacing: 8) {
                EnvironmentAlbumArtView(coverArtId: pin.coverArtId, size: .small)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Text(pin.name)
                    .lineLimit(1)
                    .font(.system(size: 13))

                Spacer()
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                appState.unpin(id: pin.id, type: pin.type)
            } label: {
                Label("Unpin", systemImage: "pin.slash")
            }

            Divider()

            Button {
                navigateToPin()
            } label: {
                Label("Go to \(pin.type.rawValue.capitalized)", systemImage: iconForType)
            }
        }
        .accessibilityIdentifier("sidebar-pin-\(pin.id)")
    }

    private var iconForType: String {
        switch pin.type {
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        case .artist: return "music.mic"
        }
    }

    private func navigateToPin() {
        switch pin.type {
        case .album:
            appState.navigationTargetAlbumId = pin.id
            appState.selectedSidebarItem = .albums
        case .artist:
            appState.navigationTargetArtistId = pin.id
            appState.selectedSidebarItem = .artists
        case .playlist:
            if let playlist = appState.playlists.first(where: { $0.id == pin.id }) {
                Task { @MainActor in
                    // Clear path first if we're on a different section
                    if appState.selectedSidebarItem != .playlists {
                        appState.detailNavigationPath = NavigationPath()
                    }
                    appState.selectedSidebarItem = .playlists
                    // Small delay to let NavigationStack settle after sidebar change
                    try? await Task.sleep(for: .milliseconds(50))
                    appState.detailNavigationPath.append(playlist)
                }
            } else {
                // Playlist not found in loaded playlists, just navigate to playlists section
                appState.selectedSidebarItem = .playlists
            }
        }
    }
}

// MARK: - Sidebar Playlist Cell (Playlist Items with Drop Support)

struct SidebarPlaylistCell: View {
    @Environment(AppState.self) private var appState
    let playlist: Playlist
    @State private var isTargeted = false

    var body: some View {
        Button {
            // Navigate to playlist detail
            appState.selectedSidebarItem = .playlists
            appState.detailNavigationPath.append(playlist)
        } label: {
            HStack(spacing: 8) {
                // Playlist icon or artwork
                if let coverArt = playlist.coverArt {
                    EnvironmentAlbumArtView(coverArtId: coverArt, size: .small)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }

                Text(playlist.name)
                    .lineLimit(1)
                    .font(.system(size: 13))

                Spacer()
            }
            .frame(height: 28)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isTargeted ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [UTType.text], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .contextMenu {
            PlaylistContextMenu(playlist: playlist)
        }
        .accessibilityIdentifier("sidebar-playlist-\(playlist.id)")
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, error in
                    guard let data = item as? Data,
                          let songIds = String(data: data, encoding: .utf8)?
                            .split(separator: ",")
                            .map(String.init),
                          !songIds.isEmpty else {
                        return
                    }

                    Task { @MainActor in
                        do {
                            try await appState.networkActor.updatePlaylist(
                                id: playlist.id,
                                songIdsToAdd: songIds
                            )
                            // Refresh playlists to show updated count
                            let playlists = try await appState.networkActor.fetchPlaylists()
                            appState.playlists = playlists
                        } catch {
                            print("Failed to add songs to playlist: \(error)")
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}

// MARK: - Sidebar Search Field

struct SidebarSearchField: View {
    @Environment(AppState.self) private var appState
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var state = appState

        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            TextField("Search", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)
                .onChange(of: state.searchQuery) { _, newValue in
                    if !newValue.isEmpty && appState.selectedSidebarItem != .search {
                        appState.selectedSidebarItem = .search
                    }
                }
                .onSubmit {
                    if appState.selectedSidebarItem != .search {
                        appState.selectedSidebarItem = .search
                    }
                }
                .onKeyPress(.escape) {
                    if !appState.searchQuery.isEmpty {
                        appState.searchQuery = ""
                    }
                    isSearchFocused = false
                    return .handled
                }

            if !appState.searchQuery.isEmpty {
                Button {
                    appState.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            if isSearchFocused {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
            }
        }
        .onChange(of: appState.shouldFocusSearch) { _, shouldFocus in
            if shouldFocus {
                isSearchFocused = true
                appState.shouldFocusSearch = false
            }
        }
        .accessibilityIdentifier("sidebar-search")
    }
}

// MARK: - Sidebar Footer

struct SidebarFooter: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @State private var isHovered = false

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .error:
            return .red
        case .disconnected, .offline:
            return .gray
        }
    }

    private var userInitials: String {
        guard let username = appState.activeServer?.username else { return "?" }
        let parts = username.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(username.prefix(2)).uppercased()
    }

    var body: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: 10) {
                // User avatar with status indicator
                ZStack(alignment: .bottomTrailing) {
                    // Avatar circle with gradient
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.8),
                                    Color.accentColor.opacity(0.5)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                        .overlay(
                            Text(userInitials)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                        )

                    // Status indicator dot
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                        )
                        .offset(x: 2, y: 2)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.activeServer?.username ?? "Not Signed In")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(appState.activeServer?.name ?? "No Server")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Chevron indicator
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            ZStack {
                // Frosted glass effect
                VisualEffectView(
                    material: .sidebar,
                    blendingMode: .behindWindow,
                    state: .active
                )

                // Subtle gradient overlay for depth
                LinearGradient(
                    colors: [
                        .white.opacity(isHovered ? 0.08 : 0.04),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Top border for visual separation
                VStack {
                    Rectangle()
                        .fill(.white.opacity(0.1))
                        .frame(height: 0.5)
                    Spacer()
                }
            }
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityIdentifier("sidebar-footer")
    }
}

// MARK: - Playlist Drop Delegate (Alternative approach for more control)

struct PlaylistDropDelegate: DropDelegate {
    let playlist: Playlist
    let appState: AppState

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let songIds = String(data: data, encoding: .utf8)?
                    .split(separator: ",")
                    .map(String.init),
                  !songIds.isEmpty else {
                return
            }

            Task { @MainActor in
                do {
                    try await appState.networkActor.updatePlaylist(
                        id: playlist.id,
                        songIdsToAdd: songIds
                    )
                    // Refresh playlists
                    let playlists = try await appState.networkActor.fetchPlaylists()
                    appState.playlists = playlists
                } catch {
                    print("Failed to add songs to playlist: \(error)")
                }
            }
        }

        return true
    }
}

// MARK: - Preview

#Preview {
    SidebarView()
        .environment(AppState())
        .frame(width: 220, height: 600)
}
