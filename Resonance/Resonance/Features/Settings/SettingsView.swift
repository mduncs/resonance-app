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
    @AppStorage("showSidebarNewMusic") private var showSidebarNewMusic = true
    @AppStorage("showSidebarRadio") private var showSidebarRadio = true
    @AppStorage("showSidebarDownloads") private var showSidebarDownloads = true

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
                }

                Toggle("Start Minimized", isOn: $startMinimized)
            }

            Section("Notifications") {
                Toggle("When song changes", isOn: $showNotifications)
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
                Toggle("New Music", isOn: $showSidebarNewMusic)
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
    @Environment(AppState.self) private var appState
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

                Text("Automatically look up lyrics on the library server when a song starts playing. This build does not use an external lyrics service.")
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
        .onChange(of: crossfadeDuration) { _, duration in
            Task { await appState.audioActor.setCrossfadeDuration(duration) }
        }
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
    @State private var musicFoldersError: String?
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
                } else if let musicFoldersError {
                    LabeledContent("Music Folder") {
                        HStack(spacing: 8) {
                            Text("Couldn't load folders")
                                .foregroundStyle(.red)
                            Button("Retry") {
                                Task { await loadFolders() }
                            }
                            .disabled(isLoadingFolders)
                        }
                    }
                    Text(musicFoldersError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
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
                            .foregroundStyle(
                                status.localizedCaseInsensitiveContains("failed") ? Color.red : Color.secondary
                            )
                            .textSelection(.enabled)
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
        guard let manager = appState.companionServiceManager else {
            operationStatus = "Companion service is unavailable."
            return
        }
        do {
            let payload: [String: Any] = ["scan_all": true]
            let requestId = try manager.createRequest(type: "validate", payload: payload)
            validationRequestId = requestId
            operationStatus = "Validation requested..."
        } catch {
            operationStatus = "Failed to request library validation: \(error.localizedDescription)"
        }
    }

    private func requestScanDuplicates() {
        guard let manager = appState.companionServiceManager else {
            operationStatus = "Companion service is unavailable."
            return
        }
        do {
            let payload: [String: Any] = ["scan_all": true]
            let requestId = try manager.createRequest(type: "fingerprint", payload: payload)
            duplicateRequestId = requestId
            operationStatus = "Duplicate scan requested..."
        } catch {
            operationStatus = "Failed to request duplicate scan: \(error.localizedDescription)"
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
        musicFoldersError = nil
        defer { isLoadingFolders = false }
        do {
            musicFolders = try await appState.networkActor.fetchMusicFolders()
        } catch {
            musicFolders = []
            musicFoldersError = "Music folders couldn't be loaded: \(error.localizedDescription)"
        }
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
    @State private var cacheClearError: String?

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

            Section("Playback Cache Limit") {
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
                    let used = Double(stats.audioSize) / (1024 * 1024 * 1024)
                    let percentage = min(used / maxCacheSize, 1.0)

                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: percentage)
                            .tint(percentage > 0.9 ? .orange : .accentColor)

                        Text("\(String(format: "%.1f", used)) GB of \(String(format: "%.0f", maxCacheSize)) GB used")
                            .settingsDescription()
                    }
                }
            }

            Text("The limit applies to cached playback audio, not offline downloads or artwork. Playback cache is trimmed as new audio is cached.")
                .settingsDescription()

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

            if let cacheClearError {
                Label(cacheClearError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
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
        .onChange(of: maxCacheSize) { _, gigabytes in
            Task {
                await appState.cacheActor.setMaxAudioCacheSize(
                    CacheActor.audioCacheLimitBytes(gigabytes: gigabytes)
                )
            }
        }
    }

    private func refreshStats() async {
        isCalculating = true
        cacheStats = await appState.cacheActor.getCacheStats()
        isCalculating = false
    }

    private func clearArtwork() async {
        guard !isClearing else { return }
        isClearing = true
        cacheClearError = nil
        defer { isClearing = false }
        do {
            try await appState.cacheActor.clearArtworkCache()
        } catch {
            cacheClearError = "Couldn't clear artwork cache: \(error.localizedDescription) Some files may already have been removed."
        }
        await refreshStats()
    }

    private func clearAudio() async {
        guard !isClearing else { return }
        isClearing = true
        cacheClearError = nil
        defer { isClearing = false }
        do {
            try await appState.cacheActor.clearAudioCache()
        } catch {
            cacheClearError = "Couldn't clear playback cache: \(error.localizedDescription) Some files may already have been removed."
        }
        await refreshStats()
    }

    private func clearAllCache() async {
        guard !isClearing else { return }
        isClearing = true
        cacheClearError = nil
        defer { isClearing = false }
        do {
            try await appState.cacheActor.clearAll()
        } catch {
            cacheClearError = "Couldn't clear all cache: \(error.localizedDescription) Some files may already have been removed."
        }
        await refreshStats()
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
                ShortcutRow(action: "Seek Back", shortcut: "←")
                ShortcutRow(action: "Seek Forward", shortcut: "→")
                ShortcutRow(action: "Volume Up", shortcut: "⌘↑")
                ShortcutRow(action: "Volume Down", shortcut: "⌘↓")
                ShortcutRow(action: "Toggle Shuffle", shortcut: "⌘S")
                ShortcutRow(action: "Cycle Repeat", shortcut: "⌘R")
            }

            Section("Curation") {
                ShortcutRow(action: "Curation Command…", shortcut: "⌘K")
                ShortcutRow(action: "Admit Current Song", shortcut: "⇧⌘A")
                ShortcutRow(action: "Mark Interesting", shortcut: "⇧⌘G")
                ShortcutRow(action: "Love Current Song", shortcut: "⇧⌘L")
                ShortcutRow(action: "Add to Playlist…", shortcut: "⇧⌘P")
            }

            Section("Navigation") {
                ShortcutRow(action: "Search", shortcut: "⌘F")
                ShortcutRow(action: "Show Queue", shortcut: "⌘U")
                ShortcutRow(action: "Show Lyrics", shortcut: "⌘L")
                ShortcutRow(action: "Toggle Sidebar", shortcut: "⌘\\")
                ShortcutRow(action: "Mini Player", shortcut: "⇧⌘M")
                ShortcutRow(action: "Immersive Mode", shortcut: "⇧⌘F")
            }

            Section("File") {
                ShortcutRow(action: "New Playlist", shortcut: "⌘N")
            }

            Section("Song") {
                ShortcutRow(action: "Get Info", shortcut: "⌘I")
            }

            Section("Window") {
                ShortcutRow(action: "Minimize", shortcut: "⌘M")
                ShortcutRow(action: "Close Window", shortcut: "⌘W")
                ShortcutRow(action: "Settings", shortcut: "⌘,")
            }

            Section("Queue") {
                ShortcutRow(action: "Remove Selected from Queue", shortcut: "Delete")
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

    @State private var showResetConfirmation = false
    @State private var isExportingDiagnostics = false
    @State private var diagnosticsExportMessage: String?
    @State private var diagnosticsExportFailed = false

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
                    Button(isExportingDiagnostics ? "Exporting Diagnostics…" : "Export Diagnostics") {
                        exportDiagnostics()
                    }
                    .disabled(isExportingDiagnostics)

                    if let diagnosticsExportMessage {
                        Label(
                            diagnosticsExportMessage,
                            systemImage: diagnosticsExportFailed ? "exclamationmark.triangle" : "checkmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(diagnosticsExportFailed ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                    }

                    Button("Simulate Connection Error") {
                        appState.connectionStatus = .error(.serverUnreachable(URL(string: "http://localhost")!))
                    }
                }
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
        guard !isExportingDiagnostics else { return }
        isExportingDiagnostics = true
        diagnosticsExportMessage = nil
        diagnosticsExportFailed = false

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
        - Admitted Albums: \(appState.admittedAlbumIds.subtracting(appState.hiddenAlbumIds).count)
        - Playlists: \(appState.playlists.count)

        Settings:
        - Debug Logging: \(debugLoggingEnabled)
        """

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "resonance-diagnostics.txt"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else {
                isExportingDiagnostics = false
                return
            }

            do {
                try diagnostics.write(to: url, atomically: true, encoding: .utf8)
                diagnosticsExportMessage = "Diagnostics saved as \(url.lastPathComponent)."
            } catch {
                diagnosticsExportFailed = true
                diagnosticsExportMessage = "Couldn't save diagnostics: \(error.localizedDescription)"
            }
            isExportingDiagnostics = false
        }
    }

    private func resetAllSettings() {
        // List of all settings keys to reset
        let settingsKeys = [
            "showMenuBarPlayer", "startMinimized", "showNotifications", "showLyricsInNotifications",
            "showNewMusicNotifications", SettingsTab.storageKey, "defaultViewOnLaunch",
            "showSidebarListen", "showSidebarHome", "showSidebarWaitingRoom",
            "showSidebarProjects", "showSidebarUnclassified",
            "showSidebarArtists", "showSidebarAlbums", "showSidebarSongs", "showSidebarGenres",
            "showSidebarFolders", "showSidebarFavorites", "showSidebarNewMusic", "showSidebarRecentlyAdded",
            "showSidebarRecentlyPlayed", "showSidebarRadio", "showSidebarDownloads",
            "crossfadeDuration", "autoPlayOnLaunch", "rememberPlaybackPosition",
            "streamingQuality", "soundCheckEnabled", "lyricsAutoFetch", "replayGainMode",
            "maxCacheSize", "autoDownloadOnWifi", "libraryRefreshInterval",
            "appTheme", "accentColorOption", "showAlbumArtInSidebar", "useVibrantBackground",
            "showWaveformInNowPlaying", "debugLoggingEnabled", "showDeveloperOptions",
            "allowRemoteImages", "clearHistoryOnQuit",
            "minArtistAlbumCount", "minAlbumSongCount", "libraryMusicFolderId",
            "artistLayoutStyle", "genreLayoutStyle", "foldersRootLayoutStyle", "folderDetailLayoutStyle",
            "sidebarCollapsedGroups", "sidebarWidth", "songsColumnCustomization", "miniPlayerMode",
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

        // Settings changes are persisted immediately, but the live actors keep
        // their applied values. Re-apply the registered defaults now instead
        // of leaving Reset All effective only after relaunch.
        let crossfadeDuration = UserDefaults.standard.double(forKey: "crossfadeDuration")
        let maxCacheSizeGB = (UserDefaults.standard.object(forKey: "maxCacheSize") as? Double) ?? 5.0
        Task {
            await appState.audioActor.setCrossfadeDuration(crossfadeDuration)
            await appState.cacheActor.setMaxAudioCacheSize(
                CacheActor.audioCacheLimitBytes(gigabytes: maxCacheSizeGB)
            )
        }
    }
}

struct PrivacySettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("clearHistoryOnQuit") private var clearHistoryOnQuit = false

    @State private var showClearHistoryConfirmation = false
    @State private var isClearingHistory = false
    @State private var isExportingUserData = false
    @State private var historyActionMessage: String?
    @State private var historyActionFailed = false

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
                .disabled(isClearingHistory)
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
                Button(isExportingUserData ? "Preparing Export…" : "Export My Data…") {
                    exportUserData()
                }
                .disabled(isExportingUserData)
            }

            if let historyActionMessage {
                Label(
                    historyActionMessage,
                    systemImage: historyActionFailed ? "exclamationmark.triangle" : "checkmark.circle"
                )
                .foregroundStyle(historyActionFailed ? Color.red : Color.secondary)
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func clearPlayHistory() {
        guard !isClearingHistory else { return }
        isClearingHistory = true
        historyActionMessage = nil
        historyActionFailed = false
        let databaseManager = appState.databaseManager

        Task.detached {
            do {
                try databaseManager.write { db in
                    try db.execute(sql: "DELETE FROM play_history")
                }
                await MainActor.run {
                    isClearingHistory = false
                    historyActionMessage = "Play history cleared."
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    isClearingHistory = false
                    historyActionFailed = true
                    historyActionMessage = "Couldn't clear play history: \(message)"
                }
            }
        }
    }

    private func exportUserData() {
        guard !isExportingUserData else { return }
        isExportingUserData = true
        historyActionMessage = nil
        historyActionFailed = false
        let databaseManager = appState.databaseManager

        Task.detached {
            do {
                let history = try databaseManager.loadPlayHistory(limit: 10000)
                let formatter = ISO8601DateFormatter()
                let exportData: [String: Any] = [
                    "exportedAt": formatter.string(from: Date()),
                    "playHistory": history.map { item in
                        [
                            "songId": item.songId,
                            "title": item.title,
                            "artist": item.artist,
                            "album": item.album,
                            "playedAt": formatter.string(from: item.playedAt)
                        ]
                    }
                ]
                let jsonData = try JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted)
                await MainActor.run {
                    presentUserDataSavePanel(with: jsonData)
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    isExportingUserData = false
                    historyActionFailed = true
                    historyActionMessage = "Couldn't prepare data export: \(message)"
                }
            }
        }
    }

    private func presentUserDataSavePanel(with jsonData: Data) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "resonance-data-export.json"
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else {
                isExportingUserData = false
                return
            }

            Task.detached {
                do {
                    try jsonData.write(to: url, options: .atomic)
                    await MainActor.run {
                        isExportingUserData = false
                        historyActionFailed = false
                        historyActionMessage = "Data export saved as \(url.lastPathComponent)."
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        isExportingUserData = false
                        historyActionFailed = true
                        historyActionMessage = "Couldn't save data export: \(message)"
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
