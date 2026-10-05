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

private final class FixtureBoundaryAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var keychainOperationCount = 0

    func recordKeychainOperation() {
        lock.lock()
        keychainOperationCount += 1
        lock.unlock()
    }

    func snapshotKeychainOperationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return keychainOperationCount
    }
}

enum NowPlayingInspectorMode: Sendable, Equatable {
    case lyrics
    case queue
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
    var activeServer: Server? {
        didSet {
            if activeServer?.id != oldValue?.id || activeServer?.url != oldValue?.url
                || activeServer?.username != oldValue?.username {
                if oldValue != nil, !DeterministicCaptureFixture.isEnabled {
                    queueManager.resetForServerChange()
                    pendingQueueRestore = nil
                    UserDefaults.standard.removeObject(forKey: Self.persistedPlaybackKey)
                }
                connectionGeneration &+= 1
                launchRestoreTicket = nil
                playbackManager.invalidateForServerChange()
                playbackManager.activeServerId = activeServer?.id.uuidString ?? ""
                clearNavigationHistory()
                invalidateFullAlbumCatalog()
                albumPresentationStore.reset()
            }
        }
    }
    var connectionStatus: ConnectionStatus = .disconnected

    /// Alias for activeServer - used by views and settings
    var currentServer: Server? {
        get { activeServer }
        set { activeServer = newValue }
    }

    /// Persisted onboarding completion state
    var isOnboardingComplete = DeterministicCaptureFixture.isEnabled
        || UserDefaults.standard.bool(forKey: "isOnboardingComplete") {
        didSet {
            guard !DeterministicCaptureFixture.isEnabled else { return }
            UserDefaults.standard.set(isOnboardingComplete, forKey: "isOnboardingComplete")
        }
    }

    /// Save current server to UserDefaults
    func saveServer(_ server: Server, password: String) throws {
        guard !DeterministicCaptureFixture.isEnabled else {
            throw ResonanceError.notConfigured
        }
        try persistServerConfiguration(server, password: password)
    }

    /// Load password from keychain for server
    func loadPassword(for server: Server) -> String? {
        guard !DeterministicCaptureFixture.isEnabled else { return nil }

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
        guard !DeterministicCaptureFixture.isEnabled else {
            throw ResonanceError.notConfigured
        }

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
        guard !DeterministicCaptureFixture.isEnabled else {
            throw ResonanceError.notConfigured
        }

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

        connectionGeneration &+= 1
        launchRestoreTicket = nil
        playbackManager.invalidateRestoration()
        await playbackManager.stop()
        await networkActor.resetConfiguration()

        servers = []
        activeServer = nil
        connectionStatus = .disconnected
        artists = []
        albums = []
        fullAlbumCatalogLoader.invalidate()
        fullAlbumCatalogServerID = nil
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
        libraryMembershipRevision &+= 1
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
    private(set) var fullAlbumCatalogServerID: String?
    private let fullAlbumCatalogLoader = FullAlbumCatalogLoader()
    private(set) var albumPresentationStore = AlbumPresentationStore()
    var albumPresentationRevision: UInt64 { albumPresentationStore.revision }
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
        libraryMembershipRevision &+= 1
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
    /// Cheap invalidation identity for DB-backed library queries. Views must
    /// not hash the complete admitted-ID sets on every body evaluation.
    private(set) var libraryMembershipRevision: UInt64 = 0

    /// Call after admit/reject operations to keep pristine library filters in sync.
    func refreshLibraryMembershipIds() {
        guard let serverId = activeServerId else { return }
        admittedSongIds = (try? databaseManager.loadLibraryMemberIds(type: .song, serverId: serverId)) ?? []
        admittedAlbumIds = (try? databaseManager.loadLibraryMemberIds(type: .album, serverId: serverId)) ?? []
        admittedArtistIds = (try? databaseManager.loadLibraryMemberIds(type: .artist, serverId: serverId)) ?? []
        libraryMembershipRevision &+= 1
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
    var selectedSidebarItem: SidebarItem = .home {
        didSet {
            guard selectedSidebarItem != oldValue, !isRestoringNavigation else { return }
            let previous = NavigationVisit(sidebar: oldValue, path: detailNavigationPath)
            isRestoringNavigation = true
            detailNavigationPath = NavigationPath()
            isRestoringNavigation = false
            recordNavigationChange(from: previous)
        }
    }
    var searchQuery: String = ""
    var nowPlayingInspector: NowPlayingInspectorMode?

    func toggleNowPlayingInspector(_ mode: NowPlayingInspectorMode) {
        nowPlayingInspector = nowPlayingInspector == mode ? nil : mode
    }
    /// Trigger to focus the search field (set to true, observed by SearchField, auto-resets)
    var shouldFocusSearch: Bool = false

    // MARK: - AutoPlay (continues playing similar songs when queue ends)
    /// Persisted autoplay toggle - when enabled, plays similar songs after queue ends
    var isAutoPlayEnabled: Bool = DeterministicCaptureFixture.isEnabled
        ? false : UserDefaults.standard.bool(forKey: "isAutoPlayEnabled") {
        didSet {
            if isAutoPlayEnabled != oldValue { playbackManager.invalidatePendingAutoPlay() }
            // Fixture controls must work without reading/writing personal defaults.
            guard !DeterministicCaptureFixture.isEnabled else { return }
            UserDefaults.standard.set(isAutoPlayEnabled, forKey: "isAutoPlayEnabled")
        }
    }

    // MARK: - Sheet State
    var showCreatePlaylistSheet = false
    var createPlaylistSongIds: [String] = []
    var playlistDestinationRequest: PlaylistDestinationRequest?

    func choosePlaylist(itemCount: Int? = nil, resolveSongIDs: @escaping @MainActor () async throws -> [String]) {
        guard let serverID = activeServer?.id else { return }
        playlistDestinationRequest = PlaylistDestinationRequest(serverID: serverID,
            itemCount: itemCount, resolveSongIDs: resolveSongIDs)
    }
    var editPlaylistTarget: Playlist?
    var getInfoContent: GetInfoContent?
    // Like route and sheet presentation, command selection is owned by the
    // shared app state. Do not depend on an active/key window to identify it.
    var songsInfoSelection: [Song] = []
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
    var detailNavigationPath = NavigationPath() {
        didSet {
            guard detailNavigationPath != oldValue, !isRestoringNavigation else { return }
            recordNavigationChange(from: NavigationVisit(sidebar: selectedSidebarItem, path: oldValue))
        }
    }

    private struct NavigationVisit: Equatable {
        let sidebar: SidebarItem
        let path: NavigationPath
    }
    private var navigationBackStack: [NavigationVisit] = []
    private var navigationForwardStack: [NavigationVisit] = []
    private var navigationHistoryStarted = false
    private var isRestoringNavigation = false
    var canNavigateBack: Bool { !navigationBackStack.isEmpty || !detailNavigationPath.isEmpty }
    var canNavigateForward: Bool { !navigationForwardStack.isEmpty }

    /// Capture whole locations, not just the last album, so Back/Forward also
    /// restores an artist/album drill-down across sidebar sections.
    func startNavigationHistory() {
        guard !navigationHistoryStarted else { return }
        navigationHistoryStarted = true
        for count in 0..<detailNavigationPath.count {
            var prefix = detailNavigationPath
            prefix.removeLast(prefix.count - count)
            navigationBackStack.append(NavigationVisit(sidebar: selectedSidebarItem, path: prefix))
        }
    }

    private var navigationVisit: NavigationVisit {
        NavigationVisit(sidebar: selectedSidebarItem, path: detailNavigationPath)
    }

    private func recordNavigationChange(from previous: NavigationVisit) {
        guard navigationHistoryStarted, previous != navigationVisit else { return }
        // A native NavigationStack Back button changes the binding directly.
        // Preserve its forward destination just like the mouse Back button.
        if previous.sidebar == selectedSidebarItem,
           previous.path.count > detailNavigationPath.count,
           let index = navigationBackStack.lastIndex(of: navigationVisit) {
            navigationForwardStack.append(previous)
            navigationForwardStack.append(contentsOf: navigationBackStack[(index + 1)...].reversed())
            navigationBackStack.removeSubrange(index...)
        } else {
            navigationBackStack.append(previous)
            if navigationBackStack.count > 100 { navigationBackStack.removeFirst() }
            navigationForwardStack.removeAll()
        }
    }

    func navigateBack() {
        if let destination = navigationBackStack.popLast() {
            navigationForwardStack.append(navigationVisit)
            restoreNavigation(destination)
        } else if !detailNavigationPath.isEmpty {
            navigationForwardStack.append(navigationVisit)
            var parent = detailNavigationPath
            parent.removeLast()
            restoreNavigation(NavigationVisit(sidebar: selectedSidebarItem, path: parent))
        }
    }

    func navigateForward() {
        guard let destination = navigationForwardStack.popLast() else { return }
        navigationBackStack.append(navigationVisit)
        restoreNavigation(destination)
    }

    private func restoreNavigation(_ destination: NavigationVisit) {
        isRestoringNavigation = true
        navigationTargetAlbumId = nil
        navigationTargetArtistId = nil
        navigationTargetSongId = nil
        selectedSidebarItem = destination.sidebar
        detailNavigationPath = destination.path
        isRestoringNavigation = false
    }

    func clearNavigationHistory() {
        isRestoringNavigation = true
        detailNavigationPath = NavigationPath()
        navigationTargetAlbumId = nil
        navigationTargetArtistId = nil
        navigationTargetSongId = nil
        isRestoringNavigation = false
        navigationBackStack.removeAll()
        navigationForwardStack.removeAll()
    }
    /// Set to navigate to an album from context menu (processed by DetailView)
    var navigationTargetAlbumId: String?
    /// Set to navigate to an artist from context menu (processed by DetailView)
    var navigationTargetArtistId: String?
    /// Set to highlight a specific song when navigating to an album (from NowPlayingBar)
    var navigationTargetSongId: String?

    // MARK: - Managers
    /// Launch-only configuration and catalog. Both are nil during a normal
    /// production-backed launch.
    let captureFixtureConfiguration: DeterministicCaptureFixture.Configuration?
    let parityFixtureCatalog: ParityFixtureCatalog?
    let fixtureScratchRoot: URL?
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
    private var launchRestoreTicket: PlaybackManager.RestoreTicket?
    private var connectionGeneration: UInt64 = 0
    private var feedbackDismissTask: Task<Void, Never>?
    private var didPresentFixtureAuxiliaryWindow = false
    private var didScheduleFixtureAudit = false
    private var didScheduleNormalSmokeAudit = false
    private let fixtureBoundaryAudit = FixtureBoundaryAudit()

    private enum KeychainStorage {
        case dataProtection
        case legacy
    }

    init() {
        let captureFixture = DeterministicCaptureFixture.configuration
        let atlasCatalog = captureFixture?.isAtlas == true
            ? captureFixture?.catalog
            : nil
        let networkFixtureCatalog = captureFixture == nil
            ? nil
            : (atlasCatalog ?? ParityFixtureCatalog.standard)
        let fixtureScratchRoot = Self.fixtureScratchRoot(for: captureFixture)

        self.captureFixtureConfiguration = captureFixture
        self.parityFixtureCatalog = atlasCatalog
        self.fixtureScratchRoot = fixtureScratchRoot

        self.audioActor = AudioActor()
        self.networkActor = NetworkActor(
            catalog: networkFixtureCatalog,
            configuration: captureFixture
        )
        if let fixtureScratchRoot {
            self.cacheActor = CacheActor(
                cacheDirectory: fixtureScratchRoot.appendingPathComponent("cache", isDirectory: true),
                downloadsDirectory: fixtureScratchRoot.appendingPathComponent("downloads", isDirectory: true)
            )
        } else {
            self.cacheActor = CacheActor()
        }
        self.networkMonitor = NetworkMonitor(inert: captureFixture != nil)
        self.queueManager = QueueManager()
        if let captureFixture {
            self.lyricsService = LyricsService(
                networkActor: networkActor,
                cacheActor: cacheActor,
                fixtureLyrics: networkFixtureCatalog?.lyricsBySongID ?? [:],
                fixtureState: captureFixture.state
            )
        } else {
            self.lyricsService = LyricsService(networkActor: networkActor, cacheActor: cacheActor)
        }

        // Initialize GRDB database (replaces SwiftData, LibraryCache, PlayHistoryStore)
        do {
            if let fixtureScratchRoot {
                self.databaseManager = try DatabaseManager(
                    databaseURL: fixtureScratchRoot.appendingPathComponent(
                        "resonance-parity-atlas.db",
                        isDirectory: false
                    )
                )
            } else {
                self.databaseManager = try DatabaseManager()
            }

            if let atlasCatalog {
                try self.databaseManager.seedFixtureCatalog(
                    atlasCatalog,
                    serverId: atlasCatalog.serverId
                )
            }
        } catch {
            fatalError("Could not create DatabaseManager: \(error)")
        }

        self.companionServiceManager = captureFixture == nil
            ? CompanionServiceManager(databaseManager: databaseManager)
            : nil

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

        if captureFixture == nil {
            // Wire up response caching
            Task { await networkActor.setCacheActor(cacheActor) }

            // Apply user's cache size limit setting
            Task {
                let maxCacheSizeGB = (UserDefaults.standard.object(forKey: "maxCacheSize") as? Double) ?? 5.0
                await cacheActor.setMaxAudioCacheSize(
                    CacheActor.audioCacheLimitBytes(gigabytes: maxCacheSizeGB)
                )
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
        }

        if captureFixture == nil {
            loadPersistedState()
            loadPins()
        }
        setupBindings(observeNetwork: captureFixture == nil)

        if captureFixture == nil {
            // A stale/defaulted launch route may have been hidden in Sidebar
            // settings. Select a visible route without rewriting the saved
            // preference, so restoring that sidebar item makes it usable again.
            selectLaunchSidebarItem(
                defaultViewRawValue: UserDefaults.standard.string(forKey: "defaultViewOnLaunch")
            )
            checkDevMode()

            // Start library auto-refresh scheduler
            self.libraryRefreshScheduler = LibraryRefreshScheduler(appState: self)
            print(
                "[ResonanceLaunch] mode=normal fixtureCatalog=absent "
                    + "database=production networkMonitor=active scheduler=enabled"
            )
        } else if let captureFixture {
            installDeterministicCaptureFixture(captureFixture)
            print(
                "[ParityFixture] mode=\(captureFixture.mode.rawValue) "
                    + "route=\(captureFixture.route.rawValue) "
                    + "state=\(captureFixture.state.rawValue) "
                    + "database=injected cache=scratch networkMonitor=inert "
                    + "scheduler=disabled companion=disabled keychain=disabled"
            )
        }
    }

    /// Keep the active sidebar route reachable when visibility preferences
    /// change while the app is open. Search stays available even if every
    /// configurable item is hidden; protected Settings-only routes are not
    /// rewritten by sidebar preferences.
    func reconcileSidebarSelectionWithVisibility() {
        guard captureFixtureConfiguration == nil else { return }
        let visibleSelection = visibleSidebarItem(for: selectedSidebarItem)
        guard visibleSelection != selectedSidebarItem else { return }

        // A Back visit to a now-hidden sidebar destination would re-create the
        // same invalid state. Treat the visibility change as a history boundary.
        isRestoringNavigation = true
        selectedSidebarItem = visibleSelection
        detailNavigationPath = NavigationPath()
        navigationTargetAlbumId = nil
        navigationTargetArtistId = nil
        navigationTargetSongId = nil
        isRestoringNavigation = false
        navigationBackStack.removeAll()
        navigationForwardStack.removeAll()
    }

    private func selectLaunchSidebarItem(defaultViewRawValue: String?) {
        let requested = defaultViewRawValue.flatMap(SidebarItem.init(rawValue:)) ?? .home
        selectedSidebarItem = visibleSidebarItem(for: requested)
    }

    private func visibleSidebarItem(for requested: SidebarItem) -> SidebarItem {
        guard isSidebarItemVisible(requested) else {
            if isSidebarItemVisible(.home) { return .home }
            if isSidebarItemVisible(.listen) { return .listen }
            // Search has its own always-visible control outside the List,
            // including the sidebar's all-items-hidden empty state.
            return .search
        }
        return requested
    }

    private func isSidebarItemVisible(_ item: SidebarItem) -> Bool {
        let defaults = UserDefaults.standard
        func enabled(_ key: String, defaultValue: Bool = true) -> Bool {
            defaults.object(forKey: key) as? Bool ?? defaultValue
        }

        // SidebarView replaces its List with an empty-state when every
        // configurable entry is hidden and no pins/playlists can populate it.
        let listHasVisibleContent = [
            enabled("showSidebarListen"), enabled("showSidebarHome"),
            enabled("showSidebarWaitingRoom"), enabled("showSidebarProjects"),
            enabled("showSidebarUnclassified"), enabled("showSidebarArtists"),
            enabled("showSidebarAlbums"), enabled("showSidebarSongs"),
            enabled("showSidebarGenres"), enabled("showSidebarFolders"),
            enabled("showSidebarFavorites"), enabled("showSidebarRecentlyAdded"),
            enabled("showSidebarRecentlyPlayed"), enabled("showSidebarNewMusic"),
            enabled("showSidebarRadio"), enabled("showSidebarDownloads"),
            enabled("enableOnePlane", defaultValue: false)
        ].contains(true) || !pinnedItems.isEmpty || !playlists.isEmpty

        switch item {
        case .listen: return enabled("showSidebarListen")
        case .plane: return enabled("enableOnePlane", defaultValue: false)
        case .home: return enabled("showSidebarHome")
        case .waitingRoom: return enabled("showSidebarWaitingRoom")
        case .projects: return enabled("showSidebarProjects")
        case .unclassified:
            return enabled("showSidebarUnclassified") && unclassifiedCount > 0
        case .importPolicies:
            // Reached from Settings; it is not a preference-controlled item.
            return true
        case .artists: return enabled("showSidebarArtists")
        case .albums: return enabled("showSidebarAlbums")
        case .songs: return enabled("showSidebarSongs")
        case .genres: return enabled("showSidebarGenres")
        case .folders: return enabled("showSidebarFolders")
        case .favorites: return enabled("showSidebarFavorites")
        case .newMusic: return enabled("showSidebarNewMusic")
        case .recentlyAdded: return enabled("showSidebarRecentlyAdded")
        case .recentlyPlayed: return enabled("showSidebarRecentlyPlayed")
        case .downloads: return enabled("showSidebarDownloads")
        case .playlists: return listHasVisibleContent
        case .radio: return enabled("showSidebarRadio")
        case .search: return true
        }
    }

    /// Present an auxiliary atlas route only after the real main window has
    /// entered the AppKit hierarchy. Background launches order the target
    /// window without activating Resonance.
    func presentFixtureAuxiliaryWindowIfNeeded() {
        guard !didPresentFixtureAuxiliaryWindow,
              let fixture = captureFixtureConfiguration,
              fixture.isAtlas else {
            return
        }
        didPresentFixtureAuxiliaryWindow = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch fixture.route {
            case .miniPlayerArtwork:
                self.showMiniPlayer(initialMode: .art, activate: !fixture.background)
                print("[ParityFixture] targetWindow=miniPlayer mode=artwork")
            case .miniPlayerQueue:
                self.showMiniPlayer(initialMode: .queue, activate: !fixture.background)
                print("[ParityFixture] targetWindow=miniPlayer mode=queue")
            case .miniPlayerLyrics:
                self.showMiniPlayer(initialMode: .lyrics, activate: !fixture.background)
                print("[ParityFixture] targetWindow=miniPlayer mode=lyrics")
            case .fullscreenNowPlaying:
                self.enterImmersiveMode(
                    activate: !fixture.background,
                    enterNativeFullScreen: !fixture.background
                )
                print("[ParityFixture] targetWindow=immersivePlayer")
            default:
                print("[ParityFixture] targetWindow=mainWindow")
            }
        }
    }

    /// Emit a settled, machine-readable audit marker after route tasks have
    /// had time to execute. This is consumed by the isolation verifier.
    func scheduleFixtureAuditIfNeeded() {
        guard !didScheduleFixtureAudit,
              captureFixtureConfiguration != nil else {
            return
        }
        didScheduleFixtureAudit = true

        let networkActor = networkActor
        let audioActor = audioActor
        let route = captureFixtureConfiguration?.route.rawValue ?? "legacy-footer"
        let databaseInjected = databaseManager.isInjectedDatabase
        let networkMonitorInert = networkMonitor.isInert
        let schedulerDisabled = libraryRefreshScheduler == nil
        let companionDisabled = companionServiceManager == nil
        let scratchRootTemporary = fixtureScratchRoot.map(Self.isTemporaryFixtureRoot) ?? false
        let boundaryAudit = fixtureBoundaryAudit
        let environment = ProcessInfo.processInfo.environment
        Self.writeFixtureAuditScheduledArtifact(environment: environment, route: route)

        // This begins only after the real WindowGroup appears. The delay gives
        // route tasks and auxiliary artwork/lyrics loading a settled window.
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(4))
            let networkAudit = await networkActor.fixtureAuditSnapshot()
            let playerItemCount = await audioActor.auditPlayerItemCreationCount()
            let keychainOperationCount = boundaryAudit.snapshotKeychainOperationCount()
            let auditFields = [
                "[ParityFixtureAudit]",
                "stage=settled",
                "route=\(route)",
                "transportRequests=\(networkAudit.transportRequestCount)",
                "blockedCalls=\(networkAudit.blockedCallCount)",
                "scrobbleAttempts=\(networkAudit.scrobbleAttemptCount)",
                "playerItems=\(playerItemCount)",
                "keychainOperations=\(keychainOperationCount)",
                "databaseInjected=\(databaseInjected)",
                "productionDatabase=unopened",
                "scratchRootTemporary=\(scratchRootTemporary)",
                "networkMonitorInert=\(networkMonitorInert)",
                "schedulerDisabled=\(schedulerDisabled)",
                "companionDisabled=\(companionDisabled)",
                "keychain=disabled",
                "preferences=read-only",
                "scrobble=disabled"
            ]
            print(auditFields.joined(separator: " "))
            Self.writeFixtureAuditArtifact(
                environment: environment,
                route: route,
                networkAudit: networkAudit,
                playerItemCreationCount: playerItemCount,
                keychainOperationCount: keychainOperationCount,
                databaseInjected: databaseInjected,
                scratchRootTemporary: scratchRootTemporary,
                networkMonitorInert: networkMonitorInert,
                schedulerDisabled: schedulerDisabled,
                companionDisabled: companionDisabled
            )
            print("[ParityFixtureReady] route=\(route)")
        }
    }

    /// Optional normal-launch proof used by the background smoke launcher.
    /// It records booleans and a synthetic-ID count, never server data.
    func scheduleNormalSmokeAuditIfRequested() {
        guard !didScheduleNormalSmokeAudit,
              captureFixtureConfiguration == nil,
              ProcessInfo.processInfo.environment["RESONANCE_NORMAL_AUDIT_LOG"] != nil else {
            return
        }
        didScheduleNormalSmokeAudit = true

        let environment = ProcessInfo.processInfo.environment
        let appState = self
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(4))
            let snapshot = await MainActor.run {
                var ids = appState.artists.map(\.id)
                ids.append(contentsOf: appState.albums.map(\.id))
                ids.append(contentsOf: appState.playlists.map(\.id))
                ids.append(contentsOf: appState.smartPlaylists.map(\.id))
                ids.append(contentsOf: appState.queueManager.baseItems.map(\.song.id))
                ids.append(contentsOf: appState.queueManager.upNextItems.map(\.song.id))
                ids.append(contentsOf: appState.queueManager.autoPlayItems.map(\.song.id))
                ids.append(contentsOf: appState.queueManager.history.map(\.song.id))
                if let nowPlayingID = appState.nowPlaying?.id {
                    ids.append(nowPlayingID)
                }
                return (
                    fixtureConfigurationAbsent: appState.captureFixtureConfiguration == nil,
                    fixtureCatalogAbsent: appState.parityFixtureCatalog == nil,
                    databaseProductionBacked: !appState.databaseManager.isInjectedDatabase,
                    networkMonitorActive: !appState.networkMonitor.isInert,
                    schedulerEnabled: appState.libraryRefreshScheduler != nil,
                    fixtureEntityCount: ids.filter { $0.hasPrefix("atlas-") }.count
                )
            }
            Self.writeNormalSmokeAuditArtifact(
                environment: environment,
                fixtureConfigurationAbsent: snapshot.fixtureConfigurationAbsent,
                fixtureCatalogAbsent: snapshot.fixtureCatalogAbsent,
                databaseProductionBacked: snapshot.databaseProductionBacked,
                networkMonitorActive: snapshot.networkMonitorActive,
                schedulerEnabled: snapshot.schedulerEnabled,
                fixtureEntityCount: snapshot.fixtureEntityCount
            )
        }
    }

    /// Optional machine-readable audit artifact used by the external
    /// isolation verifier. The destination must resolve beneath a temporary
    /// directory, and this path is never consulted during normal launch.
    private nonisolated static func writeFixtureAuditScheduledArtifact(
        environment: [String: String],
        route: String
    ) {
        guard environment["RESONANCE_PARITY_AUDIT"] == "1",
              let rawPath = environment["RESONANCE_PARITY_AUDIT_LOG"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return
        }

        let requestedURL = URL(fileURLWithPath: rawPath, isDirectory: false)
        let resolvedParent = requestedURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedURL = resolvedParent.appendingPathComponent(requestedURL.lastPathComponent)
        guard resolvedURL.path.hasPrefix("/private/tmp/")
                || resolvedURL.path.hasPrefix("/tmp/") else {
            return
        }

        let payload: [String: Any] = [
            "event": "fixtureAuditLifecycle",
            "stage": "scheduled",
            "route": route
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        data.append(0x0A)
        try? data.write(to: resolvedURL, options: [.atomic])
    }

    private nonisolated static func writeFixtureAuditArtifact(
        environment: [String: String],
        route: String,
        networkAudit: NetworkFixtureAuditSnapshot,
        playerItemCreationCount: Int,
        keychainOperationCount: Int,
        databaseInjected: Bool,
        scratchRootTemporary: Bool,
        networkMonitorInert: Bool,
        schedulerDisabled: Bool,
        companionDisabled: Bool
    ) {
        guard environment["RESONANCE_PARITY_AUDIT"] == "1",
              let rawPath = environment["RESONANCE_PARITY_AUDIT_LOG"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return
        }

        let requestedURL = URL(fileURLWithPath: rawPath, isDirectory: false)
        let resolvedParent = requestedURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedURL = resolvedParent.appendingPathComponent(requestedURL.lastPathComponent)
        let systemTemporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        let systemTemporaryAlias = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let processTemporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let allowedRoots = [systemTemporaryRoot, systemTemporaryAlias, processTemporaryRoot]
        let isTemporaryDestination = allowedRoots.contains { root in
            resolvedURL.path.hasPrefix(root.path + "/")
        }
        guard isTemporaryDestination else {
            print("[ParityFixtureAudit] artifact=rejected reason=non-temporary-destination")
            return
        }

        let payload: [String: Any] = [
            "event": "fixtureAudit",
            "stage": "settled",
            "route": route,
            "transportRequestCount": networkAudit.transportRequestCount,
            "blockedCallCount": networkAudit.blockedCallCount,
            "scrobbleAttemptCount": networkAudit.scrobbleAttemptCount,
            "playerItemCreationCount": playerItemCreationCount,
            "keychainOperationCount": keychainOperationCount,
            "databaseInjected": databaseInjected,
            "productionDatabaseUnopened": databaseInjected && scratchRootTemporary,
            "scratchRootTemporary": scratchRootTemporary,
            "cachePathsTemporary": scratchRootTemporary,
            "networkMonitorInert": networkMonitorInert,
            "schedulerDisabled": schedulerDisabled,
            "companionDisabled": companionDisabled,
            "preferencePersistenceGated": true,
            "scrobbleDisabled": networkAudit.scrobbleAttemptCount == 0
        ]
        do {
            var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            data.append(0x0A)
            try data.write(to: resolvedURL, options: [.atomic])
            print("[ParityFixtureAudit] artifact=written")
        } catch {
            print("[ParityFixtureAudit] artifact=failed")
        }
    }

    private nonisolated static func writeNormalSmokeAuditArtifact(
        environment: [String: String],
        fixtureConfigurationAbsent: Bool,
        fixtureCatalogAbsent: Bool,
        databaseProductionBacked: Bool,
        networkMonitorActive: Bool,
        schedulerEnabled: Bool,
        fixtureEntityCount: Int
    ) {
        guard let rawPath = environment["RESONANCE_NORMAL_AUDIT_LOG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty else {
            return
        }

        let requestedURL = URL(fileURLWithPath: rawPath, isDirectory: false)
        let resolvedParent = requestedURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedURL = resolvedParent.appendingPathComponent(requestedURL.lastPathComponent)
        guard isTemporaryFixtureRoot(resolvedParent) else {
            print("[ResonanceLaunchAudit] artifact=rejected reason=non-temporary-destination")
            return
        }

        let payload: [String: Any] = [
            "event": "normalLaunchAudit",
            "stage": "settled",
            "fixtureConfigurationAbsent": fixtureConfigurationAbsent,
            "fixtureCatalogAbsent": fixtureCatalogAbsent,
            "databaseProductionBacked": databaseProductionBacked,
            "networkMonitorActive": networkMonitorActive,
            "schedulerEnabled": schedulerEnabled,
            "fixtureEntityCount": fixtureEntityCount
        ]
        do {
            var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            data.append(0x0A)
            try data.write(to: resolvedURL, options: [.atomic])
            print("[ResonanceLaunchAudit] artifact=written")
        } catch {
            print("[ResonanceLaunchAudit] artifact=failed")
        }
    }

    /// Accept an explicit scratch root only beneath a system temporary root.
    /// Direct launches therefore cannot repoint fixture writes at arbitrary
    /// user data; missing or unsafe values get a process-unique fallback.
    private static func fixtureScratchRoot(
        for fixture: DeterministicCaptureFixture.Configuration?
    ) -> URL? {
        guard let fixture else { return nil }

        let fileManager = FileManager.default
        if let requested = fixture.scratchRoot?
            .standardizedFileURL
            .resolvingSymlinksInPath() {
            if isTemporaryFixtureRoot(requested) {
                return requested
            }
            print("[ParityFixture] non-temporary scratch root rejected; using process temporary storage")
        }

        return fileManager.temporaryDirectory
            .appendingPathComponent(
                "ResonanceParity-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private nonisolated static func isTemporaryFixtureRoot(_ candidate: URL) -> Bool {
        let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let roots = [
            URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            URL(fileURLWithPath: "/tmp", isDirectory: true),
            FileManager.default.temporaryDirectory
        ]
        .map { $0.standardizedFileURL.resolvingSymlinksInPath() }

        return roots.contains { root in
            resolvedCandidate.path.hasPrefix(root.path + "/")
        }
    }

    /// Seeds only in-memory state for a capture launch. This deliberately does
    /// not call PlaybackManager.play(_:), which would resolve a URL and start
    /// AVPlayer/network work. The queue is populated directly so the live
    /// footer has a current item and a next item for deterministic AX state.
    private func installDeterministicCaptureFixture(
        _ fixture: DeterministicCaptureFixture.Configuration
    ) {
        if fixture.isAtlas, let catalog = parityFixtureCatalog {
            installParityAtlasFixture(fixture, catalog: catalog)
            return
        }

        let songs = DeterministicCaptureFixture.songs
        queueManager.play(songs, startingAt: 0)
        nowPlaying = songs[0]
        playbackManager.installDeterministicCaptureFixture(
            isPlaying: fixture.playbackMode.isPlaying,
            currentTime: fixture.currentTime,
            duration: fixture.duration,
            supportsSeeking: fixture.supportsSeeking
        )

        connectionStatus = .disconnected
        activeServer = nil
        servers = []
        selectedSidebarItem = .home
        currentTime = fixture.currentTime
        duration = fixture.duration
        playbackState = fixture.playbackMode.isPlaying ? .playing : .paused
    }

    private func installParityAtlasFixture(
        _ fixture: DeterministicCaptureFixture.Configuration,
        catalog: ParityFixtureCatalog
    ) {
        guard let serverUUID = UUID(uuidString: catalog.serverId),
              !catalog.songs.isEmpty else {
            fatalError("Parity fixture catalog has an invalid server ID or no songs")
        }

        let fixtureServer = Server(
            id: serverUUID,
            name: ParityFixtureCatalog.serverName,
            url: URL(string: "https://parity-fixture.invalid")!,
            username: "fixture"
        )

        let nowPlayingSong: Song
        switch fixture.state {
        case .plain:
            nowPlayingSong = catalog.songs[min(1, catalog.songs.count - 1)]
        case .noLyrics:
            nowPlayingSong = catalog.songs[min(2, catalog.songs.count - 1)]
        default:
            nowPlayingSong = catalog.songs[0]
        }

        let currentQueueItem = QueueItem(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000090")!,
            song: nowPlayingSong
        )
        let remainingQueue = catalog.queue.filter { $0.song.id != nowPlayingSong.id }
        let baseItems = [currentQueueItem] + Array(remainingQueue.prefix(2))
        let upNextItems = Array(remainingQueue.dropFirst(2).prefix(2))
        let autoPlayItems = Array(remainingQueue.dropFirst(4))
        let isEmptyQueueFixture = fixture.route == .queue && fixture.state == .empty
        if isEmptyQueueFixture {
            queueManager.installDeterministicEmptyFixture()
        } else {
            queueManager.installDeterministicFixture(
                baseItems: baseItems,
                currentIndex: 0,
                upNextItems: upNextItems,
                autoPlayItems: autoPlayItems,
                history: catalog.queueHistory
            )
        }

        nowPlaying = nowPlayingSong
        playbackManager.installDeterministicCaptureFixture(
            isPlaying: fixture.playbackMode.isPlaying,
            currentTime: fixture.currentTime,
            duration: fixture.duration,
            supportsSeeking: fixture.supportsSeeking
        )
        playbackManager.activeServerId = catalog.serverId

        activeServer = fixtureServer
        servers = [fixtureServer]
        connectionStatus = .connected
        artists = catalog.artists
        albums = catalog.albums
        fullAlbumCatalogServerID = fixtureServer.id.uuidString
        playlists = catalog.playlists
        smartPlaylists = catalog.smartPlaylists
        hiddenSongIds = []
        hiddenAlbumIds = []
        hiddenArtistIds = []
        likedSongIds = catalog.likedSongIDs
        admittedSongIds = Set(catalog.songs.map(\.id))
        admittedAlbumIds = Set(catalog.albums.map(\.id))
        admittedArtistIds = Set(catalog.artists.map(\.id))
        libraryMembershipRevision &+= 1
        unseenDiscoveryCount = catalog.albums.count
        unclassifiedCount = 2
        currentTime = fixture.currentTime
        duration = fixture.duration
        playbackState = fixture.playbackMode.isPlaying ? .playing : .paused
        selectedSidebarItem = .home
        searchQuery = ""
        nowPlayingInspector = nil
        detailNavigationPath = NavigationPath()

        switch fixture.route {
        case .shell, .home, .footer, .miniPlayerArtwork, .miniPlayerQueue,
                .miniPlayerLyrics, .fullscreenNowPlaying:
            selectedSidebarItem = .home
        case .recentlyAdded:
            selectedSidebarItem = .recentlyAdded
        case .recentlyPlayed:
            selectedSidebarItem = .recentlyPlayed
        case .albums:
            selectedSidebarItem = .albums
        case .albumDetail:
            selectedSidebarItem = .albums
            detailNavigationPath.append(catalog.albums[min(3, catalog.albums.count - 1)])
        case .artists:
            selectedSidebarItem = .artists
        case .artistDetail:
            selectedSidebarItem = .artists
            detailNavigationPath.append(catalog.artists[min(1, catalog.artists.count - 1)])
        case .songs:
            selectedSidebarItem = .songs
        case .genres:
            selectedSidebarItem = .genres
        case .genreDetail:
            selectedSidebarItem = .genres
            detailNavigationPath.append(
                catalog.genres.first(where: { $0.name == "Electronic" }) ?? catalog.genres[0]
            )
        case .playlists:
            selectedSidebarItem = .playlists
        case .playlistDetail:
            selectedSidebarItem = .playlists
            detailNavigationPath.append(catalog.playlists[min(2, catalog.playlists.count - 1)])
        case .smartPlaylist:
            selectedSidebarItem = .playlists
            if let smartPlaylist = catalog.smartPlaylists.first {
                detailNavigationPath.append(smartPlaylist)
            }
        case .likedSongs:
            selectedSidebarItem = .favorites
        case .search:
            selectedSidebarItem = .search
        case .searchResults:
            selectedSidebarItem = .search
            searchQuery = ProcessInfo.processInfo.environment["RESONANCE_PARITY_SEARCH_QUERY"] ?? "neon"
        case .searchNoResults:
            selectedSidebarItem = .search
            searchQuery = "zzzz-no-match"
        case .queue:
            selectedSidebarItem = .home
            nowPlayingInspector = .queue
        case .lyrics:
            selectedSidebarItem = .home
            nowPlayingInspector = .lyrics
        }
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

            let generation = connectionGeneration
            Task {
                guard activeServer == server, connectionGeneration == generation else { return }
                await networkActor.configure(
                    server: server,
                    password: PublicDemoConfiguration.serverPassword
                )
                guard !Task.isCancelled, activeServer == server,
                      connectionGeneration == generation else { return }
                await connect()
            }
        }

        // Decode the scoped full-song queue; staging below never starts playback.
        if let data = UserDefaults.standard.data(forKey: Self.persistedPlaybackKey),
           let persisted = try? JSONDecoder().decode(PersistedPlaybackState.self, from: data) {
            pendingQueueRestore = persisted
        }
        // Restore metadata and the paused queue independently of navigation/network.
        if let server = activeServer {
            loadCachedLibrary(serverId: server.id.uuidString)
            restorePersistedQueue()
        }
    }

    /// Synchronous launch staging: no audio, history, scrobble, or notification.
    func restorePersistedQueue() {
        guard !DeterministicCaptureFixture.isEnabled,
              let persisted = pendingQueueRestore else { return }
        pendingQueueRestore = nil
        guard let serverID = activeServerId else { return }
        // Resolve visibility once for the complete persisted queue.  Calling
        // visibleSongsForPlayback per occurrence would reload these same sets
        // three times for every restored song.
        let hiddenSongIds = loadHiddenIdsForPlayback(type: "song", serverId: serverID)
        let hiddenAlbumIds = loadHiddenIdsForPlayback(type: "album", serverId: serverID)
        let hiddenArtistIds = loadHiddenIdsForPlayback(type: "artist", serverId: serverID)
        guard let resolved = persisted.resolved(for: serverID, visible: { song in
            !hiddenSongIds.contains(song.id)
                && !hiddenAlbumIds.contains(song.albumId)
                && !hiddenArtistIds.contains(song.artistId)
        }) else { return }
        let remember = (UserDefaults.standard.object(forKey: "rememberPlaybackPosition") as? Bool) ?? true
        launchRestoreTicket = playbackManager.stagePausedRestore(
            songs: resolved.songs, startingAt: resolved.index,
            position: remember ? resolved.position : 0, serverID: serverID
        )
    }

    private func setupBindings(observeNetwork: Bool = true) {
        if observeNetwork {
            // Observe network status using Swift Observation
            Task {
                await observeNetworkStatus()
            }
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
        guard !DeterministicCaptureFixture.isEnabled else { return }

        // Only save position if rememberPlaybackPosition is enabled
        let rememberPosition = (UserDefaults.standard.object(forKey: "rememberPlaybackPosition") as? Bool) ?? true
        // Save base items as the queue (upNext is ephemeral, not persisted)
        let persisted = PersistedPlaybackState(
            serverID: activeServerId,
            queueSongs: queueManager.baseItems.map { $0.song },
            queueIndex: max(0, queueManager.basePosition),
            lastPosition: rememberPosition && queueManager.baseItems.indices.contains(queueManager.basePosition)
                && queueManager.currentItem?.id == queueManager.baseItems[queueManager.basePosition].id
                ? currentTime : 0,
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

        connectionGeneration &+= 1
        let generation = connectionGeneration
        connectionStatus = .connecting

        do {
            // Test connection via ping - networkActor must already be configured
            _ = try await networkActor.ping()
            guard !Task.isCancelled, connectionGeneration == generation, activeServer == server else { return }
            connectionStatus = .connected
            playbackManager.activeServerId = server.id.uuidString
            if let ticket = launchRestoreTicket {
                launchRestoreTicket = nil
                if UserDefaults.standard.bool(forKey: "autoPlayOnLaunch") {
                    await playbackManager.resumeRestoredIfCurrent(ticket: ticket)
                }
            }
        } catch {
            guard !Task.isCancelled, connectionGeneration == generation, activeServer == server else { return }
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
        fixtureBoundaryAudit.recordKeychainOperation()
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

        fixtureBoundaryAudit.recordKeychainOperation()
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

        fixtureBoundaryAudit.recordKeychainOperation()
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
        fixtureBoundaryAudit.recordKeychainOperation()
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
            let hiddenArtistIds = self.hiddenArtistIds

            // Albums are loaded only for complete-catalog consumers such as Plane.
            // Album and Home surfaces read bounded pages or point rows from SQLite.
            invalidateFullAlbumCatalog()

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

    func invalidateFullAlbumCatalog() {
        fullAlbumCatalogLoader.invalidate()
        fullAlbumCatalogServerID = nil
        albums = []
    }

    /// Plane opts into the complete admitted catalog; a page never populates
    /// `albums`. The catalog epoch also rejects same-server invalidation races.
    func ensureFullAlbumCatalog(expectedServerID: UUID) async throws {
        let serverID = expectedServerID.uuidString
        guard activeServer?.id == expectedServerID else { throw CancellationError() }
        if fullAlbumCatalogServerID == serverID { return }
        let connection = connectionGeneration
        let catalogGeneration = fullAlbumCatalogLoader.generation
        let database = databaseManager
        let loaded = try await fullAlbumCatalogLoader.ensure(serverID: serverID) {
            try await database.fullAlbumCatalog(serverID: serverID)
        }
        guard !Task.isCancelled, activeServer?.id == expectedServerID,
              connectionGeneration == connection,
              fullAlbumCatalogLoader.generation == catalogGeneration else { throw CancellationError() }
        albums = loaded.map(presentedAlbum)
        fullAlbumCatalogServerID = serverID
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
        albumPresentationStore.setStarred(starred, for: id)
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
    @discardableResult
    func updateAlbumRating(id: String, rating: Int?) -> UInt64 {
        if let index = albums.firstIndex(where: { $0.id == id }) {
            albums[index].rating = rating
        }
        return albumPresentationStore.setRating(rating, for: id)
    }

    func confirmAlbumRating(id: String, actionRevision: UInt64) {
        albumPresentationStore.confirmRating(for: id, actionRevision: actionRevision)
    }

    func rejectAlbumRating(id: String, actionRevision: UInt64) {
        guard albumPresentationStore.rejectRating(for: id, actionRevision: actionRevision) else { return }
        // The optimistic value may be present in Plane's complete array.
        // Re-read the confirmed cache on next demand instead of restoring a
        // possibly stale value from the menu that started this action.
        invalidateFullAlbumCatalog()
    }

    func presentedAlbum(_ album: Album) -> Album {
        albumPresentationStore.presented(album)
    }

    /// Server albums fetched after `revision` supersede only earlier local
    /// presentation actions. A love/rating action during the fetch remains.
    func reconcileAlbumPresentationOverrides(through revision: UInt64) {
        albumPresentationStore.reconcile(through: revision)
    }

    // MARK: - Window Management

    /// Reference to emotion engine for window management
    var emotionEngine: EmotionEngine?

    /// The retained controller mirrors Music's native MiniPlayer ownership:
    /// one titled window, one hosted compositor, one close lifecycle.
    private var miniPlayerWindowController: MiniPlayerWindowController?

    /// The primary window hidden while the mini player is open.
    private var mainWindowBeforeMiniPlayer: NSWindow?

    /// Track immersive mode window
    private var immersiveWindow: NSWindow?

    /// Delegate for immersive window lifecycle events
    private var immersiveWindowDelegate: ImmersiveWindowDelegate?

    func showMiniPlayer(
        initialMode: MiniPlayerMode? = nil,
        activate: Bool = true
    ) {
        // Repeated requests reveal the retained native controller. Content
        // modes are changed inside the square; opening never replaces it.
        if let controller = miniPlayerWindowController,
           controller.window != nil {
            controller.present(activate: activate)
            return
        }

        let mainWindow = NSApp.windows.first {
            $0.identifier?.rawValue == "mainWindow"
        }
        mainWindowBeforeMiniPlayer = mainWindow

        let fixtureMode = DeterministicCaptureFixture.isEnabled
        let mode = initialMode ?? MiniPlayerMode.persisted
        let controller = MiniPlayerWindowController(
            appState: self,
            initialMode: mode,
            persistsModeChanges: initialMode == nil && !fixtureMode,
            autosavesFrame: !fixtureMode,
            level: .floating
        ) { [weak self] closingWindow in
            self?.miniPlayerDidClose(closingWindow)
        }

        miniPlayerWindowController = controller
        mainWindow?.orderOut(nil)
        controller.present(activate: activate)
    }

    private func miniPlayerDidClose(_ window: NSWindow) {
        guard miniPlayerWindowController?.window === window else { return }

        miniPlayerWindowController = nil

        let mainWindow = mainWindowBeforeMiniPlayer
            ?? NSApp.windows.first { $0.identifier?.rawValue == "mainWindow" }
        mainWindowBeforeMiniPlayer = nil
        if DeterministicCaptureFixture.isEnabled {
            mainWindow?.orderFront(nil)
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func enterImmersiveMode(
        activate: Bool = true,
        enterNativeFullScreen: Bool = true
    ) {
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
        window.identifier = NSUserInterfaceItemIdentifier("immersivePlayer")
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
            guard let self else { return }
            self.immersiveWindow = nil
            guard self.miniPlayerWindowController == nil else { return }
            let mainWindow = NSApp.windows.first {
                $0.identifier?.rawValue == "mainWindow"
            }
            if DeterministicCaptureFixture.isEnabled {
                mainWindow?.orderFront(nil)
            } else {
                mainWindow?.makeKeyAndOrderFront(nil)
            }
        }
        window.delegate = delegate
        immersiveWindowDelegate = delegate  // Retain the delegate

        if activate {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak window] in
                guard let self, let window, self.immersiveWindow === window else { return }
                window.orderFrontRegardless()
            }
        }
        if enterNativeFullScreen {
            window.toggleFullScreen(nil)
        }
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
        guard !DeterministicCaptureFixture.isEnabled else { return }
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
    /// Missing on legacy payloads: never infer their server from the current account.
    let serverID: String?
    /// Full song objects for queue restoration (avoids 10k song fetch on launch)
    let queueSongs: [Song]
    let queueIndex: Int
    let lastPosition: TimeInterval
    let timestamp: Date

    /// Migration: decode old format (queueSongIds) gracefully
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try container.decodeIfPresent(String.self, forKey: .serverID)
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

    init(serverID: String? = nil, queueSongs: [Song], queueIndex: Int, lastPosition: TimeInterval, timestamp: Date) {
        self.serverID = serverID
        self.queueSongs = queueSongs
        self.queueIndex = queueIndex
        self.lastPosition = lastPosition
        self.timestamp = timestamp
    }

    struct Resolved {
        let songs: [Song]
        let index: Int
        let position: TimeInterval
    }

    func resolved(for activeServerID: String, visible: (Song) -> Bool) -> Resolved? {
        guard serverID == activeServerID, !activeServerID.isEmpty, !queueSongs.isEmpty else { return nil }
        let sourceIndex = max(0, min(queueIndex, queueSongs.count - 1))
        let retained = queueSongs.enumerated().filter { visible($0.element) }
        guard !retained.isEmpty else { return nil }
        let index = retained.firstIndex { $0.offset >= sourceIndex } ?? retained.count - 1
        let sameOccurrence = retained[index].offset == sourceIndex
        let position = sameOccurrence && lastPosition.isFinite
            ? max(0, min(lastPosition, TimeInterval(retained[index].element.duration))) : 0
        return Resolved(songs: retained.map(\.element), index: index, position: position)
    }
}

// MARK: - Window Delegates


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
