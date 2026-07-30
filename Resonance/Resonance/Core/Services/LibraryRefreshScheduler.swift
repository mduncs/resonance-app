import Foundation
import SwiftUI
import Combine
import UserNotifications

@MainActor
struct LibraryRefreshExecutor {
    struct Operations {
        let fetchArtists: () async throws -> [Artist]
        let fetchAlbums: () async throws -> AlbumLibraryFetchResult
        let fetchSongs: (
            _ onPage: @escaping @MainActor @Sendable ([Song]) async throws -> Void
        ) async throws -> SongLibraryFetchResult
        let fetchStarred: () async throws -> StarredContent

        let knownAlbumIds: () throws -> Set<String>
        let saveArtists: ([Artist]) throws -> Void
        let saveAlbums: ([Album]) throws -> Void
        let saveSongs: ([Song]) throws -> Void
        let syncStarred: (StarredContent) throws -> Void
        let importLikedSongs: ([Song]) throws -> Int

        let hiddenArtistIds: () throws -> Set<String>
        let hiddenAlbumIds: () throws -> Set<String>
        let admittedArtists: () throws -> [Artist]
        let admittedAlbums: () throws -> [Album]
        let refreshMembership: () -> Void
        let refreshLikedIds: () -> Void
        let applyArtists: ([Artist]) -> Void
        let applyAlbums: ([Album]) -> Void

        /// Generation sweep for one cached table. Receives the sync's start time;
        /// rows older than it were not returned by the server this sync.
        let pruneStale: (DatabaseManager.PrunableLibraryItem, Date) throws -> DatabaseManager.LibraryPruneResult

        let getMetadata: (String) throws -> String?
        let setMetadata: (String, String) throws -> Void
        let recordDiscoveredAlbums: ([String]) throws -> Void
        let updateDiscoveryCount: () -> Void
        let notifyNewAlbums: ([Album]) -> Void
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

    private final class SongProgress {
        var persistedBatchCount = 0
        var persistedSongCount = 0

        func record(_ count: Int) {
            persistedBatchCount += 1
            persistedSongCount += count
        }
    }

    private static func captured<T: Sendable>(
        _ operation: () async throws -> T
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

        let artistsTask = Task { @MainActor in
            await captured(operations.fetchArtists)
        }
        let albumsTask = Task { @MainActor in
            await captured(operations.fetchAlbums)
        }
        let songsTask = Task { @MainActor in
            await captured {
                try await operations.fetchSongs { songs in
                    try operations.saveSongs(songs)
                    songProgress.record(songs.count)
                }
            }
        }
        let starredTask = Task { @MainActor in
            await captured(operations.fetchStarred)
        }

        let (artistsFetch, albumsFetch, songsFetch, starredFetch) = await (
            artistsTask.value,
            albumsTask.value,
            songsTask.value,
            starredTask.value
        )

        let timestamp = ISO8601DateFormatter().string(from: now)
        var persistedLegs = Set<String>()
        var failures: [String: String] = [:]
        var songCount = songProgress.persistedSongCount

        func recordFailure(_ leg: String, _ error: Error) {
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

        switch artistsFetch {
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

        switch albumsFetch {
        case .success(let albumResult):
            let albums = albumResult.albums
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

        switch songsFetch {
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

        switch starredFetch {
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
    private var cancellables = Set<AnyCancellable>()
    private var lastObservedConnection: (status: ConnectionStatus, serverId: String?)?
    private var lastOneShotStartedAt: [String: Date] = [:]
    private let now: () -> Date
    private let connectionSnapshotOverride: (() -> (ConnectionStatus, String?))?
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
        self.successfulSyncOverride = nil
        self.refreshOverride = nil
        Self.registerDefaults()

        // Observe interval changes
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.rescheduleIfNeeded()
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
        now: @escaping () -> Date = Date.init,
        refresh: @escaping () async -> Void
    ) {
        self.now = now
        self.connectionSnapshotOverride = connectionSnapshot
        self.successfulSyncOverride = successfulSyncExists
        self.refreshOverride = refresh
    }

    func cleanup() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
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
        lastObservedConnection = snapshot

        guard snapshot.0 == .connected, let serverId = snapshot.1 else { return }
        let isNewConnectedServer = previous?.status != .connected || previous?.serverId != serverId
        guard isNewConnectedServer else { return }

        requestRefresh(trigger: .connection)
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

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let refreshOverride = self.refreshOverride {
                await refreshOverride()
            } else {
                await self.performRefresh()
            }
            self.refreshTask = nil
        }
    }

    private func performRefresh() async {
        guard let appState = appState else { return }

        // Only refresh if connected
        guard appState.connectionStatus == ConnectionStatus.connected else { return }
        guard let serverId = appState.activeServerId else { return }

        let database = appState.databaseManager
        let network = appState.networkActor
        let summary = await LibraryRefreshExecutor.run(
            serverId: serverId,
            now: now(),
            operations: .init(
                fetchArtists: { try await network.fetchArtists() },
                fetchAlbums: { try await network.fetchAllAlbums() },
                fetchSongs: { onPage in
                    try await network.fetchAllSongs(onPage: onPage)
                },
                fetchStarred: { try await network.fetchStarred2() },
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
                    try database.loadAdmittedAlbums(serverId: serverId)
                },
                refreshMembership: { appState.refreshLibraryMembershipIds() },
                refreshLikedIds: { appState.refreshLikedIds() },
                applyArtists: { appState.artists = $0 },
                applyAlbums: { appState.albums = $0 },
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
                    guard UserDefaults.standard.bool(forKey: "showNewMusicNotifications") else { return }
                    self?.postNewMusicNotification(count: albums.count, albums: albums)
                }
            )
        )

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
