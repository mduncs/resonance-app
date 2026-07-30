import SwiftUI

enum SettingsTab: String, CaseIterable {
    static let storageKey = "settingsSelectedTab"

    case general
    case playback
    case library
    case importing
    case appearance
    case storage
    case server
    case privacy
    case shortcuts
    case advanced

    var title: String {
        switch self {
        case .general:
            return "General"
        case .playback:
            return "Playback"
        case .library:
            return "Library"
        case .importing:
            return "Importing"
        case .appearance:
            return "Appearance"
        case .storage:
            return "Storage"
        case .server:
            return "Server"
        case .privacy:
            return "Privacy"
        case .shortcuts:
            return "Shortcuts"
        case .advanced:
            return "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gear"
        case .playback:
            return "play.circle"
        case .library:
            return "books.vertical"
        case .importing:
            return "square.and.arrow.down"
        case .appearance:
            return "paintbrush"
        case .storage:
            return "internaldrive"
        case .server:
            return "server.rack"
        case .privacy:
            return "hand.raised"
        case .shortcuts:
            return "keyboard"
        case .advanced:
            return "gearshape.2"
        }
    }
}

struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var selectedTab = SettingsTab.general.rawValue

    private var activeTabTitle: String {
        SettingsTab(rawValue: selectedTab)?.title ?? "Settings"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .settingsTab(.general)

            PlaybackSettingsView()
                .settingsTab(.playback)

            LibrarySettingsView()
                .settingsTab(.library)

            ImportPoliciesView()
                .settingsTab(.importing)

            AppearanceSettingsView()
                .settingsTab(.appearance)

            CacheSettingsView()
                .settingsTab(.storage)

            ServerSettingsView()
                .settingsTab(.server)

            PrivacySettingsView()
                .settingsTab(.privacy)

            KeyboardShortcutsView()
                .settingsTab(.shortcuts)

            AdvancedSettingsView()
                .settingsTab(.advanced)
        }
        .navigationTitle(activeTabTitle)
        .frame(width: 760, height: 580)
    }
}

private extension View {
    func settingsTab(_ tab: SettingsTab) -> some View {
        self
            .tabItem {
                Label(tab.title, systemImage: tab.systemImage)
            }
            .tag(tab.rawValue)
    }

    func settingsDescription() -> some View {
        self
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage("showMenuBarPlayer") private var showMenuBarPlayer = true
    @AppStorage("startMinimized") private var startMinimized = false
    @AppStorage("showNotifications") private var showNotifications = true
    @AppStorage("showLyricsInNotifications") private var showLyricsInNotifications = false
    @AppStorage("showNewMusicNotifications") private var showNewMusicNotifications = true
    @AppStorage("defaultViewOnLaunch") private var defaultViewOnLaunch = SidebarItem.home.rawValue

    // Sidebar item visibility
    @AppStorage("showSidebarListen") private var showSidebarListen = true
    @AppStorage("showSidebarHome") private var showSidebarHome = true
    @AppStorage("showSidebarWaitingRoom") private var showSidebarWaitingRoom = true
    @AppStorage("showSidebarProjects") private var showSidebarProjects = true
    @AppStorage("showSidebarUnclassified") private var showSidebarUnclassified = true
    @AppStorage("showSidebarArtists") private var showSidebarArtists = true
    @AppStorage("showSidebarAlbums") private var showSidebarAlbums = true
    @AppStorage("showSidebarSongs") private var showSidebarSongs = true
    @AppStorage("showSidebarGenres") private var showSidebarGenres = true
    @AppStorage("showSidebarFolders") private var showSidebarFolders = true
    @AppStorage("showSidebarFavorites") private var showSidebarFavorites = true
    @AppStorage("showSidebarRecentlyAdded") private var showSidebarRecentlyAdded = true
    @AppStorage("showSidebarRecentlyPlayed") private var showSidebarRecentlyPlayed = true
    @AppStorage("showSidebarRadio") private var showSidebarRadio = true
    @AppStorage("showSidebarDownloads") private var showSidebarDownloads = true
    @AppStorage(FetcherContractSettings.isEnabledKey) private var enableFetcherSourceBrowser = false

    var body: some View {
        Form {
            Section("Launch") {
                Picker("Default View", selection: $defaultViewOnLaunch) {
                    Text("Listen").tag(SidebarItem.listen.rawValue)
                    Text("Home").tag(SidebarItem.home.rawValue)
                    Text("Waiting Room").tag(SidebarItem.waitingRoom.rawValue)
                    Text("Projects").tag(SidebarItem.projects.rawValue)
                    Text("Unclassified").tag(SidebarItem.unclassified.rawValue)
                    Text("Artists").tag(SidebarItem.artists.rawValue)
                    Text("Albums").tag(SidebarItem.albums.rawValue)
                    Text("Songs").tag(SidebarItem.songs.rawValue)
                    Text("Recently Added").tag(SidebarItem.recentlyAdded.rawValue)
                    Text("Recently Played").tag(SidebarItem.recentlyPlayed.rawValue)
                    if enableFetcherSourceBrowser {
                        Text("Sources").tag(SidebarItem.fetcherSources.rawValue)
                    }
                }

                Toggle("Start Minimized", isOn: $startMinimized)
            }

            Section("Notifications") {
                Toggle("Track Changes", isOn: $showNotifications)
                Toggle("Lyrics", isOn: $showLyricsInNotifications)
                    .disabled(!showNotifications)
                Toggle("New Music", isOn: $showNewMusicNotifications)
            }

            Section("Interface") {
                Toggle("Menu Bar Player", isOn: $showMenuBarPlayer)
            }

            Section {
                Toggle("Listen", isOn: $showSidebarListen)
                Toggle("Home", isOn: $showSidebarHome)
                Toggle("Waiting Room", isOn: $showSidebarWaitingRoom)
                Toggle("Projects", isOn: $showSidebarProjects)
                Toggle("Unclassified", isOn: $showSidebarUnclassified)
                Toggle("Artists", isOn: $showSidebarArtists)
                Toggle("Albums", isOn: $showSidebarAlbums)
                Toggle("Songs", isOn: $showSidebarSongs)
                Toggle("Genres", isOn: $showSidebarGenres)
                Toggle("Folders", isOn: $showSidebarFolders)
                Toggle("Liked Songs", isOn: $showSidebarFavorites)
                Toggle("Recently Added", isOn: $showSidebarRecentlyAdded)
                Toggle("Recently Played", isOn: $showSidebarRecentlyPlayed)
                Toggle("Radio", isOn: $showSidebarRadio)
                Toggle("Downloads", isOn: $showSidebarDownloads)
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Choose which items appear in the sidebar.")
                    .settingsDescription()
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Playback Settings

struct PlaybackSettingsView: View {
    @AppStorage("crossfadeDuration") private var crossfadeDuration = 0.0
    @AppStorage("autoPlayOnLaunch") private var autoPlayOnLaunch = false
    @AppStorage("rememberPlaybackPosition") private var rememberPlaybackPosition = true
    @AppStorage("streamingQuality") private var streamingQuality = TranscodingQuality.original.rawValue
    @AppStorage("replayGainMode") private var replayGainMode = "off"
    @AppStorage("lyricsAutoFetch") private var lyricsAutoFetch = true

    private var crossfadeLabel: String {
        if crossfadeDuration == 0 {
            return "Off"
        } else {
            return "\(Int(crossfadeDuration))s"
        }
    }

    var body: some View {
        Form {
            Section("Playback") {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Crossfade", value: crossfadeLabel)

                    Slider(value: $crossfadeDuration, in: 0...12, step: 1)
                }

                Text("Crossfade gradually blends one song into the next.")
                    .settingsDescription()
            }

            Section("Volume Normalization") {
                Picker("ReplayGain", selection: $replayGainMode) {
                    Text("Off").tag("off")
                    Text("Track").tag("track")
                    Text("Album").tag("album")
                }

                Text("Adjusts volume based on track/album loudness metadata to maintain consistent levels.")
                    .settingsDescription()
            }

            Section("Behavior") {
                Toggle("Autoplay on Launch", isOn: $autoPlayOnLaunch)
                Toggle("Remember Playback Position", isOn: $rememberPlaybackPosition)
            }

            Section("Lyrics") {
                Toggle("Fetch Lyrics Automatically", isOn: $lyricsAutoFetch)

                Text("Automatically search for lyrics when a song starts playing. Uses LRCLIB as external source.")
                    .settingsDescription()
            }

            Section("Streaming") {
                Picker("Streaming Quality", selection: $streamingQuality) {
                    ForEach(TranscodingQuality.allCases, id: \.rawValue) { quality in
                        Text(quality.rawValue).tag(quality.rawValue)
                    }
                }

                Text("Lower quality uses less bandwidth. Original streams files without transcoding.")
                    .settingsDescription()
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}


// MARK: - Library Settings

struct LibrarySettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("minArtistAlbumCount") private var minArtistAlbumCount = 1
    @AppStorage("minAlbumSongCount") private var minAlbumSongCount = 1
    @AppStorage("libraryMusicFolderId") private var libraryMusicFolderId = ""

    @State private var musicFolders: [MusicFolder] = []
    @State private var isLoadingFolders = false
    @State private var validationRequestId: String?
    @State private var duplicateRequestId: String?
    @State private var operationStatus: String?
    @State private var showHiddenItems = false
    @State private var isImporting = false
    @State private var importResult: AppleMusicImporter.ImportResult?
    @State private var importError: String?

    var body: some View {
        Form {
            Section {
                if isLoadingFolders {
                    LabeledContent("Music Folder") {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else if musicFolders.isEmpty {
                    LabeledContent("Music Folder", value: "No folders found")
                } else {
                    Picker("Music Folder", selection: $libraryMusicFolderId) {
                        Text("All Folders").tag("")
                        ForEach(musicFolders) { folder in
                            Text(folder.name).tag(folder.id)
                        }
                    }
                }
            } header: {
                Text("Library Scope")
            } footer: {
                Text("Only show albums and artists from the selected folder. Requires reloading the library.")
                    .settingsDescription()
            }

            // Library Management (requires companion service)
            if appState.companionServiceManager?.isAvailable == true {
                Section {
                    LabeledContent("Status") {
                        if appState.companionServiceManager?.isRunning == true {
                            Text("Running")
                                .foregroundStyle(.green)
                        } else {
                            Text("Available")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Validate Library...") {
                        requestValidateLibrary()
                    }

                    Button("Scan for Duplicates...") {
                        requestScanDuplicates()
                    }

                    if let status = operationStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Companion Service")
                } footer: {
                    Text("These operations use the companion service to scan your music files for issues or duplicates.")
                        .settingsDescription()
                }
            }

            Section("Filtering") {
                Picker("Min albums per artist", selection: $minArtistAlbumCount) {
                    ForEach(1...10, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }

                Picker("Min tracks per album", selection: $minAlbumSongCount) {
                    ForEach(1...10, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }

                Text("Hide artists or albums below these thresholds from library views.")
                    .settingsDescription()
            }

            Section("Import") {
                Button {
                    importAppleMusicLibrary()
                } label: {
                    HStack {
                        Label("Import Apple Music Library", systemImage: "square.and.arrow.down")
                        Spacer()
                        if isImporting {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }
                .disabled(isImporting)

                if let result = importResult {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Imported: \(result.matchedLiked) liked, \(result.matchedLoved) loved as local likes, \(result.matchedPlayHistory) play history")
                            .font(.caption)
                        if !result.unmatched.isEmpty {
                            Text("\(result.unmatched.count) tracks unmatched (not in navidrome)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = importError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Imports liked status, Apple Music Loved as local Resonance likes, and play history from ~/Music/Library.xml. This does not star songs on Navidrome.")
                    .settingsDescription()
            }

            Section("Hidden Items") {
                Button {
                    showHiddenItems = true
                } label: {
                    HStack {
                        Label("Manage Hidden Items", systemImage: "eye.slash")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                }

                Text("View and restore items you've hidden from your library.")
                    .settingsDescription()
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await loadFolders()
        }
        .sheet(isPresented: $showHiddenItems) {
            HiddenItemsView()
                .environment(appState)
                .frame(minWidth: 550, minHeight: 400)
        }
    }

    private func requestValidateLibrary() {
        guard let manager = appState.companionServiceManager else { return }
        do {
            let payload: [String: Any] = ["scan_all": true]
            let requestId = try manager.createRequest(type: "validate", payload: payload)
            validationRequestId = requestId
            operationStatus = "Validation requested..."
        } catch {
            operationStatus = "Failed to create validation request"
            print("Failed to request library validation: \(error)")
        }
    }

    private func requestScanDuplicates() {
        guard let manager = appState.companionServiceManager else { return }
        do {
            let payload: [String: Any] = ["scan_all": true]
            let requestId = try manager.createRequest(type: "fingerprint", payload: payload)
            duplicateRequestId = requestId
            operationStatus = "Duplicate scan requested..."
        } catch {
            operationStatus = "Failed to create duplicate scan request"
            print("Failed to request duplicate scan: \(error)")
        }
    }

    private func importAppleMusicLibrary() {
        let xmlPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music/Library.xml")
        guard FileManager.default.fileExists(atPath: xmlPath.path) else {
            importError = "Library.xml not found at ~/Music/Library.xml"
            return
        }
        guard let serverId = appState.activeServerId else {
            importError = "No active server"
            return
        }

        isImporting = true
        importError = nil
        importResult = nil

        let dbManager = appState.databaseManager
        Task.detached {
            let importer = AppleMusicImporter(databaseManager: dbManager)
            do {
                let result = try importer.importLibrary(xmlPath: xmlPath, serverId: serverId)
                await MainActor.run {
                    importResult = result
                    isImporting = false
                    appState.refreshLikedIds()
                }
            } catch {
                await MainActor.run {
                    importError = "Import failed: \(error.localizedDescription)"
                    isImporting = false
                }
            }
        }
    }

    private func loadFolders() async {
        isLoadingFolders = true
        do {
            musicFolders = try await appState.networkActor.fetchMusicFolders()
        } catch {
            print("Failed to load music folders: \(error)")
        }
        isLoadingFolders = false
    }
}

// MARK: - Cache Settings

struct CacheSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("maxCacheSize") private var maxCacheSize = 5.0 // GB
    // minutes, 0 = Manual Only. The unset default is registered by
    // LibraryRefreshScheduler, so this mirrors it rather than inventing one.
    @AppStorage(LibraryRefreshScheduler.intervalDefaultsKey)
    private var libraryRefreshInterval = LibraryRefreshScheduler.defaultIntervalMinutes

    @State private var cacheStats: CacheStats?
    @State private var isCalculating = false
    @State private var isClearing = false

    private var cacheLocationURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(PublicDemoConfiguration.appSupportDirectoryName)
    }

    private var cacheLocationLabel: String {
        cacheLocationURL?.path ?? "~/Library/Caches/Resonance Public"
    }

    var body: some View {
        Form {
            Section {
                Picker("Library Refresh", selection: $libraryRefreshInterval) {
                    Text("Manual Only").tag(0)
                    Text("Every 15 minutes").tag(15)
                    Text("Every 30 minutes").tag(30)
                    Text("Every hour").tag(60)
                    Text("Every 6 hours").tag(360)
                    Text("Daily").tag(1440)
                }
            } header: {
                Text("Library")
            } footer: {
                Text("How often to check for new music on the server. This is also what fills the New Music room — on Manual Only, arrivals are recorded only when you refresh there.")
                    .settingsDescription()
            }

            Section("Storage Usage") {
                if isCalculating {
                    HStack {
                        Text("Calculating...")
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                } else if let stats = cacheStats {
                    StorageRow(label: "Album Artwork", size: stats.artworkSize, icon: "photo", color: .blue)
                    StorageRow(label: "Playback Cache", size: stats.audioSize, icon: "music.note", color: .purple)
                    StorageRow(label: "Response Cache", size: stats.responseSize, icon: "doc.text", color: .gray)
                    StorageRow(label: "Offline Downloads", size: stats.downloadSize, icon: "arrow.down.circle", color: .green)

                    Divider()

                    HStack {
                        Text("Total Storage")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(stats.formattedTotalSize)
                            .fontWeight(.semibold)
                    }
                }
            }

            Section("Cache Limit") {
                Picker("Maximum Size", selection: $maxCacheSize) {
                    Text("1 GB").tag(1.0)
                    Text("2 GB").tag(2.0)
                    Text("5 GB").tag(5.0)
                    Text("10 GB").tag(10.0)
                    Text("20 GB").tag(20.0)
                    Text("50 GB").tag(50.0)
                    Text("Unlimited").tag(0.0)
                }

                if maxCacheSize > 0, let stats = cacheStats {
                    let used = Double(stats.totalSize) / (1024 * 1024 * 1024)
                    let percentage = min(used / maxCacheSize, 1.0)

                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: percentage)
                            .tint(percentage > 0.9 ? .orange : .accentColor)

                        Text("\(String(format: "%.1f", used)) GB of \(String(format: "%.0f", maxCacheSize)) GB used")
                            .settingsDescription()
                    }
                }
            }

            Section("Manage Storage") {
                Button {
                    Task {
                        await clearArtwork()
                    }
                } label: {
                    HStack {
                        Label("Clear Artwork Cache", systemImage: "photo")
                        Spacer()
                        if let stats = cacheStats {
                            Text(stats.formattedArtworkSize)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isClearing || cacheStats?.artworkSize == 0)

                Button {
                    Task {
                        await clearAudio()
                    }
                } label: {
                    HStack {
                        Label("Clear Playback Cache", systemImage: "music.note")
                        Spacer()
                        if let stats = cacheStats {
                            Text(stats.formattedAudioSize)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isClearing || cacheStats?.audioSize == 0)

                Button {
                    appState.selectedSidebarItem = .downloads
                } label: {
                    HStack {
                        Label("Manage Offline Downloads", systemImage: "arrow.down.circle")
                        Spacer()
                        if let stats = cacheStats {
                            Text(stats.formattedDownloadSize)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(cacheStats?.downloadSize == 0)

                Button(role: .destructive) {
                    Task {
                        await clearAllCache()
                    }
                } label: {
                    HStack {
                        Label("Clear All Cache", systemImage: "trash")
                        Spacer()
                        if isClearing {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }
                .disabled(isClearing || cacheStats?.cacheSize == 0)
            }

            Section("Cache Location") {
                LabeledContent("Location") {
                    Button {
                        if let cacheLocationURL {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cacheLocationURL.path)
                        }
                    } label: {
                        Text(cacheLocationLabel)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await refreshStats()
        }
    }

    private func refreshStats() async {
        isCalculating = true
        cacheStats = await appState.cacheActor.getCacheStats()
        isCalculating = false
    }

    private func clearArtwork() async {
        isClearing = true
        try? await appState.cacheActor.clearArtworkCache()
        await refreshStats()
        isClearing = false
    }

    private func clearAudio() async {
        isClearing = true
        try? await appState.cacheActor.clearAudioCache()
        await refreshStats()
        isClearing = false
    }

    private func clearAllCache() async {
        isClearing = true
        await appState.cacheActor.clearAll()
        await refreshStats()
        isClearing = false
    }
}

private struct StorageRow: View {
    let label: String
    let size: Int64
    let icon: String
    let color: Color

    private var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)

            Text(label)

            Spacer()

            Text(formattedSize)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Server Settings

struct ServerSettingsView: View {
    @Environment(AppState.self) private var appState

    private var connectionDescription: String {
        switch appState.connectionStatus {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Not connected"
        case .offline: return "Offline"
        case .error: return "Unreachable"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Library", value: appState.currentServer?.name ?? PublicDemoConfiguration.server.name)
                LabeledContent("Server", value: PublicDemoConfiguration.serverURL.absoluteString)
                LabeledContent("Status", value: connectionDescription)
            } header: {
                Label("Local Demo Server", systemImage: "lock.fill")
            } footer: {
                Text("This showcase build is permanently locked to the bundled demo server on this Mac (127.0.0.1, port 4534). Other servers, hosts, and redirects are rejected, and the server cannot be changed here.")
                    .settingsDescription()
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Keyboard Shortcuts

struct KeyboardShortcutsView: View {
    var body: some View {
        Form {
            Section("Playback") {
                ShortcutRow(action: "Play/Pause", shortcut: "Space")
                ShortcutRow(action: "Stop", shortcut: "⌘.")
                ShortcutRow(action: "Next Track", shortcut: "⌘→")
                ShortcutRow(action: "Previous Track", shortcut: "⌘←")
                ShortcutRow(action: "Volume Up", shortcut: "⌘↑")
                ShortcutRow(action: "Volume Down", shortcut: "⌘↓")
                ShortcutRow(action: "Toggle Shuffle", shortcut: "⌘S")
                ShortcutRow(action: "Cycle Repeat", shortcut: "⌘R")
            }

            Section("Navigation") {
                ShortcutRow(action: "Search", shortcut: "⌘F")
                ShortcutRow(action: "Show Queue", shortcut: "⌘U")
                ShortcutRow(action: "Show Lyrics", shortcut: "⌘L")
                ShortcutRow(action: "Mini Player", shortcut: "⌘⇧M")
                ShortcutRow(action: "Immersive Mode", shortcut: "⌘⇧F")
            }

            Section("File") {
                ShortcutRow(action: "New Playlist", shortcut: "⌘N")
                ShortcutRow(action: "Get Info", shortcut: "⌘I")
            }

            Section("Window") {
                ShortcutRow(action: "Minimize", shortcut: "⌘M")
                ShortcutRow(action: "Close Window", shortcut: "⌘W")
                ShortcutRow(action: "Settings", shortcut: "⌘,")
            }

            Section("Queue") {
                ShortcutRow(action: "Remove from Queue", shortcut: "Delete")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct ShortcutRow: View {
    let action: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(action)
            Spacer()
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary)
                .cornerRadius(4)
        }
    }
}

// MARK: - Appearance Settings

enum AppTheme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

enum AccentColorOption: String, CaseIterable {
    case blue = "Blue"
    case purple = "Purple"
    case pink = "Pink"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case graphite = "Graphite"

    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .graphite: return .gray
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("appTheme") private var appTheme = AppTheme.system.rawValue
    @AppStorage("accentColorOption") private var accentColorOption = AccentColorOption.blue.rawValue

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $appTheme) {
                    ForEach(AppTheme.allCases, id: \.rawValue) { theme in
                        Text(theme.rawValue).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("Match your system appearance or choose a specific theme.")
                    .settingsDescription()
            }

            Section("Accent Color") {
                Picker("Accent Color", selection: $accentColorOption) {
                    ForEach(AccentColorOption.allCases, id: \.rawValue) { option in
                        Label(option.rawValue, systemImage: "circle.fill")
                            .foregroundStyle(option.color)
                            .tag(option.rawValue)
                    }
                }

                Text("Choose your preferred accent color for buttons and highlights.")
                    .settingsDescription()
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("debugLoggingEnabled") private var debugLoggingEnabled = false
    @AppStorage("showDeveloperOptions") private var showDeveloperOptions = false
    @AppStorage(FetcherContractSettings.isEnabledKey) private var enableFetcherSourceBrowser = false
    @AppStorage(FetcherContractSettings.fixtureDirectoryKey) private var fetcherContractFixtureDirectory = ""

    @State private var showResetConfirmation = false

    private var cacheLocation: String {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let resonanceCache = cacheDir?.appendingPathComponent(PublicDemoConfiguration.appSupportDirectoryName)
        return resonanceCache?.path ?? "~/Library/Caches/Resonance Public"
    }

    var body: some View {
        Form {
            Section("Data Location") {
                LabeledContent("Cache") {
                    Button {
                        openCacheFolder()
                    } label: {
                        Text(cacheLocation)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                }

                LabeledContent("Preferences") {
                    Button {
                        openPreferencesFolder()
                    } label: {
                        Text("~/Library/Preferences")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
            }

            Section("Developer") {
                Toggle("Show Developer Options", isOn: $showDeveloperOptions)

                if showDeveloperOptions {
                    Button("Export Diagnostics") {
                        exportDiagnostics()
                    }

                    Button("Simulate Connection Error") {
                        appState.connectionStatus = .error(.serverUnreachable(URL(string: "http://localhost")!))
                    }
                }
            }

            Section {
                Toggle("Enable Fetcher Source Browser", isOn: $enableFetcherSourceBrowser)

                LabeledContent("Fixture Directory") {
                    HStack {
                        Text(fetcherFixtureDirectoryLabel)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Button("Choose...") {
                            chooseFetcherFixtureDirectory()
                        }
                    }
                }

                if !fetcherContractFixtureDirectory.isEmpty {
                    Button("Reveal Fixture Directory") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: fetcherContractFixtureDirectory)
                    }
                }
            } header: {
                Text("Fetcher Contract")
            } footer: {
                Text("Loads a local Fetcher JSON export as source evidence. Explicit candidate actions may stage Navidrome-matched songs in Resonance Waiting Room, but never write Fetcher state.")
                    .settingsDescription()
            }

            Section("Reset") {
                Button("Reset All Settings", role: .destructive) {
                    showResetConfirmation = true
                }

                Text("This will reset all preferences to their default values. Your server connection and library data will be preserved.")
                    .settingsDescription()
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Reset All Settings?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                resetAllSettings()
            }
        } message: {
            Text("This will reset all preferences to their default values. This action cannot be undone.")
        }
        .onChange(of: enableFetcherSourceBrowser) { _, isEnabled in
            guard !isEnabled else { return }
            if appState.selectedSidebarItem == .fetcherSources {
                appState.selectedSidebarItem = .home
            }
            if UserDefaults.standard.string(forKey: "defaultViewOnLaunch") == SidebarItem.fetcherSources.rawValue {
                UserDefaults.standard.set(SidebarItem.home.rawValue, forKey: "defaultViewOnLaunch")
            }
        }
    }

    private func openCacheFolder() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let resonanceCache = cacheDir?.appendingPathComponent(PublicDemoConfiguration.appSupportDirectoryName) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: resonanceCache.path)
        }
    }

    private func openPreferencesFolder() {
        let prefsPath = NSHomeDirectory() + "/Library/Preferences"
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: prefsPath)
    }

    private func exportDiagnostics() {
        // Collect diagnostic info
        let diagnostics = """
        Resonance Diagnostics Report
        Generated: \(Date())

        System Info:
        - macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        - App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")

        Connection Status: \(String(describing: appState.connectionStatus))
        Server: \(appState.currentServer?.url.absoluteString ?? "None")

        Library Stats:
        - Artists: \(appState.artists.count)
        - Albums: \(appState.albums.count)
        - Playlists: \(appState.playlists.count)

        Settings:
        - Debug Logging: \(debugLoggingEnabled)
        """

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "resonance-diagnostics.txt"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                try? diagnostics.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private var fetcherFixtureDirectoryLabel: String {
        fetcherContractFixtureDirectory.isEmpty ? "Not selected" : fetcherContractFixtureDirectory
    }

    private func chooseFetcherFixtureDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        if !fetcherContractFixtureDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: fetcherContractFixtureDirectory)
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            fetcherContractFixtureDirectory = url.path
        }
    }

    private func resetAllSettings() {
        // List of all settings keys to reset
        let settingsKeys = [
            "showMenuBarPlayer", "startMinimized", "showNotifications", "showLyricsInNotifications",
            "defaultViewOnLaunch", "showSidebarListen", "showSidebarHome", "showSidebarWaitingRoom",
            "showSidebarProjects", "showSidebarUnclassified",
            "showSidebarArtists", "showSidebarAlbums", "showSidebarSongs", "showSidebarGenres",
            "showSidebarFolders", "showSidebarFavorites", "showSidebarRecentlyAdded",
            "showSidebarRecentlyPlayed", "showSidebarRadio", "showSidebarDownloads",
            "crossfadeDuration", "autoPlayOnLaunch", "rememberPlaybackPosition",
            "streamingQuality", "soundCheckEnabled", "lyricsAutoFetch", "selectedEQPreset", "replayGainMode",
            "eq.enabled", "eq.presetId", "eq.customPresets",
            "maxCacheSize", "autoDownloadOnWifi", "libraryRefreshInterval",
            "appTheme", "accentColorOption", "showAlbumArtInSidebar", "useVibrantBackground",
            "showWaveformInNowPlaying", "debugLoggingEnabled", "showDeveloperOptions",
            "allowRemoteImages", "clearHistoryOnQuit",
            "minArtistAlbumCount", "minAlbumSongCount", "libraryMusicFolderId",
            FetcherContractSettings.isEnabledKey,
            FetcherContractSettings.fixtureDirectoryKey,
            ImportPolicyDefaults.autoAdmitNavidromeLibrary,
            ImportPolicyDefaults.stageServerImports,
            ImportPolicyDefaults.keepUnclassifiedOutOfLibrary,
            ImportPolicyDefaults.autoMarkPartialAuditions,
            ImportPolicyDefaults.autoMarkHeardAuditions
        ]

        for key in settingsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Force UI refresh
        UserDefaults.standard.synchronize()
    }
}

struct PrivacySettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("clearHistoryOnQuit") private var clearHistoryOnQuit = false

    @State private var showClearHistoryConfirmation = false
    @State private var showExportPanel = false

    var body: some View {
        Form {
            Section("Privacy") {
                HStack {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.green)
                    Text("Resonance does not collect telemetry")
                        .fontWeight(.medium)
                }
                Text("No analytics, no crash reports, no data sent anywhere. Your listening habits stay on your device.")
                    .settingsDescription()
            }

            Section("History") {
                Toggle("Clear History on Quit", isOn: $clearHistoryOnQuit)
                Text("Automatically clear play history when the app closes.")
                    .settingsDescription()

                Button("Clear Play History Now...") {
                    showClearHistoryConfirmation = true
                }
                .confirmationDialog("Clear Play History?", isPresented: $showClearHistoryConfirmation) {
                    Button("Clear History", role: .destructive) {
                        clearPlayHistory()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently delete your listening history. This action cannot be undone.")
                }
            }

            Section("Data") {
                Button("Export My Data...") {
                    exportUserData()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func clearPlayHistory() {
        try? appState.databaseManager.write { db in
            try db.execute(sql: "DELETE FROM play_history")
        }
    }

    private func exportUserData() {
        Task {
            let history = (try? appState.databaseManager.loadPlayHistory(limit: 10000)) ?? []

            let exportData: [String: Any] = [
                "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "playHistory": history.map { item in
                    [
                        "songId": item.songId,
                        "title": item.title,
                        "artist": item.artist,
                        "album": item.album,
                        "playedAt": ISO8601DateFormatter().string(from: item.playedAt)
                    ]
                }
            ]

            await MainActor.run {
                if let jsonData = try? JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted) {
                    let savePanel = NSSavePanel()
                    savePanel.allowedContentTypes = [.json]
                    savePanel.nameFieldStringValue = "resonance-data-export.json"

                    if savePanel.runModal() == .OK, let url = savePanel.url {
                        try? jsonData.write(to: url)
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
