import SwiftUI
import UniformTypeIdentifiers


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
    @AppStorage("enableOnePlane") private var enableOnePlane = false

    // Collapsed sections persistence (stored as comma-separated string for AppStorage)
    @AppStorage("sidebarCollapsedGroups") private var collapsedGroupsString: String = ""

    // Sidebar width persistence
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 213

    private var forcesAtlasVisibility: Bool {
        ProcessInfo.processInfo.environment["RESONANCE_PARITY_FIXTURE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "atlas"
    }

    private func isVisible(_ storedValue: Bool) -> Bool {
        forcesAtlasVisibility || storedValue
    }

    private var collapsedGroups: Set<String> {
        get {
            Set(collapsedGroupsString.split(separator: ",").map(String.init))
        }
    }

    private func toggleSection(_ section: String) {
        guard !forcesAtlasVisibility else { return }
        var groups = collapsedGroups
        if groups.contains(section) {
            groups.remove(section)
        } else {
            groups.insert(section)
        }
        collapsedGroupsString = groups.joined(separator: ",")
    }

    private func isCollapsed(_ section: String) -> Bool {
        !forcesAtlasVisibility && collapsedGroups.contains(section)
    }

    private var visibleLibraryItems: [SidebarItem] {
        var items: [SidebarItem] = []
        if isVisible(showArtists) { items.append(.artists) }
        if isVisible(showAlbums) { items.append(.albums) }
        if isVisible(showSongs) { items.append(.songs) }
        if isVisible(showGenres) { items.append(.genres) }
        if isVisible(showFolders) { items.append(.folders) }
        return items
    }

    private var allSidebarItemsHidden: Bool {
        // Public playlist discovery is an always-visible destination.
        false
    }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            // Search navigation; the query belongs in the detail toolbar.
            SidebarSearchNavigation()
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
        .frame(minWidth: 210)
        // A frame's idealWidth is not the NavigationSplitView allocation.
        // Native state 50 allocates 213 points to this split item; preserve
        // normal-mode user widths, but establish that measured initial width.
        .navigationSplitViewColumnWidth(
            min: 210,
            ideal: forcesAtlasVisibility ? 213 : max(210, sidebarWidth)
        )
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
        .accessibilityIdentifier("sidebar-empty-state")
    }

    // MARK: - Top Level Items

    @ViewBuilder
    private var topLevelItemsSection: some View {
        Group {
            if isVisible(showListen) {
                SidebarItemCell(
                    label: "Listen",
                    icon: "play.circle.fill",
                    item: .listen
                )
                .tag(SidebarItem.listen)
            }

            if isVisible(enableOnePlane) {
                SidebarItemCell(
                    label: "Plane",
                    icon: "square.stack.3d.down.right.fill",
                    item: .plane
                )
                .tag(SidebarItem.plane)
            }

            if isVisible(showHome) {
                SidebarItemCell(
                    label: "Home",
                    icon: "house.fill",
                    item: .home
                )
                .tag(SidebarItem.home)
            }

            if isVisible(showNewMusic) {
                SidebarItemCell(
                    label: "New Music",
                    icon: "sparkles",
                    item: .newMusic,
                    badgeCount: appState.unseenDiscoveryCount
                )
                .tag(SidebarItem.newMusic)
            }

            if isVisible(showRecentlyAdded) {
                SidebarItemCell(
                    label: "Recently Added",
                    icon: "clock.badge.checkmark",
                    item: .recentlyAdded
                )
                .tag(SidebarItem.recentlyAdded)
            }

            if isVisible(showWaitingRoom) {
                SidebarItemCell(
                    label: "Waiting Room",
                    icon: "tray.fill",
                    item: .waitingRoom
                )
                .tag(SidebarItem.waitingRoom)
            }

            if isVisible(showProjects) {
                SidebarItemCell(
                    label: "Projects",
                    icon: "tray.full.fill",
                    item: .projects
                )
                .tag(SidebarItem.projects)
            }

            if isVisible(showUnclassified) && appState.unclassifiedCount > 0 {
                SidebarItemCell(
                    label: "Unclassified",
                    icon: "rectangle.dashed",
                    item: .unclassified,
                    badgeCount: appState.unclassifiedCount
                )
                .tag(SidebarItem.unclassified)
            }

            // Import Policies is normally reached from Settings. Goal 01's
            // shell route must make every protected Resonance destination
            // observable without changing normal navigation, so expose the
            // existing production route only while the atlas gate is active.
            if forcesAtlasVisibility {
                SidebarItemCell(
                    label: "Import Policies",
                    icon: "slider.horizontal.3",
                    item: .importPolicies
                )
                .tag(SidebarItem.importPolicies)
            }

            if isVisible(showRadio) {
                SidebarItemCell(
                    label: "Radio",
                    icon: "antenna.radiowaves.left.and.right",
                    item: .radio
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
                        item: item
                    )
                    .tag(item)
                }

                if isVisible(showFavorites) {
                    SidebarItemCell(
                        label: "Liked Songs",
                        icon: "heart.fill",
                        item: .favorites
                    )
                    .tag(SidebarItem.favorites)
                }

                if isVisible(showRecentlyPlayed) {
                    SidebarItemCell(
                        label: "Recently Played",
                        icon: "clock.fill",
                        item: .recentlyPlayed
                    )
                    .tag(SidebarItem.recentlyPlayed)
                }

                if isVisible(showDownloads) {
                    SidebarItemCell(
                        label: "Downloads",
                        icon: "arrow.down.circle.fill",
                        item: .downloads
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
                    item: .playlists
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
                .frame(height: 32) // uniform 32pt row pitch (Music 1.7 state 10 viewhierarchy)

                Button {
                    appState.editSmartPlaylistTarget = nil
                    appState.showSmartPlaylistEditor = true
                } label: {
                    Label("New Smart Playlist", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(height: 32)
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
        .frame(height: 32) // native: rows 32pt @32 pitch (AX exact)
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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)

                Text(title)
                    .font(.system(size: 11, weight: .semibold)) // native header ~11pt
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: 19) // Music 1.7: section header rows measure 19pt (state 10 viewhierarchy)
        .accessibilityLabel(title)
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(isCollapsed ? "Expands the \(title) section" : "Collapses the \(title) section")
        .accessibilityIdentifier("sidebar-section-\(title.lowercased())")
    }
}

// MARK: - Sidebar Item Cell (Regular Items)

struct SidebarItemCell: View {
    let label: String
    let icon: String
    let item: SidebarItem
    var badgeCount: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(label)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if badgeCount > 0 {
                Text("\(badgeCount)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32) // Music 1.7: every source-list row is 32pt tall at 32pt pitch (state 10 viewhierarchy)
        .contentShape(Rectangle())
        // Selection highlighting, keyboard focus, and inactive-window dimming are
        // owned by List(selection:) + .sidebar style, matching the native
        // NSOutlineView row-selection mechanism. Cells never paint their own
        // selection background.
        .accessibilityElement(children: .combine)
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
            .frame(height: 32) // uniform 32pt row pitch (Music 1.7 state 10 viewhierarchy)
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
            .frame(height: 32)
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

struct SidebarSearchNavigation: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.selectedSidebarItem = .search
            appState.shouldFocusSearch = true
        } label: {
            Label("Search", systemImage: "magnifyingglass")
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(appState.selectedSidebarItem == .search
            ? Color.primary.opacity(0.08) : .clear,
            in: RoundedRectangle(cornerRadius: 8))
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

    private var statusText: String {
        switch appState.connectionStatus {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .error: return "error"
        case .disconnected: return "disconnected"
        case .offline: return "offline"
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(appState.activeServer?.username ?? "Not Signed In"), \(appState.activeServer?.name ?? "No Server")")
        .accessibilityValue("Connection \(statusText)")
        .accessibilityHint("Opens Settings")
        .accessibilityIdentifier("sidebar-footer")
    }
}


// MARK: - Preview

#Preview {
    SidebarView()
        .environment(AppState())
        .frame(width: 220, height: 600)
}
