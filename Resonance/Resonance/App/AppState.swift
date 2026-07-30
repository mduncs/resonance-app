import SwiftUI
import Security
import Combine

enum PublicDemoConfiguration {
    static let appSupportDirectoryName = "Resonance Public"
    static let keychainService = "com.resonance.public.server"
    static let serverURL = URL(string: "http://127.0.0.1:4534")!
    static let serverUsername = "admin"
    static let serverPassword = "demo"
    static let serverID = UUID(uuidString: "9D8F5E31-E989-4B4E-884A-C4AB431621D4")!
    static var isReadOnly: Bool { true }
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.processName.hasSuffix("xctest")
            || NSClassFromString("XCTestCase") != nil
    }

    static var server: Server {
        Server(
            id: serverID,
            name: "Forty",
            url: serverURL,
            username: serverUsername
        )
    }

    static func allowsNetworkURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "http",
              url.host?.lowercased() == "127.0.0.1",
              (url.port ?? 80) == 4534,
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }
}

enum FeedbackStyle: Sendable {
    case success
    case info
    case warning
    case error
}

struct AppFeedback: Identifiable {
    let id = UUID()
    let message: String
    let detail: String?
    let style: FeedbackStyle
    let systemImage: String
    let actionTitle: String?
    let action: (() -> Void)?
}

@MainActor
@Observable
final class AppState {
    private static let serversStorageKey = "servers"
    private static let persistedPlaybackKey = "persistedPlayback"
    private static let serverPasswordService = PublicDemoConfiguration.keychainService

    // MARK: - Server
    var servers: [Server] = []
    var activeServer: Server?
    var connectionStatus: ConnectionStatus = .disconnected

    /// Alias for activeServer - used by views and settings
    var currentServer: Server? {
        get { activeServer }
        set { activeServer = newValue }
    }

    /// Persisted onboarding completion state
    var isOnboardingComplete = UserDefaults.standard.bool(forKey: "isOnboardingComplete") {
        didSet { UserDefaults.standard.set(isOnboardingComplete, forKey: "isOnboardingComplete") }
    }

    /// Save current server to UserDefaults
    func saveServer(_ server: Server, password: String) throws {
        try persistServerConfiguration(server, password: password)
    }

    /// Load password from keychain for server
    func loadPassword(for server: Server) -> String? {
        if let password = copyPassword(for: server, storage: .dataProtection) {
            return password
        }

        guard let legacyPassword = copyPassword(for: server, storage: .legacy) else {
            return nil
        }

        // Older debug builds wrote to the legacy macOS keychain, which can prompt
        // after rebuilds. Move it forward once we successfully read it.
        try? storePassword(for: server, password: legacyPassword)
        return legacyPassword
    }

    func applyServerConfiguration(
        urlString: String,
        username: String,
        password: String
    ) async throws -> Server {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme, !scheme.isEmpty,
              url.host != nil else {
            throw ResonanceError.invalidURL
        }
        guard PublicDemoConfiguration.allowsNetworkURL(url) else {
            throw ResonanceError.publicDemoRequiresLocalServer
        }

        let existingServer = activeServer ?? servers.first
        let draftServer = Server(
            id: existingServer?.id ?? UUID(),
            name: existingServer?.name ?? "Navidrome",
            url: url,
            username: trimmedUsername
        )

        let response = try await networkActor.ping(server: draftServer, password: password)
        let updatedServer = Server(
            id: draftServer.id,
            name: response.serverName,
            url: url,
            username: trimmedUsername
        )

        try persistServerConfiguration(updatedServer, password: password)
        await networkActor.configure(server: updatedServer, password: password)

        connectionStatus = .connected
        playbackManager.activeServerId = updatedServer.id.uuidString
        isOnboardingComplete = true

        return updatedServer
    }

    func disconnectServer() async throws {
        var savedServers = servers
        if let activeServer,
           !savedServers.contains(where: { $0.id == activeServer.id }) {
            savedServers.insert(activeServer, at: 0)
        }
        var cleanupError: Error?

        for server in savedServers {
            do {
                try removePassword(for: server)
            } catch {
                cleanupError = cleanupError ?? error
            }
        }

        await playbackManager.stop()
        await networkActor.resetConfiguration()

        servers = []
        activeServer = nil
        connectionStatus = .disconnected
        artists = []
        albums = []
        playlists = []
        smartPlaylists = []
        unseenDiscoveryCount = 0
        unclassifiedCount = 0
        hiddenSongIds = []
        hiddenAlbumIds = []
        hiddenArtistIds = []
        likedSongIds = []
        admittedSongIds = []
        admittedAlbumIds = []
        admittedArtistIds = []
        nowPlaying = nil
        currentTime = 0
        duration = 0
        selectedSidebarItem = .home
        detailNavigationPath = NavigationPath()
        navigationTargetAlbumId = nil
        navigationTargetArtistId = nil
        navigationTargetSongId = nil
        selectedQueueItemId = nil
        pendingQueueRestore = nil
        undoToastMessage = nil
        undoToastAction = nil
        playbackManager.activeServerId = ""

        UserDefaults.standard.removeObject(forKey: Self.serversStorageKey)
        UserDefaults.standard.removeObject(forKey: Self.persistedPlaybackKey)

        if let cleanupError {
            throw cleanupError
        }
    }

    func showFeedback(
        message: String,
        detail: String? = nil,
        style: FeedbackStyle = .info,
        systemImage: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        autoDismissAfter duration: Duration? = .seconds(4)
    ) {
        feedbackDismissTask?.cancel()

        let feedback = AppFeedback(
            message: message,
            detail: detail,
            style: style,
            systemImage: systemImage,
            actionTitle: actionTitle,
            action: action
        )
        self.feedback = feedback

        guard let duration else { return }
        let feedbackID = feedback.id

        feedbackDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self?.feedback?.id == feedbackID else { return }
                self?.feedback = nil
                self?.feedbackDismissTask = nil
            }
        }
    }

    func dismissFeedback() {
        feedbackDismissTask?.cancel()
        feedbackDismissTask = nil
        feedback = nil
    }

    // MARK: - Library (fetched from server, cached locally)
    var artists: [Artist] = []
    var albums: [Album] = []
    var playlists: [Playlist] = []
    var smartPlaylists: [SmartPlaylist] = []
    var unseenDiscoveryCount: Int = 0
    var unclassifiedCount: Int = 0

    // MARK: - Hidden Items (cached for fast filtering across all views)
    private(set) var hiddenSongIds: Set<String> = []
    private(set) var hiddenAlbumIds: Set<String> = []
    private(set) var hiddenArtistIds: Set<String> = []

    /// Call after hiding/unhiding to keep cached sets in sync
    func refreshHiddenIds() {
        guard let serverId = activeServerId else { return }
        hiddenSongIds = (try? databaseManager.loadHiddenIds(type: "song", serverId: serverId)) ?? []
        hiddenAlbumIds = (try? databaseManager.loadHiddenIds(type: "album", serverId: serverId)) ?? []
        hiddenArtistIds = (try? databaseManager.loadHiddenIds(type: "artist", serverId: serverId)) ?? []
    }

    // MARK: - Liked Items (Resonance-only, cached for fast UI checks)
    private(set) var likedSongIds: Set<String> = []

    /// Call after liking/unliking to keep cached set in sync
    func refreshLikedIds() {
        guard let serverId = activeServerId else { return }
        likedSongIds = (try? databaseManager.loadLikedIds(type: "song", serverId: serverId)) ?? []
    }

    // MARK: - Library Membership (local admission boundary)
    private(set) var admittedSongIds: Set<String> = []
    private(set) var admittedAlbumIds: Set<String> = []
    private(set) var admittedArtistIds: Set<String> = []

    /// Call after admit/reject operations to keep pristine library filters in sync.
    func refreshLibraryMembershipIds() {
        guard let serverId = activeServerId else { return }
        admittedSongIds = (try? databaseManager.loadLibraryMemberIds(type: .song, serverId: serverId)) ?? []
        admittedAlbumIds = (try? databaseManager.loadLibraryMemberIds(type: .album, serverId: serverId)) ?? []
        admittedArtistIds = (try? databaseManager.loadLibraryMemberIds(type: .artist, serverId: serverId)) ?? []
        unclassifiedCount = (try? databaseManager.unclassifiedUndecidedCount(serverId: serverId)) ?? 0
    }

    // MARK: - Playback
    var nowPlaying: Song?
    var playbackState: PlaybackState = .stopped
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0

    /// Alias for duration - used by SeekBar
    var currentDuration: TimeInterval { duration }
    var volume: Float = 1.0 {
        didSet { Task { await audioActor.setVolume(volume) } }
    }
    /// Shuffle state - delegates to QueueManager as single source of truth
    var shuffleEnabled: Bool {
        get { queueManager.isShuffleEnabled }
        set {
            if newValue != queueManager.isShuffleEnabled {
                queueManager.toggleShuffle()
            }
        }
    }

    // MARK: - UI State
    var selectedSidebarItem: SidebarItem = .home
    var searchQuery: String = ""
    var isLyricsPanelVisible: Bool = false
    var isQueueVisible: Bool = false
    /// Trigger to focus the search field (set to true, observed by SearchField, auto-resets)
    var shouldFocusSearch: Bool = false

    // MARK: - AutoPlay (continues playing similar songs when queue ends)
    /// Persisted autoplay toggle - when enabled, plays similar songs after queue ends
    var isAutoPlayEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "isAutoPlayEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "isAutoPlayEnabled") }
    }

    // MARK: - Sheet State
    var showCreatePlaylistSheet = false
    var createPlaylistSongIds: [String] = []
    var editPlaylistTarget: Playlist?
    var getInfoContent: GetInfoContent?
    var showSimilarSongsSheet = false
    var similarSongsSeedSong: Song?
    var deletePlaylistTarget: Playlist?
    var showSmartPlaylistEditor = false
    var editSmartPlaylistTarget: SmartPlaylist?
    /// Global ⌘K Command HUD (Quick Capture Command Layer) — rendered as a
    /// ContentView overlay over any surface.
    var isCommandHUDVisible = false
    // MARK: - Delete confirmation
    var deleteConfirmSong: Song?
    var deleteConfirmAlbum: (album: Album, songs: [Song])?
    // MARK: - Undo toast
    var undoToastMessage: String?
    var undoToastAction: (() -> Void)?
    // MARK: - Operation feedback
    var feedback: AppFeedback?
    // MARK: - Queue Selection (for Delete key handling)
    var selectedQueueItemId: UUID?

    // MARK: - Navigation
    /// Navigation path for detail view - used by NavigationStack
    var detailNavigationPath = NavigationPath()
    /// Set to navigate to an album from context menu (processed by DetailView)
    var navigationTargetAlbumId: String?
    /// Set to navigate to an artist from context menu (processed by DetailView)
    var navigationTargetArtistId: String?
    /// Set to highlight a specific song when navigating to an album (from NowPlayingBar)
    var navigationTargetSongId: String?

    // MARK: - Managers
    let playbackManager: PlaybackManager
    let queueManager: QueueManager
    let networkMonitor: NetworkMonitor

    // MARK: - Actors
    let audioActor: AudioActor
    let networkActor: NetworkActor
    let cacheActor: CacheActor

    // MARK: - Services
    let lyricsService: LyricsService
    private(set) var libraryRefreshScheduler: LibraryRefreshScheduler!
    private(set) var trashManager: TrashManager!

    // MARK: - Database
    let databaseManager: DatabaseManager

    // MARK: - Companion Service
    private(set) var companionServiceManager: CompanionServiceManager?

    /// Convenience: active server ID string for database operations
    var activeServerId: String? { activeServer?.id.uuidString }

    // MARK: - Pins (local-only, max 10)
    var pinnedItems: [PinnedItem] = [] {
        didSet { persistPins() }
    }
    private static let maxPins = 10
    private static let pinsKey = "pinnedItems"

    // MARK: - Emotion Engine
    var dominantColor: Color = .accentColor
    var secondaryColor: Color = .secondary

    // MARK: - Private
    private var cancellables = Set<AnyCancellable>()
    private var pendingQueueRestore: PersistedPlaybackState?
    private var feedbackDismissTask: Task<Void, Never>?

    private enum KeychainStorage {
        case dataProtection
        case legacy
    }

    init() {
        self.audioActor = AudioActor()
        self.networkActor = NetworkActor()
        self.cacheActor = CacheActor()
        self.networkMonitor = NetworkMonitor()
        self.queueManager = QueueManager()
        self.lyricsService = LyricsService(networkActor: networkActor, cacheActor: cacheActor)

        // Initialize GRDB database (replaces SwiftData, LibraryCache, PlayHistoryStore)
        do {
            self.databaseManager = try DatabaseManager()
        } catch {
            fatalError("Could not create DatabaseManager: \(error)")
        }

        self.companionServiceManager = CompanionServiceManager(databaseManager: databaseManager)

        let trashMgr = TrashManager(networkActor: networkActor, databaseManager: databaseManager)
        self.trashManager = trashMgr

        self.playbackManager = PlaybackManager(
            audioActor: audioActor,
            networkActor: networkActor,
            cacheActor: cacheActor,
            queueManager: queueManager,
            databaseManager: databaseManager,
            lyricsService: lyricsService
        )

        // Wire up trash manager callbacks
        trashMgr.onUndoAvailable = { [weak self] info in
            self?.undoToastMessage = info.message
            self?.undoToastAction = info.action
        }
        trashMgr.onUndoDismissed = { [weak self] in
            self?.undoToastMessage = nil
            self?.undoToastAction = nil
        }

        // Wire up response caching
        Task { await networkActor.setCacheActor(cacheActor) }

        // Apply user's cache size limit setting
        Task {
            let maxCacheSizeGB = UserDefaults.standard.double(forKey: "maxCacheSize")
            if maxCacheSizeGB > 0 {
                let maxCacheSizeBytes = Int64(maxCacheSizeGB * 1024 * 1024 * 1024)
                await cacheActor.setMaxAudioCacheSize(maxCacheSizeBytes)
            }
        }

        // Apply user's crossfade setting
        Task {
            let crossfadeDuration = UserDefaults.standard.double(forKey: "crossfadeDuration")
            await audioActor.setCrossfadeDuration(crossfadeDuration)
        }

        // Wire up download handler for CacheActor
        Task {
            await cacheActor.setDownloadHandler { [weak self] songId, serverId in
                guard let self else { throw ResonanceError.notConfigured }
                let streamURL = try await self.networkActor.streamURL(for: songId)
                let data = try await self.networkActor.downloadData(from: streamURL)
                // Determine suffix from content type or default to mp3
                let suffix = "mp3"  // Default, could be improved with content-type detection
                return (data, suffix)
            }
        }

        loadPersistedState()
        loadPins()
        setupBindings()

        // Load default view on launch
        if let defaultView = UserDefaults.standard.string(forKey: "defaultViewOnLaunch"),
           let sidebarItem = SidebarItem(rawValue: defaultView) {
            if sidebarItem == .fetcherSources &&
                !UserDefaults.standard.bool(forKey: FetcherContractSettings.isEnabledKey) {
                selectedSidebarItem = .home
            } else {
                selectedSidebarItem = sidebarItem
            }
        }
        checkDevMode()

        // Start library auto-refresh scheduler
        self.libraryRefreshScheduler = LibraryRefreshScheduler(appState: self)
    }

    /// Dev mode: auto-configure from environment variables
    /// Set RESONANCE_SERVER_URL, RESONANCE_USERNAME, RESONANCE_PASSWORD
    private func checkDevMode() {
        guard let urlString = ProcessInfo.processInfo.environment["RESONANCE_SERVER_URL"],
              let username = ProcessInfo.processInfo.environment["RESONANCE_USERNAME"],
              let password = ProcessInfo.processInfo.environment["RESONANCE_PASSWORD"],
              let url = URL(string: urlString),
              PublicDemoConfiguration.allowsNetworkURL(url) else {
            return
        }

        // Dev mode: skip onboarding immediately (before async connection)
        isOnboardingComplete = true

        let server = Server(name: "Dev Server", url: url, username: username)
        activeServer = server
        connectionStatus = .connecting

        Task {
            await networkActor.configure(server: server, password: password)
            do {
                _ = try await networkActor.ping()
                connectionStatus = .connected
            } catch {
                connectionStatus = .error(.serverUnreachable(url))
            }
        }
    }

    private func loadPersistedState() {
        // The public showcase is deliberately pinned to its loopback-only demo
        // server. It never reads a persisted server list or credentials from the
        // private Resonance installation.
        if !PublicDemoConfiguration.isRunningTests {
            let server = PublicDemoConfiguration.server
            servers = [server]
            activeServer = server
            isOnboardingComplete = true
            loadCachedLibrary(serverId: server.id.uuidString)
            playbackManager.activeServerId = server.id.uuidString

            Task {
                await networkActor.configure(
                    server: server,
                    password: PublicDemoConfiguration.serverPassword
                )
                await connect()
            }
        }

        // Restore last queue (just song IDs, don't auto-play)
        if let data = UserDefaults.standard.data(forKey: Self.persistedPlaybackKey),
           let persisted = try? JSONDecoder().decode(PersistedPlaybackState.self, from: data) {
            // Store for restoration after library loads
            pendingQueueRestore = persisted
        }
    }

    /// Restore persisted queue using stored song data
    /// Call this after app launch / library loads
    func restorePersistedQueue() {
        guard let persisted = pendingQueueRestore else { return }
        pendingQueueRestore = nil

        // Use stored songs directly (no network fetch needed), but do not restore
        // content that has since been hidden.
        let restoredSongs = visibleSongsForPlayback(persisted.queueSongs)
        guard !restoredSongs.isEmpty else { return }

        let originalStartIndex = min(persisted.queueIndex, persisted.queueSongs.count - 1)
        let originalStartSongId = persisted.queueSongs[originalStartIndex].id
        let startIndex = restoredSongs.firstIndex { $0.id == originalStartSongId }
            ?? min(originalStartIndex, restoredSongs.count - 1)
        let rememberPosition = UserDefaults.standard.bool(forKey: "rememberPlaybackPosition")
        Task {
            await playbackManager.play(songs: restoredSongs, startingAt: startIndex)
            // Seek to saved position if we're on the same track and setting is enabled
            if restoredSongs[startIndex].id == originalStartSongId && rememberPosition && persisted.lastPosition > 0 {
                await playbackManager.seek(to: persisted.lastPosition)
            }
            // Only auto-play if setting is enabled, otherwise pause
            if !UserDefaults.standard.bool(forKey: "autoPlayOnLaunch") {
                await playbackManager.pause()
            }
        }
    }

    private func setupBindings() {
        // Observe network status using Swift Observation
        Task {
            await observeNetworkStatus()
        }

        // Sync PlaybackManager state to AppState
        playbackManager.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                guard let self else { return }
                self.playbackState = isPlaying ? .playing : (self.playbackManager.isBuffering ? .buffering : .paused)
            }
            .store(in: &cancellables)

        playbackManager.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isBuffering in
                guard let self else { return }
                if isBuffering {
                    self.playbackState = .buffering
                } else if self.playbackManager.isPlaying {
                    self.playbackState = .playing
                }
            }
            .store(in: &cancellables)

        playbackManager.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.currentTime = time
            }
            .store(in: &cancellables)

        playbackManager.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.duration = duration
            }
            .store(in: &cancellables)

        // Sync QueueManager state to AppState
        observeQueueManager()
    }

    private func observeQueueManager() {
        // Use Swift Observation to react to QueueManager changes
        Task { @MainActor in
            while !Task.isCancelled {
                // Wait for any change to tracked properties using continuation
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        // Access tracked properties to register observation
                        _ = queueManager.currentItem?.song.id
                        _ = queueManager.baseItems.count
                        _ = queueManager.upNextItems.count
                        _ = queueManager.autoPlayItems.count
                        _ = queueManager.basePosition
                    } onChange: {
                        // Resume when a change is detected
                        continuation.resume()
                    }
                }

                // Update AppState with new values immediately after change
                self.nowPlaying = self.queueManager.currentItem?.song
            }
        }
    }

    private func observeNetworkStatus() async {
        // Use Swift Observation - NetworkMonitor is @Observable and updates via pathUpdateHandler
        while !Task.isCancelled {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = networkMonitor.isConnected
                } onChange: {
                    continuation.resume()
                }
            }

            // Update connection status based on network change
            if networkMonitor.isConnected && connectionStatus == .offline {
                connectionStatus = .connected
            } else if !networkMonitor.isConnected && connectionStatus == .connected {
                connectionStatus = .offline
            }
        }
    }

    func persistState() {
        // Only save position if rememberPlaybackPosition is enabled
        let rememberPosition = UserDefaults.standard.bool(forKey: "rememberPlaybackPosition")
        // Save base items as the queue (upNext is ephemeral, not persisted)
        let persisted = PersistedPlaybackState(
            queueSongs: queueManager.baseItems.map { $0.song },
            queueIndex: max(0, queueManager.basePosition),
            lastPosition: rememberPosition ? currentTime : 0,
            timestamp: Date()
        )
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: Self.persistedPlaybackKey)
        }
    }

    // MARK: - Connection

    /// Attempts to reconnect to the current server.
    /// Assumes networkActor is already configured with credentials.
    /// For initial setup, use OnboardingView which configures credentials.
    func connect() async {
        guard let server = currentServer else {
            connectionStatus = .disconnected
            return
        }

        connectionStatus = .connecting

        do {
            // Test connection via ping - networkActor must already be configured
            _ = try await networkActor.ping()
            connectionStatus = .connected
            playbackManager.activeServerId = server.id.uuidString
        } catch {
            if let resonanceError = error as? ResonanceError {
                connectionStatus = .error(resonanceError)
            } else {
                connectionStatus = .error(.serverUnreachable(server.url))
            }
        }
    }

    private func persistServerConfiguration(_ server: Server, password: String) throws {
        try storePassword(for: server, password: password)
        upsertServer(server)
    }

    private func upsertServer(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        servers.insert(server, at: 0)
        persistServers()
        activeServer = server
    }

    private func persistServers() {
        guard !servers.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.serversStorageKey)
            return
        }

        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Self.serversStorageKey)
        }
    }

    private func storePassword(for server: Server, password: String) throws {
        guard let passwordData = password.data(using: .utf8) else {
            throw ResonanceError.invalidResponse(statusCode: 0)
        }

        let query = keychainQuery(for: server, storage: .dataProtection)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: passwordData] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            try? removePassword(for: server, storage: .legacy)
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw ResonanceError.keychainError(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = passwordData
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ResonanceError.keychainError(addStatus)
        }

        try? removePassword(for: server, storage: .legacy)
    }

    private func removePassword(for server: Server) throws {
        var firstError: OSStatus?

        for storage in [KeychainStorage.dataProtection, .legacy] {
            do {
                try removePassword(for: server, storage: storage)
            } catch ResonanceError.keychainError(let status) {
                firstError = firstError ?? status
            } catch {
                firstError = firstError ?? errSecInternalError
            }
        }

        if let firstError {
            throw ResonanceError.keychainError(firstError)
        }
    }

    private func removePassword(for server: Server, storage: KeychainStorage) throws {
        let query = keychainQuery(for: server, storage: storage)

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ResonanceError.keychainError(status)
        }
    }

    private func copyPassword(for server: Server, storage: KeychainStorage) -> String? {
        var query = keychainQuery(for: server, storage: storage)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainQuery(for server: Server, storage: KeychainStorage) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: server.id.uuidString,
            kSecAttrService as String: Self.serverPasswordService
        ]

        if storage == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        return query
    }

    // MARK: - GRDB Cache Loading

    /// Load cached library data from GRDB for instant display on startup
    func loadCachedLibrary(serverId: String) {
        do {
            // Load hidden IDs for filtering at display boundary + cache for other views
            refreshHiddenIds()
            refreshLikedIds()
            refreshLibraryMembershipIds()
            let hiddenAlbumIds = self.hiddenAlbumIds
            let hiddenArtistIds = self.hiddenArtistIds

            let cachedAlbums = try databaseManager.loadAdmittedAlbums(serverId: serverId)
            if !cachedAlbums.isEmpty {
                albums = hiddenAlbumIds.isEmpty ? cachedAlbums : cachedAlbums.filter { !hiddenAlbumIds.contains($0.id) }
            }

            let cachedArtists = try databaseManager.loadAdmittedArtists(serverId: serverId)
            if !cachedArtists.isEmpty {
                artists = hiddenArtistIds.isEmpty ? cachedArtists : cachedArtists.filter { !hiddenArtistIds.contains($0.id) }
            }

            let cachedPlaylists = try databaseManager.loadPlaylists(serverId: serverId)
            if !cachedPlaylists.isEmpty { playlists = cachedPlaylists }

            smartPlaylists = (try? databaseManager.loadSmartPlaylists(serverId: serverId)) ?? []
            unseenDiscoveryCount = (try? databaseManager.unseenDiscoveryCount(serverId: serverId)) ?? 0
        } catch {
            print("[AppState] Failed to load cached library: \(error)")
        }
    }

    func visibleSongsForPlayback(_ songs: [Song], serverId explicitServerId: String? = nil) -> [Song] {
        let serverId = explicitServerId ?? activeServerId
        let hiddenSongIds = loadHiddenIdsForPlayback(type: "song", serverId: serverId)
        let hiddenAlbumIds = loadHiddenIdsForPlayback(type: "album", serverId: serverId)
        let hiddenArtistIds = loadHiddenIdsForPlayback(type: "artist", serverId: serverId)

        return songs.filter {
            !hiddenSongIds.contains($0.id) &&
            !hiddenAlbumIds.contains($0.albumId) &&
            !hiddenArtistIds.contains($0.artistId)
        }
    }

    func playableAlbumSongs(for album: Album) async throws -> [Song] {
        let songs = try await networkActor.fetchAlbumSongs(albumId: album.id)
        let visibleSongs = visibleSongsForPlayback(songs)

        guard let serverId = activeServerId else {
            return visibleSongs
        }

        let albumIsAdmitted = (try? databaseManager.isInLibrary(
            id: album.id,
            type: .album,
            serverId: serverId
        )) ?? admittedAlbumIds.contains(album.id)

        guard albumIsAdmitted else {
            return visibleSongs
        }

        let admittedSongIds = (try? databaseManager.loadLibraryMemberIds(
            type: .song,
            serverId: serverId
        )) ?? self.admittedSongIds

        return visibleSongs.filter { admittedSongIds.contains($0.id) }
    }

    func playableArtistSongs(for artist: Artist) async throws -> [Song] {
        let detail = try await networkActor.fetchArtist(id: artist.id)

        guard let serverId = activeServerId else {
            var songs: [Song] = []
            for album in detail.albums {
                songs.append(contentsOf: try await networkActor.fetchAlbumSongs(albumId: album.id))
            }
            return visibleSongsForPlayback(songs)
        }

        let artistIsAdmitted = (try? databaseManager.isInLibrary(
            id: artist.id,
            type: .artist,
            serverId: serverId
        )) ?? admittedArtistIds.contains(artist.id)
        let admittedAlbumIds = (try? databaseManager.loadLibraryMemberIds(
            type: .album,
            serverId: serverId
        )) ?? self.admittedAlbumIds
        let admittedSongIds = (try? databaseManager.loadLibraryMemberIds(
            type: .song,
            serverId: serverId
        )) ?? self.admittedSongIds

        var songs: [Song] = []
        for album in detail.albums where !artistIsAdmitted || admittedAlbumIds.contains(album.id) {
            let albumSongs = try await networkActor.fetchAlbumSongs(albumId: album.id)
            let visibleAlbumSongs = visibleSongsForPlayback(albumSongs, serverId: serverId)
                .filter { !artistIsAdmitted || admittedSongIds.contains($0.id) }
            songs.append(contentsOf: visibleAlbumSongs)
        }
        return songs
    }

    private func loadHiddenIdsForPlayback(type: String, serverId explicitServerId: String?) -> Set<String> {
        guard let serverId = explicitServerId else {
            return cachedHiddenIds(type: type)
        }
        return (try? databaseManager.loadHiddenIds(type: type, serverId: serverId)) ?? cachedHiddenIds(type: type)
    }

    private func cachedHiddenIds(type: String) -> Set<String> {
        switch type {
        case "song":
            return hiddenSongIds
        case "album":
            return hiddenAlbumIds
        case "artist":
            return hiddenArtistIds
        default:
            return []
        }
    }

    // MARK: - Star/Unstar Updates

    /// Update starred status for a song in all relevant collections
    func updateSongStarred(id: String, starred: Date?) {
        // Update in QueueManager (handles all sections including currentItem)
        queueManager.updateSongStarred(id: id, starred: starred)

        // Update nowPlaying if it's the same song
        if nowPlaying?.id == id {
            nowPlaying?.starred = starred
        }
    }

    /// Update starred status for an album
    func updateAlbumStarred(id: String, starred: Date?) {
        if let index = albums.firstIndex(where: { $0.id == id }) {
            albums[index].starred = starred
        }
    }

    /// Update starred status for an artist
    func updateArtistStarred(id: String, starred: Date?) {
        if let index = artists.firstIndex(where: { $0.id == id }) {
            artists[index].starred = starred
        }
    }

    // MARK: - Rating Updates

    /// Update rating for a song (optimistic update, call after API success)
    func updateSongRating(id: String, rating: Int?) {
        // Update now playing if it's the same song
        if nowPlaying?.id == id {
            nowPlaying?.rating = rating
        }
    }

    /// Update rating for an album (optimistic update, call after API success)
    func updateAlbumRating(id: String, rating: Int?) {
        if let index = albums.firstIndex(where: { $0.id == id }) {
            albums[index].rating = rating
        }
    }

    // MARK: - Window Management

    /// Reference to emotion engine for window management
    var emotionEngine: EmotionEngine?

    /// Track open mini player window
    private var miniPlayerWindow: NSWindow?

    /// The primary window hidden while the mini player is open.
    private var mainWindowBeforeMiniPlayer: NSWindow?

    /// Retained delegate for mini player lifecycle events.
    private var miniPlayerWindowDelegate: MiniPlayerWindowDelegate?

    /// Track immersive mode window
    private var immersiveWindow: NSWindow?

    /// Delegate for immersive window lifecycle events
    private var immersiveWindowDelegate: ImmersiveWindowDelegate?

    func showMiniPlayer() {
        // Repeated requests should reveal/focus the existing player, not tear
        // down its SwiftUI hosting hierarchy while AppKit is still using it.
        if let existing = miniPlayerWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let mainWindow = NSApp.windows.first {
            $0.identifier?.rawValue == "mainWindow"
        }
        mainWindowBeforeMiniPlayer = mainWindow

        // Open mini player window with persisted size
        let mode = MiniPlayerMode.persisted
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: mode.size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("miniPlayer")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false

        // Hide traffic lights initially (MiniPlayerView will show them on hover)
        window.standardWindowButton(.closeButton)?.alphaValue = 0
        window.standardWindowButton(.miniaturizeButton)?.alphaValue = 0
        window.standardWindowButton(.zoomButton)?.alphaValue = 0

        let rootView = MiniPlayerView().environment(self)
        if let engine = emotionEngine {
            let viewWithEngine = rootView.environment(\.emotionEngine, engine)
            window.contentView = NSHostingView(rootView: viewWithEngine)
        } else {
            window.contentView = NSHostingView(rootView: rootView)
        }

        let delegate = MiniPlayerWindowDelegate { [weak self] closingWindow in
            self?.miniPlayerDidClose(closingWindow)
        }
        window.delegate = delegate
        miniPlayerWindowDelegate = delegate
        miniPlayerWindow = window

        window.center()
        mainWindow?.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func miniPlayerDidClose(_ window: NSWindow) {
        guard miniPlayerWindow === window else { return }

        miniPlayerWindow = nil
        miniPlayerWindowDelegate = nil

        let mainWindow = mainWindowBeforeMiniPlayer
            ?? NSApp.windows.first { $0.identifier?.rawValue == "mainWindow" }
        mainWindowBeforeMiniPlayer = nil
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func enterImmersiveMode() {
        // Close existing immersive window if open
        if let existing = immersiveWindow, existing.isVisible {
            existing.close()
            immersiveWindow = nil
            return
        }

        // Create fullscreen immersive window
        guard let screen = NSScreen.main else { return }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .normal
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.fullScreenPrimary]

        let rootView = ImmersiveView().environment(self)
        if let engine = emotionEngine {
            let viewWithEngine = rootView.environment(\.emotionEngine, engine)
            window.contentView = NSHostingView(rootView: viewWithEngine)
        } else {
            window.contentView = NSHostingView(rootView: rootView)
        }

        // Set delegate to handle native close/fullscreen exit
        let delegate = ImmersiveWindowDelegate { [weak self] in
            self?.immersiveWindow = nil
        }
        window.delegate = delegate
        immersiveWindowDelegate = delegate  // Retain the delegate

        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        immersiveWindow = window
    }

    func exitImmersiveMode() {
        guard let window = immersiveWindow else { return }
        immersiveWindow = nil  // Clear first to prevent delegate re-entry
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        window.close()
    }

    func removeSelectedQueueItem() {
        guard let selectedId = selectedQueueItemId else { return }
        queueManager.remove(id: selectedId)
        selectedQueueItemId = nil
    }

    // MARK: - Pins Management

    /// Load pins from UserDefaults
    private func loadPins() {
        guard let data = UserDefaults.standard.data(forKey: Self.pinsKey),
              let decoded = try? JSONDecoder().decode([PinnedItem].self, from: data) else {
            return
        }
        // Set directly to avoid triggering didSet persistence
        pinnedItems = decoded
    }

    /// Persist pins to UserDefaults
    private func persistPins() {
        guard let data = try? JSONEncoder().encode(pinnedItems) else { return }
        UserDefaults.standard.set(data, forKey: Self.pinsKey)
    }

    /// Check if an item is pinned
    func isPinned(id: String, type: PinnableType) -> Bool {
        pinnedItems.contains { $0.id == id && $0.type == type }
    }

    /// Pin an item (max 10, oldest removed if exceeded)
    func pin(_ item: PinnedItem) {
        // Don't add duplicates
        guard !pinnedItems.contains(where: { $0.id == item.id && $0.type == item.type }) else {
            return
        }

        // Insert at beginning (most recent first)
        pinnedItems.insert(item, at: 0)

        // Enforce max limit
        if pinnedItems.count > Self.maxPins {
            pinnedItems = Array(pinnedItems.prefix(Self.maxPins))
        }
    }

    /// Unpin an item
    func unpin(id: String, type: PinnableType) {
        pinnedItems.removeAll { $0.id == id && $0.type == type }
    }

    /// Move a pin to a new position (for drag reordering)
    func movePins(from source: IndexSet, to destination: Int) {
        pinnedItems.move(fromOffsets: source, toOffset: destination)
    }

    // Convenience methods
    func pinAlbum(_ album: Album) { pin(PinnedItem(album: album)) }
    func pinPlaylist(_ playlist: Playlist) { pin(PinnedItem(playlist: playlist)) }
    func pinArtist(_ artist: Artist) { pin(PinnedItem(artist: artist)) }
    func unpinAlbum(_ album: Album) { unpin(id: album.id, type: .album) }
    func unpinPlaylist(_ playlist: Playlist) { unpin(id: playlist.id, type: .playlist) }
    func unpinArtist(_ artist: Artist) { unpin(id: artist.id, type: .artist) }
}

// MARK: - Supporting Types

enum ConnectionStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case offline
    case error(ResonanceError)

    static func == (lhs: ConnectionStatus, rhs: ConnectionStatus) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected),
             (.offline, .offline):
            return true
        case (.error, .error):
            // Compare by case only, not underlying error details
            return true
        default:
            return false
        }
    }
}

enum PlaybackState: Sendable {
    case stopped
    case playing
    case paused
    case buffering
}

enum RepeatMode: String, Sendable, Codable, CaseIterable {
    case off
    case one
    case all
}

enum SidebarItem: String, Sendable, CaseIterable, Identifiable {
    case listen
    case plane
    case home
    case waitingRoom
    case projects
    case unclassified
    case importPolicies
    case fetcherSources
    case artists
    case albums
    case songs
    case genres
    case folders
    case favorites
    case newMusic
    case recentlyAdded
    case recentlyPlayed
    case downloads
    case playlists
    case radio
    case search

    var id: String { rawValue }

    var label: String {
        switch self {
        case .listen: return "Listen"
        case .plane: return "Plane"
        case .home: return "Home"
        case .waitingRoom: return "Waiting Room"
        case .projects: return "Projects"
        case .unclassified: return "Unclassified"
        case .importPolicies: return "Import Policies"
        case .fetcherSources: return "Sources"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .songs: return "Songs"
        case .genres: return "Genres"
        case .folders: return "Folders"
        case .favorites: return "Liked Songs"
        case .newMusic: return "New Music"
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        case .downloads: return "Downloads"
        case .playlists: return "Playlists"
        case .radio: return "Radio"
        case .search: return "Search"
        }
    }

    var icon: String {
        switch self {
        case .listen: return "play.circle"
        case .plane: return "square.stack.3d.down.right"
        case .home: return "house"
        case .waitingRoom: return "tray"
        case .projects: return "tray.full"
        case .unclassified: return "rectangle.dashed"
        case .importPolicies: return "slider.horizontal.3"
        case .fetcherSources: return "tray.and.arrow.down"
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .songs: return "music.note.list"
        case .genres: return "guitars"
        case .folders: return "folder"
        case .favorites: return "plus.circle.fill"
        case .newMusic: return "sparkles"
        case .recentlyAdded: return "clock.badge.checkmark"
        case .recentlyPlayed: return "clock"
        case .downloads: return "arrow.down.circle"
        case .playlists: return "music.note.list"
        case .radio: return "radio"
        case .search: return "magnifyingglass"
        }
    }

    /// Filled icon variants for Apple Music-style sidebar
    var filledIcon: String {
        switch self {
        case .listen: return "play.circle.fill"
        case .plane: return "square.stack.3d.down.right.fill"
        case .home: return "house.fill"
        case .waitingRoom: return "tray.fill"
        case .projects: return "tray.full.fill"
        case .unclassified: return "rectangle.dashed"
        case .importPolicies: return "slider.horizontal.3"
        case .fetcherSources: return "tray.and.arrow.down.fill"
        case .artists: return "music.mic.circle.fill"
        case .albums: return "square.stack.fill"
        case .songs: return "music.note.list"
        case .genres: return "guitars.fill"
        case .folders: return "folder.fill"
        case .favorites: return "plus.circle.fill"
        case .newMusic: return "sparkles"
        case .recentlyAdded: return "sparkles"
        case .recentlyPlayed: return "clock.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .playlists: return "music.note.list"
        case .radio: return "antenna.radiowaves.left.and.right"
        case .search: return "magnifyingglass"
        }
    }
}

struct PersistedPlaybackState: Codable {
    /// Full song objects for queue restoration (avoids 10k song fetch on launch)
    let queueSongs: [Song]
    let queueIndex: Int
    let lastPosition: TimeInterval
    let timestamp: Date

    /// Migration: decode old format (queueSongIds) gracefully
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queueIndex = try container.decode(Int.self, forKey: .queueIndex)
        lastPosition = try container.decode(TimeInterval.self, forKey: .lastPosition)
        timestamp = try container.decode(Date.self, forKey: .timestamp)

        // Try new format first, fall back to empty if old format
        if let songs = try? container.decode([Song].self, forKey: .queueSongs) {
            queueSongs = songs
        } else {
            // Old format had queueSongIds - we can't restore without songs, so empty queue
            queueSongs = []
        }
    }

    init(queueSongs: [Song], queueIndex: Int, lastPosition: TimeInterval, timestamp: Date) {
        self.queueSongs = queueSongs
        self.queueIndex = queueIndex
        self.lastPosition = lastPosition
        self.timestamp = timestamp
    }
}

// MARK: - Immersive Window Delegate

/// Owns the handoff back to the primary window when the mini player closes.
final class MiniPlayerWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: (NSWindow) -> Void

    init(onClose: @escaping (NSWindow) -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onClose(window)
    }
}

/// Handles native window close/fullscreen exit for immersive mode
final class ImmersiveWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        // User exited fullscreen via green button - close the window
        guard let window = notification.object as? NSWindow else { return }
        window.close()
    }
}
