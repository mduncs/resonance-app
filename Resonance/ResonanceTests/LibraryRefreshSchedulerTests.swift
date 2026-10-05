import XCTest
@testable import Resonance

@MainActor
final class LibraryRefreshSchedulerTests: XCTestCase {
    private enum TestError: LocalizedError {
        case songs
        case starred

        var errorDescription: String? {
            switch self {
            case .songs: "songs unavailable"
            case .starred: "starred unavailable"
            }
        }
    }

    @MainActor
    private final class Recorder {
        var savedArtistIds: [String] = []
        var savedAlbumIds: [String] = []
        var savedSongIds: [String] = []
        var metadata: [String: String] = [:]
        var refreshCount = 0
        var appliedArtistIds: [String] = []
        var appliedAlbumIds: [String] = []
        /// Every sweep the executor actually attempted, in order.
        var pruneCalls: [DatabaseManager.PrunableLibraryItem] = []
        /// Sync start time handed to each sweep.
        var pruneCutoffs: [Date] = []
        /// Result the fake sweep should return.
        var pruneResult = DatabaseManager.LibraryPruneResult(removed: 3, examined: 100, refusalReason: nil)
    }

    func testConnectTransitionTriggersOneShotRefresh() async {
        let recorder = Recorder()
        var status = ConnectionStatus.disconnected
        let scheduler = LibraryRefreshScheduler(
            connectionSnapshot: { (status, "server-1") },
            successfulSyncExists: { _ in false },
            refresh: { recorder.refreshCount += 1 }
        )

        status = .connected
        scheduler.connectionStateDidChange()

        for _ in 0..<20 where recorder.refreshCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(recorder.refreshCount, 1)

        scheduler.connectionStateDidChange()
        await Task.yield()
        XCTAssertEqual(recorder.refreshCount, 1, "Repeated connected observations must not stack refreshes")
    }

    func testThrowingSongsLegStillPersistsArtistsAndAlbums() async {
        let recorder = Recorder()
        let summary = await runRefresh(recorder: recorder)

        XCTAssertEqual(recorder.savedArtistIds, ["artist-1"])
        XCTAssertEqual(recorder.savedAlbumIds, ["album-1"])
        XCTAssertTrue(recorder.savedSongIds.isEmpty)
        XCTAssertTrue(summary.persistedLegs.contains("artists"))
        XCTAssertTrue(summary.persistedLegs.contains("albums"))
        XCTAssertEqual(summary.failures["songs"], "songs unavailable")
        XCTAssertNotNil(recorder.metadata["lastSync.server-1"])
    }

    func testThrowingLegRecordsPerLegFailureMarker() async {
        let recorder = Recorder()
        _ = await runRefresh(recorder: recorder)

        let marker = recorder.metadata["lastSyncError.songs.server-1"]
        XCTAssertNotNil(marker)
        XCTAssertTrue(marker?.contains("songs unavailable") == true)
    }

    func testSongsPersistIncrementallyBeforeLatePagingFailure() async {
        let recorder = Recorder()
        let song = Song(
            id: "song-1",
            title: "Song",
            album: "Album",
            albumId: "album-1",
            artist: "Artist",
            artistId: "artist-1",
            track: 1,
            discNumber: 1,
            year: nil,
            genre: nil,
            duration: 180,
            bitRate: nil,
            contentType: "audio/flac",
            suffix: "flac",
            coverArt: nil,
            starred: nil,
            rating: nil,
            replayGain: nil
        )

        let summary = await runRefresh(recorder: recorder, fetchSongs: { onPage in
            try await onPage([song])
            throw TestError.songs
        })

        XCTAssertEqual(recorder.savedSongIds, [song.id])
        XCTAssertTrue(summary.persistedLegs.contains("songs"))
        XCTAssertEqual(summary.songCount, 1)
        XCTAssertNotNil(recorder.metadata["lastSyncError.songs.server-1"])
    }

    /// A songs leg that succeeds with a fully-walked library.
    private static func completeSongsLeg(
        _ song: Song? = nil
    ) -> @MainActor @Sendable (@escaping @MainActor @Sendable ([Song]) async throws -> Void) async throws -> SongLibraryFetchResult {
        { onPage in
            if let song { try await onPage([song]) }
            return SongLibraryFetchResult(
                songCount: song == nil ? 0 : 1,
                path: .emptyQuerySearch,
                fallbackReason: nil,
                walk: .complete
            )
        }
    }

    // MARK: - Generation sweep (prune)

    private static func makeSong(id: String = "song-1") -> Song {
        Song(
            id: id, title: "Song", album: "Album", albumId: "album-1",
            artist: "Artist", artistId: "artist-1", track: 1, discNumber: 1,
            year: nil, genre: nil, duration: 180, bitRate: nil,
            contentType: "audio/flac", suffix: "flac", coverArt: nil,
            starred: nil, rating: nil, replayGain: nil
        )
    }

    func testCompleteWalkSweepsEveryLeg() async {
        let recorder = Recorder()
        let summary = await runRefresh(
            recorder: recorder,
            fetchSongs: Self.completeSongsLeg(Self.makeSong())
        )

        XCTAssertEqual(Set(recorder.pruneCalls), [.song, .album, .artist])
        XCTAssertEqual(summary.pruneResults["songs"]?.removed, 3)
        XCTAssertEqual(summary.pruneResults["albums"]?.removed, 3)
        XCTAssertEqual(summary.pruneResults["artists"]?.removed, 3)
    }

    func testTruncatedAlbumWalkIsNotSwept() async {
        // The load-bearing case. A truncated walk saw only part of the server's
        // albums, so every album it *didn't* see would look stale — sweeping
        // there deletes a live library.
        let recorder = Recorder()
        let summary = await runRefresh(
            recorder: recorder,
            albumWalk: .truncated(reason: "stopped after 5 duplicate pages"),
            fetchSongs: Self.completeSongsLeg(Self.makeSong())
        )

        XCTAssertFalse(recorder.pruneCalls.contains(.album), "a truncated walk must never trigger a sweep")
        XCTAssertNil(summary.pruneResults["albums"])
        XCTAssertTrue(recorder.pruneCalls.contains(.song), "an unrelated complete leg must still sweep")
    }

    func testFailedSongsLegIsNotSwept() async {
        // Default fixture: the songs leg throws.
        let recorder = Recorder()
        let summary = await runRefresh(recorder: recorder)

        XCTAssertFalse(recorder.pruneCalls.contains(.song))
        XCTAssertNil(summary.pruneResults["songs"])
    }

    func testPartiallyPersistedSongsLegIsNotSwept() async {
        // Pages persisted, then the walk died. `persistedLegs` contains "songs",
        // but the enumeration is partial — sweeping would delete the remainder
        // of the library.
        let recorder = Recorder()
        let summary = await runRefresh(recorder: recorder, fetchSongs: { onPage in
            try await onPage([Self.makeSong()])
            throw TestError.songs
        })

        XCTAssertTrue(summary.persistedLegs.contains("songs"), "precondition: the leg did persist rows")
        XCTAssertFalse(recorder.pruneCalls.contains(.song), "persisted-but-incomplete must not sweep")
    }

    func testSweepCutoffIsTheSyncStartTime() async {
        // If the cutoff were taken after the legs ran, the sweep would delete
        // rows the sync had just written.
        let recorder = Recorder()
        _ = await runRefresh(recorder: recorder, fetchSongs: Self.completeSongsLeg(Self.makeSong()))

        XCTAssertFalse(recorder.pruneCutoffs.isEmpty)
        for cutoff in recorder.pruneCutoffs {
            XCTAssertEqual(cutoff, Date(timeIntervalSince1970: 1_000))
        }
    }

    func testRefusedSweepRecordsBreadcrumbAndRemovesNothing() async {
        let recorder = Recorder()
        recorder.pruneResult = DatabaseManager.LibraryPruneResult(
            removed: 0,
            examined: 100,
            refusalReason: "refused to prune 51 of 100 song rows (51%, over the 40% ceiling)"
        )

        let summary = await runRefresh(recorder: recorder, fetchSongs: Self.completeSongsLeg(Self.makeSong()))

        XCTAssertEqual(summary.pruneResults["songs"]?.removed, 0)
        XCTAssertEqual(summary.pruneResults["songs"]?.wasRefused, true)
        let marker = recorder.metadata["lastSyncError.prune.songs.server-1"]
        XCTAssertTrue(marker?.contains("over the 40% ceiling") == true)
        XCTAssertTrue(recorder.metadata["lastPrune.server-1"]?.contains("songs=refused") == true)
    }

    func testLastPruneBreadcrumbIsWrittenEvenWhenNothingIsRemoved() async {
        // A silent sweep and a sweep that never ran look identical without this.
        let recorder = Recorder()
        recorder.pruneResult = .noop

        _ = await runRefresh(recorder: recorder, fetchSongs: Self.completeSongsLeg(Self.makeSong()))

        let breadcrumb = recorder.metadata["lastPrune.server-1"]
        XCTAssertNotNil(breadcrumb)
        XCTAssertTrue(breadcrumb?.contains("songs=0") == true)
    }

    func testSkippedLegIsReportedAsSkippedNotZero() async {
        // "skipped" and "removed 0" are different facts and must not collapse.
        let recorder = Recorder()
        _ = await runRefresh(recorder: recorder)  // songs leg throws

        XCTAssertTrue(recorder.metadata["lastPrune.server-1"]?.contains("songs=skipped") == true)
    }

    func testObsoleteOriginAfterIncrementalPageDoesNotPublishOrSweep() async {
        let recorder = Recorder()
        var originIsCurrent = true
        let summary = await runRefresh(
            recorder: recorder,
            validateOrigin: {
                try Task.checkCancellation()
                guard originIsCurrent else { throw CancellationError() }
            },
            fetchSongs: { onPage in
                try await onPage([Self.makeSong()])
                originIsCurrent = false
                return SongLibraryFetchResult(
                    songCount: 1,
                    path: .emptyQuerySearch,
                    fallbackReason: nil,
                    walk: .complete
                )
            }
        )

        XCTAssertEqual(recorder.savedSongIds, ["song-1"], "a page saved under the captured origin remains safe")
        XCTAssertTrue(recorder.savedArtistIds.isEmpty)
        XCTAssertTrue(recorder.savedAlbumIds.isEmpty)
        XCTAssertTrue(recorder.appliedArtistIds.isEmpty)
        XCTAssertTrue(recorder.appliedAlbumIds.isEmpty)
        XCTAssertTrue(recorder.pruneCalls.isEmpty)
        XCTAssertNil(recorder.metadata["lastSync.server-1"])
        XCTAssertTrue(summary.failures.isEmpty, "origin invalidation is cancellation, not a sync error")
    }

    func testCancelingExecutorCancelsStructuredChildrenAndPreventsPublication() async {
        let recorder = Recorder()
        let task = Task { @MainActor in
            await runRefresh(recorder: recorder, fetchSongs: { _ in
                while !Task.isCancelled { await Task.yield() }
                throw CancellationError()
            })
        }

        for _ in 0..<10 { await Task.yield() }
        task.cancel()
        let summary = await task.value

        XCTAssertTrue(summary.persistedLegs.isEmpty)
        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertTrue(recorder.savedArtistIds.isEmpty)
        XCTAssertTrue(recorder.savedAlbumIds.isEmpty)
        XCTAssertTrue(recorder.savedSongIds.isEmpty)
        XCTAssertTrue(recorder.pruneCalls.isEmpty)
        XCTAssertNil(recorder.metadata["lastSync.server-1"])
    }

    func testConnectedServerTransitionReplacesCanceledRefreshWithoutOldCleanupClearingNewTask() async {
        let recorder = Recorder()
        var serverID = "server-A"
        var starts: [String] = []
        var allowAFinish = false
        var allowBFinish = false
        let scheduler = LibraryRefreshScheduler(
            connectionSnapshot: { (.connected, serverID) },
            successfulSyncExists: { _ in false },
            refresh: {
                let startedServer = serverID
                starts.append(startedServer)
                if startedServer == "server-A" {
                    while !Task.isCancelled { await Task.yield() }
                    while !allowAFinish { await Task.yield() }
                } else {
                    while !allowBFinish { await Task.yield() }
                }
                recorder.refreshCount += 1
            }
        )

        scheduler.connectionStateDidChange()
        for _ in 0..<40 where starts != ["server-A"] { await Task.yield() }
        serverID = "server-B"
        scheduler.connectionStateDidChange()
        for _ in 0..<40 where !starts.contains("server-B") { await Task.yield() }

        allowAFinish = true
        for _ in 0..<20 { await Task.yield() }
        let waiter = Task { @MainActor in await scheduler.refreshNow() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(starts, ["server-A", "server-B"], "old completion must not clear and duplicate B")

        allowBFinish = true
        await waiter.value
        XCTAssertEqual(recorder.refreshCount, 2)
        scheduler.cleanup()
    }

    func testFolderOriginChangeReplacesInFlightRefresh() async {
        var origin = "server-1|folder-A"
        var starts: [String] = []
        let scheduler = LibraryRefreshScheduler(
            connectionSnapshot: { (.connected, "server-1") },
            successfulSyncExists: { _ in false },
            connectionOrigin: { origin },
            refresh: {
                starts.append(origin)
                while !Task.isCancelled { await Task.yield() }
            }
        )

        scheduler.connectionStateDidChange()
        for _ in 0..<40 where starts.count < 1 { await Task.yield() }
        origin = "server-1|folder-B"
        scheduler.connectionStateDidChange()
        for _ in 0..<40 where starts.count < 2 { await Task.yield() }

        XCTAssertEqual(starts, ["server-1|folder-A", "server-1|folder-B"])
        scheduler.cleanup()
    }

    func testCanceledConnectionAttemptDoesNotSuppressABAReconnect() async {
        var serverID = "server-A"
        var starts: [String] = []
        let scheduler = LibraryRefreshScheduler(
            connectionSnapshot: { (.connected, serverID) },
            successfulSyncExists: { _ in false },
            now: { Date(timeIntervalSince1970: 2_000) },
            refresh: {
                starts.append(serverID)
                while !Task.isCancelled { await Task.yield() }
            }
        )

        scheduler.connectionStateDidChange()
        for _ in 0..<40 where starts.count < 1 { await Task.yield() }
        serverID = "server-B"
        scheduler.connectionStateDidChange()
        for _ in 0..<40 where starts.count < 2 { await Task.yield() }
        serverID = "server-A"
        scheduler.connectionStateDidChange()
        for _ in 0..<40 where starts.count < 3 { await Task.yield() }

        XCTAssertEqual(starts, ["server-A", "server-B", "server-A"])
        scheduler.cleanup()
    }

    private func runRefresh(
        recorder: Recorder,
        albumWalk: LibraryWalkOutcome = .complete,
        validateOrigin: @escaping @MainActor @Sendable () throws -> Void = { try Task.checkCancellation() },
        fetchSongs: @escaping @MainActor @Sendable (
            _ onPage: @escaping @MainActor @Sendable ([Song]) async throws -> Void
        ) async throws -> SongLibraryFetchResult = { _ in throw TestError.songs }
    ) async -> LibraryRefreshExecutor.Summary {
        let artist = Artist(
            id: "artist-1",
            name: "Artist",
            albumCount: 1,
            coverArt: nil,
            starred: nil
        )
        let album = Album(
            id: "album-1",
            name: "Album",
            artist: "Artist",
            artistId: artist.id,
            songCount: 1,
            duration: 180,
            year: nil,
            genre: nil,
            coverArt: nil,
            starred: nil,
            rating: nil
        )

        return await LibraryRefreshExecutor.run(
            serverId: "server-1",
            now: Date(timeIntervalSince1970: 1_000),
            operations: .init(
                fetchArtists: { [artist] },
                fetchAlbums: { AlbumLibraryFetchResult(albums: [album], walk: albumWalk) },
                fetchSongs: fetchSongs,
                fetchStarred: { throw TestError.starred },
                validateOrigin: validateOrigin,
                knownAlbumIds: { [] },
                saveArtists: { recorder.savedArtistIds += $0.map(\.id) },
                saveAlbums: { recorder.savedAlbumIds += $0.map(\.id) },
                saveSongs: { recorder.savedSongIds += $0.map(\.id) },
                syncStarred: { _ in },
                importLikedSongs: { _ in 0 },
                hiddenArtistIds: { [] },
                hiddenAlbumIds: { [] },
                admittedArtists: { [artist] },
                admittedAlbums: { [album] },
                refreshMembership: {},
                refreshLikedIds: {},
                applyArtists: { recorder.appliedArtistIds += $0.map(\.id) },
                applyAlbums: { recorder.appliedAlbumIds += $0.map(\.id) },
                pruneStale: { item, cutoff in
                    recorder.pruneCalls.append(item)
                    recorder.pruneCutoffs.append(cutoff)
                    return recorder.pruneResult
                },
                getMetadata: { recorder.metadata[$0] },
                setMetadata: { recorder.metadata[$0] = $1 },
                recordDiscoveredAlbums: { _ in },
                updateDiscoveryCount: {},
                notifyNewAlbums: { _ in }
            )
        )
    }
}
