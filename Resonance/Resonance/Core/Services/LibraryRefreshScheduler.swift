import Foundation
import SwiftUI
import Combine
import UserNotifications

@MainActor
struct LibraryRefreshExecutor {
    struct Operations: Sendable {
        let fetchArtists: @MainActor @Sendable () async throws -> [Artist]
        let fetchAlbums: @MainActor @Sendable () async throws -> AlbumLibraryFetchResult
        let fetchSongs: @MainActor @Sendable (
            _ onPage: @escaping @MainActor @Sendable ([Song]) async throws -> Void
        ) async throws -> SongLibraryFetchResult
        let fetchStarred: @MainActor @Sendable () async throws -> StarredContent
        /// Throws cancellation when the server/folder/configuration captured by
        /// this refresh is no longer the active library origin.
        let validateOrigin: @MainActor @Sendable () throws -> Void

        let knownAlbumIds: @MainActor @Sendable () throws -> Set<String>
        let saveArtists: @MainActor @Sendable ([Artist]) throws -> Void
        let saveAlbums: @MainActor @Sendable ([Album]) throws -> Void
        let saveSongs: @MainActor @Sendable ([Song]) throws -> Void
        let syncStarred: @MainActor @Sendable (StarredContent) throws -> Void
        let importLikedSongs: @MainActor @Sendable ([Song]) throws -> Int

        let hiddenArtistIds: @MainActor @Sendable () throws -> Set<String>
        let hiddenAlbumIds: @MainActor @Sendable () throws -> Set<String>
        let admittedArtists: @MainActor @Sendable () throws -> [Artist]
        let admittedAlbums: @MainActor @Sendable () throws -> [Album]
        let refreshMembership: @MainActor @Sendable () -> Void
        let refreshLikedIds: @MainActor @Sendable () -> Void
        let applyArtists: @MainActor @Sendable ([Artist]) -> Void
        let applyAlbums: @MainActor @Sendable ([Album]) -> Void

        /// Generation sweep for one cached table. Receives the sync's start time;
        /// rows older than it were not returned by the server this sync.
        let pruneStale: @MainActor @Sendable (DatabaseManager.PrunableLibraryItem, Date) throws -> DatabaseManager.LibraryPruneResult

        let getMetadata: @MainActor @Sendable (String) throws -> String?
        let setMetadata: @MainActor @Sendable (String, String) throws -> Void
        let recordDiscoveredAlbums: @MainActor @Sendable ([String]) throws -> Void
        let updateDiscoveryCount: @MainActor @Sendable () -> Void
        let notifyNewAlbums: @MainActor @Sendable ([Album]) -> Void
    }

    struct Summary: Sendable {
        let persistedLegs: Set<String>
        let failures: [String: String]
        let songCount: Int
        /// Sweep outcome per leg, for legs that were eligible to sweep at all.
        /// A leg absent from this map was never swept (it failed, or its walk
        /// was truncated) — which is different from being swept and removing 0.
        var pruneResults: [String: DatabaseManager.LibraryPruneResult] = [:]
    }

    @MainActor
    private final class SongProgress {
        var persistedBatchCount = 0
        var persistedSongCount = 0

        func record(_ count: Int) {
            persistedBatchCount += 1
            persistedSongCount += count
        }
    }

    private static func captured<T: Sendable>(
        _ operation: @MainActor @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    static func run(
        serverId: String,
        now: Date = Date(),
        operations: Operations
    ) async -> Summary {
        let songProgress = SongProgress()

        do {
            try operations.validateOrigin()
        } catch {
            return Summary(persistedLegs: [], failures: [:], songCount: 0)
        }

        async let artistsFetch = captured(operations.fetchArtists)
        async let albumsFetch = captured(operations.fetchAlbums)
        async let songsFetch = captured {
            try await operations.fetchSongs { songs in
                try operations.validateOrigin()
                try operations.saveSongs(songs)
                songProgress.record(songs.count)
            }
        }
        async let starredFetch = captured(operations.fetchStarred)

        let results = await (
            artistsFetch,
            albumsFetch,
            songsFetch,
            starredFetch
        )
        let (artistsResult, albumsResult, songsResult, starredResult) = results

        // No result from an obsolete or canceled refresh may mutate the cache,
        // current UI, discovery ledger, sweep state, or last-sync metadata.
        do {
            try operations.validateOrigin()
        } catch {
            let persisted: Set<String> = songProgress.persistedBatchCount > 0 ? ["songs"] : []
            return Summary(
                persistedLegs: persisted,
                failures: [:],
                songCount: songProgress.persistedSongCount
            )
        }

        let timestamp = ISO8601DateFormatter().string(from: now)
        var persistedLegs = Set<String>()
        var failures: [String: String] = [:]
        var songCount = songProgress.persistedSongCount

        func recordFailure(_ leg: String, _ error: Error) {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            let description = error.localizedDescription
            failures[leg] = description
            let value = "\(timestamp) — \(description)"
            do {
                try operations.setMetadata("lastSyncError.\(leg).\(serverId)", value)
            } catch {
                print("[LibraryRefreshScheduler] Failed to record \(leg) sync error: \(error.localizedDescription)")
            }
            print("[LibraryRefreshScheduler] \(leg) sync failed: \(description)")
        }

        /// Record whether a leg's paginated walk actually reached the end.
        ///
        /// A leg can persist rows, throw nothing, and still have enumerated only
        /// a fraction of the server's library. Without this marker that state is
        /// indistinguishable from a clean sync, and anything destructive gated on
        /// "the leg succeeded" would act on a partial view of the library.
        func recordWalk(_ leg: String, _ walk: LibraryWalkOutcome) {
            let key = "lastSyncTruncated.\(leg).\(serverId)"
            do {
                if let reason = walk.truncationReason {
                    try operations.setMetadata(key, "\(timestamp) — \(reason)")
                    print("[LibraryRefreshScheduler] \(leg) sync TRUNCATED: \(reason)")
                } else {
                    // Clear any stale marker from an earlier partial sync.
                    try operations.setMetadata(key, "")
                }
            } catch {
                print("[LibraryRefreshScheduler] Failed to record \(leg) walk outcome: \(error.localizedDescription)")
            }
        }

        // Walk completeness per leg, defaulting to "not proven complete".
        //
        // The default matters more than the assignment: a leg that threw, or
        // that persisted a partial page set before failing, must never look
        // eligible for a destructive sweep. Only an explicit `.complete` from a
        // successful walk clears it.
        var albumWalk = LibraryWalkOutcome.truncated(reason: "albums leg did not complete")
        var songWalk = LibraryWalkOutcome.truncated(reason: "songs leg did not complete")

        switch artistsResult {
        case .success(let artists):
            do {
                try operations.saveArtists(artists)
                persistedLegs.insert("artists")
                let hiddenIds = (try? operations.hiddenArtistIds()) ?? []
                let admitted = (try? operations.admittedArtists()) ?? artists
                operations.applyArtists(hiddenIds.isEmpty ? admitted : admitted.filter { !hiddenIds.contains($0.id) })
            } catch {
                recordFailure("artists", error)
            }
        case .failure(let error):
            recordFailure("artists", error)
        }

        switch albumsResult {
        case .success(let albumResult):
            let albums = AlbumSanitizer.sanitize(albumResult.albums)
            albumWalk = albumResult.walk
            recordWalk("albums", albumResult.walk)
            do {
                // The discovery diff must precede persistence or every fetched ID
                // becomes "known" before it can be classified as an arrival.
                let knownIds = try operations.knownAlbumIds()
                let newAlbumIds = albums.filter { !knownIds.contains($0.id) }.map(\.id)
                try operations.saveAlbums(albums)
                persistedLegs.insert("albums")

                let hiddenIds = (try? operations.hiddenAlbumIds()) ?? []
                let admitted = (try? operations.admittedAlbums()) ?? albums
                operations.applyAlbums(hiddenIds.isEmpty ? admitted : admitted.filter { !hiddenIds.contains($0.id) })

                let baselineKey = LibraryRefreshScheduler.discoveryBaselineKey(serverId: serverId)
                if try operations.getMetadata(baselineKey) == nil {
                    try operations.setMetadata(baselineKey, timestamp)
                } else if !newAlbumIds.isEmpty {
                    try operations.recordDiscoveredAlbums(newAlbumIds)
                    operations.updateDiscoveryCount()
                    operations.notifyNewAlbums(albums.filter { newAlbumIds.contains($0.id) })
                }
            } catch {
                recordFailure("albums", error)
            }
        case .failure(let error):
            recordFailure("albums", error)
        }

        switch songsResult {
        case .success(let result):
            songCount = result.songCount
            persistedLegs.insert("songs")
            songWalk = result.walk
            recordWalk("songs", result.walk)
            var pathValue = "\(timestamp) — \(result.path.rawValue)"
            if let reason = result.fallbackReason {
                pathValue += " — \(reason)"
            }
            do {
                try operations.setMetadata("lastSyncPath.songs.\(serverId)", pathValue)
            } catch {
                print("[LibraryRefreshScheduler] Failed to record song sync path: \(error.localizedDescription)")
            }
            print("[LibraryRefreshScheduler] Song sync used \(result.path.rawValue)")
        case .failure(let error):
            if songProgress.persistedBatchCount > 0 {
                persistedLegs.insert("songs")
            }
            if error is SongLibraryFallbackError {
                try? operations.setMetadata(
                    "lastSyncPath.songs.\(serverId)",
                    "\(timestamp) — \(SongLibraryFetchPath.albumEnumeration.rawValue) — failed"
                )
            }
            recordFailure("songs", error)
        }

        switch starredResult {
        case .success(let starred):
            do {
                try operations.saveSongs(starred.songs)
                persistedLegs.insert("starred")
                try operations.syncStarred(starred)
                if try operations.importLikedSongs(starred.songs) > 0 {
                    operations.refreshLikedIds()
                }
            } catch {
                recordFailure("starred", error)
            }
        case .failure(let error):
            recordFailure("starred", error)
        }

        // Generation sweep — must run AFTER every leg that persists rows.
        //
        // The starred leg also calls `saveSongs`, so sweeping before it would
        // delete rows that were about to be re-stamped. Ordering here is not
        // stylistic.
        var pruneResults: [String: DatabaseManager.LibraryPruneResult] = [:]

        func sweep(_ leg: String, _ item: DatabaseManager.PrunableLibraryItem, walk: LibraryWalkOutcome) {
            // Three independent conditions, all required. A sweep is the only
            // thing here that destroys data, so it declines on any doubt.
            guard persistedLegs.contains(leg) else { return }
            guard failures[leg] == nil else { return }
            guard walk.isComplete else {
                print("[LibraryRefreshScheduler] Skipping \(leg) prune: \(walk.truncationReason ?? "walk incomplete")")
                return
            }

            do {
                let result = try operations.pruneStale(item, now)
                pruneResults[leg] = result
                if let refusal = result.refusalReason {
                    try? operations.setMetadata("lastSyncError.prune.\(leg).\(serverId)", "\(timestamp) — \(refusal)")
                    print("[LibraryRefreshScheduler] \(leg) prune REFUSED: \(refusal)")
                } else {
                    try? operations.setMetadata("lastSyncError.prune.\(leg).\(serverId)", "")
                    if result.removed > 0 {
                        print("[LibraryRefreshScheduler] \(leg) prune removed \(result.removed) stale rows")
                    }
                }
            } catch {
                print("[LibraryRefreshScheduler] \(leg) prune failed: \(error.localizedDescription)")
            }
        }

        sweep("songs", .song, walk: songWalk)
        sweep("albums", .album, walk: albumWalk)
        // Artists come from an unpaginated `getArtists`, so a successful leg is
        // by definition a complete enumeration — there is no walk to truncate.
        sweep("artists", .artist, walk: .complete)

        if !persistedLegs.isEmpty {
            operations.refreshMembership()
            do {
                try operations.setMetadata("lastSync.\(serverId)", timestamp)
            } catch {
                print("[LibraryRefreshScheduler] Failed to record lastSync: \(error.localizedDescription)")
            }

            // Liveness breadcrumb, written on every sync including zero-removal
            // ones. Without it, a sweep that silently stopped firing (a gate
            // never satisfied, say a permanently truncated walk) is invisible
            // until ghosts have already piled up.
            let summary = DatabaseManager.PrunableLibraryItem.allCases
                .map { item -> String in
                    let leg = item.syncLeg
                    guard let result = pruneResults[leg] else { return "\(leg)=skipped" }
                    return result.wasRefused ? "\(leg)=refused" : "\(leg)=\(result.removed)"
                }
                .joined(separator: " ")
            try? operations.setMetadata("lastPrune.\(serverId)", "\(timestamp) — \(summary)")
        }

        return Summary(
            persistedLegs: persistedLegs,
            failures: failures,
            songCount: songCount,
            pruneResults: pruneResults
        )
    }
}

/// Schedules automatic library refreshes based on user preference.
/// Only runs when app is active (not backgrounded).
@MainActor
final class LibraryRefreshScheduler: ObservableObject {
    private weak var appState: AppState?
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var activeRefreshServerID: String?
    private var activeRefreshUsesMinimumInterval = false
    private var activeRefreshStartedAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var lastObservedConnection: (status: ConnectionStatus, serverId: String?)?
    private var lastObservedOrigin: String?
    private var lastOneShotStartedAt: [String: Date] = [:]
    private let now: () -> Date
    private let connectionSnapshotOverride: (() -> (ConnectionStatus, String?))?
    private let connectionOriginOverride: (() -> String?)?
    private let successfulSyncOverride: ((String) -> Bool)?
    private let refreshOverride: (() async -> Void)?

    private static let oneShotMinimumInterval: TimeInterval = 3 * 60

    private enum RefreshTrigger {
        case connection
        case activationWithoutSuccessfulSync
        case periodic
        case manual

        var usesMinimumInterval: Bool {
            switch self {
            case .connection, .activationWithoutSuccessfulSync:
                true
            case .periodic, .manual:
                false
            }
        }
    }

    /// UserDefaults key for the auto-refresh cadence, in minutes.
    /// `nonisolated` so Settings can name it from a non-MainActor initializer.
    nonisolated static let intervalDefaultsKey = "libraryRefreshInterval"

    /// Cadence used when the user has never picked one. Registered rather than
    /// written, so "Manual Only" (0) stays a real, selectable choice instead of
    /// being indistinguishable from "never touched". Without this the shipped
    /// default was 0 and the New Music ledger had no writer at all.
    nonisolated static let defaultIntervalMinutes = 15

    nonisolated static func registerDefaults() {
        UserDefaults.standard.register(defaults: [intervalDefaultsKey: defaultIntervalMinutes])
    }

    /// Sync-metadata key marking that this server's album list has been diffed
    /// at least once. Until it exists, a diff is cache seeding, not discovery.
    static func discoveryBaselineKey(serverId: String) -> String {
        "discoveryBaseline.\(serverId)"
    }

    /// Current interval in minutes (0 = manual only)
    private var currentInterval: Int {
        UserDefaults.standard.integer(forKey: Self.intervalDefaultsKey)
    }

    init(appState: AppState) {
        self.appState = appState
        self.now = Date.init
        self.connectionSnapshotOverride = nil
        self.connectionOriginOverride = nil
        self.successfulSyncOverride = nil
        self.refreshOverride = nil
        Self.registerDefaults()

        // Observe interval changes
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.rescheduleIfNeeded()
                self?.connectionStateDidChange()
            }
            .store(in: &cancellables)

        // Observe app activation state
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.handleAppBecameActive()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                self?.handleAppResignedActive()
            }
            .store(in: &cancellables)

        // Start if interval is set and app is active
        if NSApplication.shared.isActive {
            scheduleTimer()
        }

        observeConnectionState()
        connectionStateDidChange()
    }

    /// Narrow test seam for the trigger/debounce state machine. Refresh leg
    /// behavior is exercised separately through `LibraryRefreshExecutor`.
    init(
        connectionSnapshot: @escaping () -> (ConnectionStatus, String?),
        successfulSyncExists: @escaping (String) -> Bool,
        connectionOrigin: (() -> String?)? = nil,
        now: @escaping () -> Date = Date.init,
        refresh: @escaping () async -> Void
    ) {
        self.now = now
        self.connectionSnapshotOverride = connectionSnapshot
        self.connectionOriginOverride = connectionOrigin
        self.successfulSyncOverride = successfulSyncExists
        self.refreshOverride = refresh
    }

    func cleanup() {
        timer?.invalidate()
        timer = nil
        cancelActiveRefresh(restoringMinimumInterval: true)
    }

    // MARK: - Timer Management

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil

        let interval = currentInterval
        // "Manual Only" disables cadence polling, not the one-shot connection
        // bootstrap. The local cache is the product's working substrate; turning
        // off that bootstrap would leave a fresh install with no viable state.
        guard interval > 0 else { return }

        let seconds = TimeInterval(interval * 60)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestRefresh(trigger: .periodic)
            }
        }

        // Include in common run loop modes so it fires during scrolling etc
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func rescheduleIfNeeded() {
        // Only reschedule if app is active
        guard NSApplication.shared.isActive else {
            timer?.invalidate()
            timer = nil
            return
        }

        scheduleTimer()
    }

    private func handleAppBecameActive() {
        scheduleTimer()
        let snapshot = connectionSnapshot()
        guard case .connected = snapshot.0,
              let serverId = snapshot.1,
              !successfulSyncExists(serverId: serverId) else {
            return
        }
        requestRefresh(trigger: .activationWithoutSuccessfulSync)
    }

    private func handleAppResignedActive() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Refresh

    private func observeConnectionState() {
        guard let appState else { return }

        withObservationTracking {
            _ = appState.connectionStatus
            _ = appState.activeServerId
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeConnectionState()
                self.connectionStateDidChange()
            }
        }
    }

    private func connectionSnapshot() -> (ConnectionStatus, String?) {
        if let connectionSnapshotOverride {
            return connectionSnapshotOverride()
        }
        guard let appState else { return (.disconnected, nil) }
        return (appState.connectionStatus, appState.activeServerId)
    }

    private func successfulSyncExists(serverId: String) -> Bool {
        if let successfulSyncOverride {
            return successfulSyncOverride(serverId)
        }
        guard let appState else { return false }
        return ((try? appState.databaseManager.getSyncMetadata(key: "lastSync.\(serverId)")) ?? nil) != nil
    }

    /// Called by Swift Observation in production and directly by focused tests.
    func connectionStateDidChange() {
        let snapshot = connectionSnapshot()
        let previous = lastObservedConnection
        let origin = connectionOriginFingerprint()
        let previousOrigin = lastObservedOrigin
        lastObservedConnection = snapshot
        lastObservedOrigin = origin

        let originChanged = previous != nil && (
            previous?.status != snapshot.0
                || previous?.serverId != snapshot.1
                || previousOrigin != origin
        )
        if originChanged {
            cancelActiveRefresh(restoringMinimumInterval: true)
        }

        guard snapshot.0 == .connected, let serverId = snapshot.1 else { return }
        let needsRefresh = previous?.status != .connected
            || previous?.serverId != serverId
            || previousOrigin != origin
        guard needsRefresh else { return }

        requestRefresh(trigger: .connection)
    }

    private func connectionOriginFingerprint() -> String? {
        if let connectionOriginOverride {
            return connectionOriginOverride()
        }
        if connectionSnapshotOverride != nil {
            return connectionSnapshot().1
        }
        guard let appState, let server = appState.activeServer else { return nil }
        let folder = UserDefaults.standard.string(forKey: "libraryMusicFolderId") ?? ""
        return "\(server.id.uuidString)|\(server.url.absoluteString)|\(server.username)|\(folder)"
    }

    private func cancelActiveRefresh(restoringMinimumInterval: Bool) {
        if restoringMinimumInterval,
           refreshTask != nil,
           activeRefreshUsesMinimumInterval,
           let serverID = activeRefreshServerID,
           let startedAt = activeRefreshStartedAt,
           lastOneShotStartedAt[serverID] == startedAt {
            // A canceled connection bootstrap did not satisfy the debounce.
            // Preserve timestamps only for attempts that actually completed.
            lastOneShotStartedAt.removeValue(forKey: serverID)
        }
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        activeRefreshServerID = nil
        activeRefreshUsesMinimumInterval = false
        activeRefreshStartedAt = nil
    }

    private func requestRefresh(trigger: RefreshTrigger) {
        guard refreshTask == nil else { return }

        let snapshot = connectionSnapshot()
        guard snapshot.0 == .connected, let serverId = snapshot.1 else { return }

        let startedAt = now()
        if trigger.usesMinimumInterval,
           let previousStart = lastOneShotStartedAt[serverId],
           startedAt.timeIntervalSince(previousStart) < Self.oneShotMinimumInterval {
            return
        }
        if trigger.usesMinimumInterval {
            lastOneShotStartedAt[serverId] = startedAt
        }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        activeRefreshServerID = serverId
        activeRefreshUsesMinimumInterval = trigger.usesMinimumInterval
        activeRefreshStartedAt = startedAt
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let refreshOverride = self.refreshOverride {
                await refreshOverride()
            } else {
                await self.performRefresh()
            }
            guard self.refreshGeneration == generation else { return }
            self.refreshTask = nil
            self.activeRefreshServerID = nil
            self.activeRefreshUsesMinimumInterval = false
            self.activeRefreshStartedAt = nil
        }
    }

    private func performRefresh() async {
        guard let appState = appState else { return }

        // Only refresh if connected
        guard appState.connectionStatus == ConnectionStatus.connected else { return }
        guard let expectedServer = appState.activeServer else { return }
        let serverId = expectedServer.id.uuidString
        let configuredFolder = UserDefaults.standard.string(forKey: "libraryMusicFolderId") ?? ""
        let expectedMusicFolderID = configuredFolder.isEmpty ? nil : configuredFolder

        let database = appState.databaseManager
        let network = appState.networkActor
        let albumPresentationRevisionAtStart = appState.albumPresentationRevision
        let summary = await LibraryRefreshExecutor.run(
            serverId: serverId,
            now: now(),
            operations: .init(
                fetchArtists: {
                    try await network.fetchArtists(
                        expectedServerID: expectedServer.id,
                        expectedMusicFolderID: expectedMusicFolderID
                    )
                },
                fetchAlbums: {
                    try await network.fetchAllAlbums(
                        expectedServerID: expectedServer.id,
                        expectedMusicFolderID: expectedMusicFolderID
                    )
                },
                fetchSongs: { onPage in
                    try await network.fetchAllSongs(
                        expectedServerID: expectedServer.id,
                        expectedMusicFolderID: expectedMusicFolderID,
                        onPage: onPage
                    )
                },
                fetchStarred: {
                    try await network.fetchStarred2(
                        expectedServerID: expectedServer.id,
                        expectedMusicFolderID: expectedMusicFolderID
                    )
                },
                validateOrigin: {
                    try Task.checkCancellation()
                    let selectedFolder = UserDefaults.standard.string(forKey: "libraryMusicFolderId") ?? ""
                    let activeFolder = selectedFolder.isEmpty ? nil : selectedFolder
                    guard appState.connectionStatus == .connected,
                          appState.activeServer == expectedServer,
                          activeFolder == expectedMusicFolderID else {
                        throw CancellationError()
                    }
                },
                knownAlbumIds: { try database.knownAlbumIds(serverId: serverId) },
                saveArtists: { try database.saveArtists($0, serverId: serverId) },
                saveAlbums: { try database.saveAlbums($0, serverId: serverId) },
                saveSongs: { try database.saveSongs($0, serverId: serverId) },
                syncStarred: {
                    try database.syncStarredFromAPI(
                        songs: $0.songs,
                        albums: $0.albums,
                        artists: $0.artists,
                        serverId: serverId
                    )
                },
                importLikedSongs: {
                    try database.importLikedSongsFromStarredSongs($0, serverId: serverId)
                },
                hiddenArtistIds: {
                    try database.loadHiddenIds(type: "artist", serverId: serverId)
                },
                hiddenAlbumIds: {
                    try database.loadHiddenIds(type: "album", serverId: serverId)
                },
                admittedArtists: {
                    try database.loadAdmittedArtists(serverId: serverId)
                },
                admittedAlbums: {
                    // The scheduler persists the complete network walk, but
                    // publishing it into AppState would defeat demand-loading.
                    []
                },
                refreshMembership: { appState.refreshLibraryMembershipIds() },
                refreshLikedIds: { appState.refreshLikedIds() },
                applyArtists: { appState.artists = $0 },
                applyAlbums: { _ in
                    appState.reconcileAlbumPresentationOverrides(through: albumPresentationRevisionAtStart)
                    appState.invalidateFullAlbumCatalog()
                },
                pruneStale: { item, syncStartedAt in
                    try database.pruneStaleLibraryRows(item, serverId: serverId, olderThan: syncStartedAt)
                },
                getMetadata: { try database.getSyncMetadata(key: $0) },
                setMetadata: { try database.setSyncMetadata(key: $0, value: $1) },
                recordDiscoveredAlbums: {
                    try database.recordDiscoveredAlbums($0, serverId: serverId)
                },
                updateDiscoveryCount: {
                    appState.unseenDiscoveryCount = (try? database.unseenDiscoveryCount(serverId: serverId)) ?? 0
                },
                notifyNewAlbums: { [weak self] albums in
                    // Match Settings' enabled-by-default preference without overriding an explicit opt-out.
                    guard (UserDefaults.standard.object(forKey: "showNewMusicNotifications") as? Bool) ?? true else { return }
                    self?.postNewMusicNotification(count: albums.count, albums: albums)
                }
            )
        )

        // Provenance facts are retried only after this origin has persisted its
        // song cache, so exact Fetcher identities can resolve without guessing.
        if summary.persistedLegs.contains("songs"),
           FetcherContractSettings.isEnabled,
           appState.activeServer == expectedServer,
           let directory = FetcherContractLoader().configuredDirectory() {
            let outcome = await FetcherProvenanceImporter.shared.importIfNeeded(
                directory: directory, serverId: serverId, database: database
            )
            if case let .failed(message) = outcome {
                print("[LibraryRefreshScheduler] Fetcher provenance import failed: \(message)")
            }
            if case let .awaitingSongCache(count, bySourceKind) = outcome {
                let kinds = bySourceKind
                    .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: ", ")
                print("[LibraryRefreshScheduler] Fetcher provenance awaiting \(count) exact mappings\(kinds.isEmpty ? "" : " (\(kinds))")")
            }
            guard appState.activeServer == expectedServer,
                  FetcherContractSettings.isEnabled
            else { return }
            if case .imported = outcome {
                NotificationCenter.default.post(name: .resonanceProjectItemsDidChange, object: nil, userInfo: ["serverId": serverId])
            }
            if case .awaitingSongCache = outcome {
                NotificationCenter.default.post(name: .resonanceProjectItemsDidChange, object: nil, userInfo: ["serverId": serverId])
            }
        }

        print(
            "[LibraryRefreshScheduler] Refresh complete: "
                + "\(summary.persistedLegs.sorted().joined(separator: ", ")) persisted, "
                + "\(summary.songCount) songs, \(summary.failures.count) failed legs"
        )
    }

    /// Force an immediate refresh (for manual refresh button)
    func refreshNow() async {
        requestRefresh(trigger: .manual)
        await refreshTask?.value
    }

    // MARK: - New Music Notifications

    private func postNewMusicNotification(count: Int, albums: [Album]) {
        let content = UNMutableNotificationContent()

        if count == 1, let album = albums.first {
            content.title = "New Album Added"
            content.body = "\(album.name) by \(album.artist)"
        } else {
            content.title = "New Music Added"
            content.body = "\(count) new albums added to your library"
        }

        let request = UNNotificationRequest(
            identifier: "new-music-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[LibraryRefreshScheduler] Failed to post new music notification: \(error)")
            }
        }
    }
}
