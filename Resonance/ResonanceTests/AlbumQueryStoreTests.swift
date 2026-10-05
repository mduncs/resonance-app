import XCTest
import GRDB
@testable import Resonance

final class AlbumQueryStoreTests: XCTestCase {
    private let serverID = "album-query-fixture"

    private struct Fixture {
        let database: DatabaseManager
        let root: URL
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-album-query-\(UUID().uuidString)", isDirectory: true)
        return Fixture(database: try DatabaseManager(databaseURL: root.appendingPathComponent("test.db")), root: root)
    }

    private func insert(_ rows: [(String, String, Int, Date?)], database: DatabaseManager,
                        serverID: String? = nil) throws {
        let server = serverID ?? self.serverID
        try database.write { db in
            for (id, name, songs, added) in rows {
                try db.execute(sql: """
                    INSERT INTO cached_albums
                      (id, server_id, name, artist_name, artist_id, song_count,
                       duration, added_at, last_fetched)
                    VALUES (?, ?, ?, 'Artist', 'artist', ?, 180, ?, CURRENT_TIMESTAMP)
                    """, arguments: [id, server, name, songs, added])
                try db.execute(sql: """
                    INSERT INTO library_membership
                      (item_id, item_type, server_id, admitted_at, admitted_by)
                    VALUES (?, 'album', ?, CURRENT_TIMESTAMP, 'navidrome_library')
                    """, arguments: [id, server])
            }
        }
    }

    func testGlobalValiditySearchMinimumAndRecentSortAreAppliedBeforePage() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sameDate = Date(timeIntervalSince1970: 1_700_000_000)
        try insert([
            ("z", "Élan", 3, sameDate),
            ("a", "elan", 3, sameDate),
            ("older", "Élan Old", 2, Date(timeIntervalSince1970: 1_600_000_000)),
            ("unknown", "Élan Unknown", 3, nil),
            ("negative", "Malformed Count", -1, nil),
            ("invalid", "  \n", 30, Date(timeIntervalSince1970: 1_800_000_000)),
            ("other", "Different", 4, sameDate),
        ], database: fixture.database)
        try fixture.database.hideItem(id: "other", type: "album", serverId: serverID)
        let query = LibraryAlbumQuery(serverID: serverID, searchText: "élan",
                                      minimumSongCount: 3, sort: .recentlyAdded)
        let first = try await fixture.database.libraryAlbumPage(matching: query, offset: 0, limit: 2, includeCount: true)
        let second = try await fixture.database.libraryAlbumPage(matching: query, offset: 2, limit: 2, includeCount: false)
        XCTAssertEqual(first.totalCount, 3)
        XCTAssertEqual(first.albums.map(\.id), ["a", "z"])
        XCTAssertEqual(second.albums.map(\.id), ["unknown"], "Unknown added date belongs last")
        let ids = try await fixture.database.libraryAlbumIDs(matching: query)
        let full = try await fixture.database.fullAlbumCatalog(serverID: serverID)
        let point = try await fixture.database.cachedAlbum(id: "z", serverID: serverID)
        let hidden = try await fixture.database.cachedAlbum(id: "other", serverID: serverID)
        XCTAssertEqual(ids, ["a", "z", "unknown"])
        XCTAssertEqual(full.count, 5, "Default view applies title validity but no minimum-song filter")
        XCTAssertEqual(point?.id, "z")
        XCTAssertNil(hidden)
    }

    func testBestRepeatedNativeIDIsSavedBeforeFilteringAndDistinctEditionRemains() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let poor = Album(id: "same", name: "Album", artist: "Artist", artistId: "artist",
                         songCount: 1, duration: 0, year: nil, genre: nil, coverArt: nil)
        let better = Album(id: "same", name: "Album", artist: "Artist", artistId: "artist",
                           songCount: 12, duration: 2000, year: 2021, genre: "Electronic", coverArt: "cover")
        let edition = Album(id: "edition", name: "Album", artist: "Artist", artistId: "artist",
                            songCount: 2, duration: 200, year: nil, genre: nil, coverArt: nil)
        try fixture.database.saveAlbums([better, poor, edition], serverId: serverID)
        try fixture.database.write { [serverID] db in
            for id in ["same", "edition"] {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO library_membership
                      (item_id, item_type, server_id, admitted_at, admitted_by)
                    VALUES (?, 'album', ?, CURRENT_TIMESTAMP, 'navidrome_library')
                    """, arguments: [id, serverID])
            }
        }
        let query = LibraryAlbumQuery(serverID: serverID, minimumSongCount: 10)
        let page = try await fixture.database.libraryAlbumPage(matching: query, offset: 0, limit: 1, includeCount: true)
        XCTAssertEqual(page.totalCount, 1)
        XCTAssertEqual(page.albums.first?.id, "same")
        XCTAssertEqual(page.albums.first?.coverArt, "cover")
        let full = try await fixture.database.fullAlbumCatalog(serverID: serverID)
        XCTAssertEqual(full.count, 2)
    }

    func testPointAlbumResponseRetainsRatingAndAddedDate() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = Data(#"{"id":"point","name":"Point Album","artist":"Artist","created":"2026-09-01T00:00:00Z","userRating":4}"#.utf8)
        let album = try decoder.decode(AlbumResponse.self, from: payload).toAlbum()
        XCTAssertEqual(album.id, "point")
        XCTAssertEqual(album.rating, 4)
        XCTAssertNotNil(album.addedAt)
    }

    func testHundredThousandAlbumsStayPagedWhileExplicitWholeCatalogIsComplete() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.database.write { [serverID] db in
            try db.execute(sql: """
                WITH RECURSIVE sequence(value) AS (
                    VALUES(0) UNION ALL SELECT value + 1 FROM sequence WHERE value < 99999
                )
                INSERT INTO cached_albums
                  (id, server_id, name, artist_name, artist_id, song_count, duration, last_fetched)
                SELECT printf('album-%06d', value), ?, printf('Album %06d', value),
                       'Artist', 'artist', 2, 180, CURRENT_TIMESTAMP
                FROM sequence
                """, arguments: [serverID])
            try db.execute(sql: """
                INSERT INTO library_membership
                  (item_id, item_type, server_id, admitted_at, admitted_by)
                SELECT id, 'album', server_id, CURRENT_TIMESTAMP, 'navidrome_library'
                FROM cached_albums WHERE server_id = ?
                """, arguments: [serverID])
        }
        let query = LibraryAlbumQuery(serverID: serverID)
        let first = try await fixture.database.libraryAlbumPage(matching: query, offset: 0, limit: 250, includeCount: true)
        XCTAssertEqual(first.totalCount, 100_000)
        XCTAssertEqual(first.albums.count, 250)
        XCTAssertEqual(first.albums.first?.id, "album-000000")
        let last = try await fixture.database.libraryAlbumPage(matching: query, offset: 99_750, limit: 250, includeCount: false)
        XCTAssertEqual(last.albums.last?.id, "album-099999")
        let ids = try await fixture.database.libraryAlbumIDs(matching: query)
        let full = try await fixture.database.fullAlbumCatalog(serverID: serverID)
        XCTAssertEqual(ids.count, 100_000)
        XCTAssertEqual(full.count, 100_000)
    }

    func testServerSwitchRejectsLatePageAndCancellationKeepsNewRows() async throws {
        let client = LibraryAlbumQueryClient { query, _, _, _ in
            if query.serverID == "old" {
                try? await Task.sleep(for: .milliseconds(250))
            }
            let album = Album(id: query.serverID, name: query.serverID, artist: "A",
                              artistId: "artist", songCount: 1, duration: 1, year: nil, genre: nil, coverArt: nil)
            return LibraryAlbumPage(albums: [album], totalCount: 1)
        }
        let store = await MainActor.run { LibraryAlbumQueryStore(client: client, pageSize: 1) }
        let old = Task { await store.loadFirstPage(matching: LibraryAlbumQuery(serverID: "old")) }
        try await Task.sleep(for: .milliseconds(50))
        await store.loadFirstPage(matching: LibraryAlbumQuery(serverID: "new"))
        await old.value
        let ids = await MainActor.run { store.albums.map(\.id) }
        XCTAssertEqual(ids, ["new"])
    }

    func testSameServerInvalidationRejectsLateCatalogAndPreservesReplacementOwnership() async throws {
        let serverID = self.serverID
        let source = ControlledCatalogRead()
        let loader = await MainActor.run { FullAlbumCatalogLoader() }
        let old = Task { try? await loader.ensure(serverID: serverID) { try await source.load() } }
        await source.waitForCount(1)

        await loader.invalidate()
        let replacement = Task { try await loader.ensure(serverID: serverID) { try await source.load() } }
        await source.waitForCount(2)

        await source.release(0, albums: [makeAlbum("stale")])
        let oldResult = await old.value
        XCTAssertNil(oldResult, "Cancellation-ignoring old read must not publish")
        let loadedAfterOld = await MainActor.run { loader.loadedServerID }
        XCTAssertNil(loadedAfterOld)

        let coalesced = Task { try await loader.ensure(serverID: serverID) { try await source.load() } }
        await source.release(1, albums: [makeAlbum("current")])
        let replacementResult = try await replacement.value
        let coalescedResult = try await coalesced.value
        XCTAssertEqual(replacementResult.map(\.id), ["current"])
        XCTAssertEqual(coalescedResult.map(\.id), ["current"])
        let requestCount = await source.count
        XCTAssertEqual(requestCount, 2, "Old catch must not clear the replacement task")
    }

    func testCancelledCatalogWaiterDoesNotCancelSharedRead() async throws {
        let serverID = self.serverID
        let source = ControlledCatalogRead()
        let loader = await MainActor.run { FullAlbumCatalogLoader() }
        let first = Task { try? await loader.ensure(serverID: serverID) { try await source.load() } }
        await source.waitForCount(1)
        let second = Task { try await loader.ensure(serverID: serverID) { try await source.load() } }
        first.cancel()
        await source.release(0, albums: [makeAlbum("shared")])
        let cancelledResult = await first.value
        XCTAssertNil(cancelledResult)
        let kept = try await second.value
        XCTAssertEqual(kept.map(\.id), ["shared"])
        let requestCount = await source.count
        XCTAssertEqual(requestCount, 1)
    }

    func testCancelledWaiterCleanupPrecedesHealthyCatalogConsumer() async throws {
        let serverID = self.serverID
        let source = ControlledCatalogRead()
        let loader = await MainActor.run { FullAlbumCatalogLoader() }
        let cancelled = Task { try? await loader.ensure(serverID: serverID) { try await source.load() } }
        await source.waitForCount(1)
        cancelled.cancel()
        await source.release(0, albums: [makeAlbum("completed")])
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)

        // This starts only after cancelled cleanup has finished. It must reuse
        // the completed pending read, not start a second DB walk or hang.
        let healthy = try await loader.ensure(serverID: serverID) { try await source.load() }
        XCTAssertEqual(healthy.map(\.id), ["completed"])
        let count = await source.count
        XCTAssertEqual(count, 1)
    }

    func testConfirmedRefreshClearsOnlyPreexistingAlbumPresentationActions() {
        var store = AlbumPresentationStore()
        let originalDate = Date(timeIntervalSince1970: 1_600_000_000)
        var serverAlbum = makeAlbum("curated")
        serverAlbum.starred = originalDate
        serverAlbum.rating = 2

        store.setStarred(nil, for: serverAlbum.id)
        let refreshStart = store.revision
        let newerAction = store.setRating(5, for: serverAlbum.id)
        store.reconcile(through: refreshStart)
        let afterRefresh = store.presented(serverAlbum)
        XCTAssertEqual(afterRefresh.starred, originalDate, "Confirmed server value supersedes old action")
        XCTAssertEqual(afterRefresh.rating, 5, "New action during fetch remains visible")

        store.confirmRating(for: serverAlbum.id, actionRevision: newerAction)
        store.reconcile(through: store.revision)
        XCTAssertEqual(store.presented(serverAlbum).rating, 2)
    }

    func testDelayedRatingWriteOverlappingFetchCannotBeClearedEarly() {
        var store = AlbumPresentationStore()
        var serverAlbum = makeAlbum("delayed")
        serverAlbum.rating = 1
        let action = store.setRating(4, for: serverAlbum.id)
        let fetchStart = store.revision

        // The server snapshot still contains the old value while the write
        // awaits acknowledgement; even an earlier-started intent is pending.
        store.reconcile(through: fetchStart)
        XCTAssertEqual(store.presented(serverAlbum).rating, 4)
        store.confirmRating(for: serverAlbum.id, actionRevision: action)
        store.reconcile(through: fetchStart)
        XCTAssertEqual(store.presented(serverAlbum).rating, 4,
                       "Acknowledgement during the fetch is not proof its response includes the write")

        let nextFetchStart = store.revision
        store.reconcile(through: nextFetchStart)
        XCTAssertEqual(store.presented(serverAlbum).rating, 1)
    }

    func testOldRatingAcknowledgementOrFailureCannotClobberNewAction() {
        var store = AlbumPresentationStore()
        let album = makeAlbum("overlap")
        let older = store.setRating(2, for: album.id)
        let newer = store.setRating(5, for: album.id)
        store.confirmRating(for: album.id, actionRevision: older)
        XCTAssertFalse(store.rejectRating(for: album.id, actionRevision: older))
        store.reconcile(through: store.revision)
        XCTAssertEqual(store.presented(album).rating, 5)
        store.confirmRating(for: album.id, actionRevision: newer)
        XCTAssertEqual(store.presented(album).rating, 5)
    }

    func testFailedNewRatingRestoresLastAcknowledgedValueNotStaleCache() {
        var store = AlbumPresentationStore()
        var staleCache = makeAlbum("rollback")
        staleCache.rating = 1
        let confirmed = store.setRating(3, for: staleCache.id)
        store.confirmRating(for: staleCache.id, actionRevision: confirmed)
        let failing = store.setRating(4, for: staleCache.id)
        XCTAssertEqual(store.presented(staleCache).rating, 4)
        XCTAssertTrue(store.rejectRating(for: staleCache.id, actionRevision: failing))
        XCTAssertEqual(store.presented(staleCache).rating, 3,
                       "A later failed write must restore the last acknowledged rating")
    }

    func testDetailFirstFailedRatingNeverPollutesAuthoritativeFallback() {
        var store = AlbumPresentationStore()
        var captured = makeAlbum("detail")
        captured.rating = 1
        var detail = AlbumDetailPresentationState(navigation: captured)
        let failed = store.setRating(4, for: captured.id)
        detail.absorbAcknowledged(store)
        XCTAssertEqual(detail.displayed(using: store).rating, 4)
        XCTAssertEqual(detail.base.rating, 1, "The pending value must not enter point metadata")
        store.rejectRating(for: captured.id, actionRevision: failed)
        detail.absorbAcknowledged(store)
        XCTAssertEqual(detail.displayed(using: store).rating, 1)
    }

    func testDetailObservingExternalMenuFailureReturnsToConfirmedPointMetadata() {
        var store = AlbumPresentationStore()
        var captured = makeAlbum("external-menu")
        captured.rating = 1
        var detail = AlbumDetailPresentationState(navigation: captured)
        let externalAction = store.setRating(5, for: captured.id)
        detail.absorbAcknowledged(store) // View's presentation-revision observation.
        XCTAssertEqual(detail.displayed(using: store).rating, 5)
        store.rejectRating(for: captured.id, actionRevision: externalAction)
        detail.absorbAcknowledged(store)
        XCTAssertEqual(detail.displayed(using: store).rating, 1)
        XCTAssertEqual(detail.base.rating, 1)
    }

    func testDetailConfirmedRatingSurvivesLaterFailedRatingAndRefreshHandoff() {
        var store = AlbumPresentationStore()
        var captured = makeAlbum("detail")
        captured.rating = 1
        var detail = AlbumDetailPresentationState(navigation: captured)
        let confirmed = store.setRating(3, for: captured.id)
        store.confirmRating(for: captured.id, actionRevision: confirmed)
        detail.absorbAcknowledged(store)
        XCTAssertEqual(detail.base.rating, 3)

        let failing = store.setRating(4, for: captured.id)
        detail.absorbAcknowledged(store)
        XCTAssertEqual(detail.displayed(using: store).rating, 4)
        XCTAssertEqual(detail.base.rating, 3)
        store.rejectRating(for: captured.id, actionRevision: failing)
        detail.absorbAcknowledged(store)
        XCTAssertEqual(detail.displayed(using: store).rating, 3)

        let refreshStart = store.revision
        store.reconcile(through: refreshStart)
        detail.absorbAcknowledged(store)
        XCTAssertEqual(detail.displayed(using: store).rating, 3,
                       "Keep acknowledged presentation until the exact refreshed row arrives")
        var refreshed = captured
        refreshed.rating = 3
        refreshed.starred = Date(timeIntervalSince1970: 1_700_000_000)
        detail.updatePoint(refreshed, store: store)
        XCTAssertEqual(detail.displayed(using: store).rating, 3)
        XCTAssertEqual(detail.displayed(using: store).starred, refreshed.starred)

        // A later authoritative response can supersede that acknowledged value.
        let nextRefresh = store.revision
        store.reconcile(through: nextRefresh)
        var serverChanged = refreshed
        serverChanged.rating = 2
        detail.updatePoint(serverChanged, store: store)
        XCTAssertEqual(detail.displayed(using: store).rating, 2)
    }

    func testDetailAcknowledgementDuringFetchSurvivesStalePointResponse() {
        var store = AlbumPresentationStore()
        var stale = makeAlbum("overlapping-point")
        stale.rating = 1
        var detail = AlbumDetailPresentationState(navigation: stale)
        let fetchStart = store.revision
        let action = store.setRating(3, for: stale.id)
        store.confirmRating(for: stale.id, actionRevision: action)
        store.reconcile(through: fetchStart)
        detail.updatePoint(stale, store: store)
        XCTAssertEqual(detail.displayed(using: store).rating, 3)
    }

    private func makeAlbum(_ id: String) -> Album {
        Album(id: id, name: id, artist: "Artist", artistId: "artist",
              songCount: 1, duration: 1, year: nil, genre: nil, coverArt: nil)
    }

    func testCurrentCopiedSnapshotHasBoundedFirstPageWhenSupplied() async throws {
        guard let path = ProcessInfo.processInfo.environment["RESONANCE_ALBUM_SNAPSHOT"] else {
            throw XCTSkip("Pass the copied QA resonance.db path to exercise the 32k real cache")
        }
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("snapshot.db")
        try FileManager.default.copyItem(atPath: path, toPath: target.path)
        let database = try DatabaseManager(databaseURL: target)
        let server = try database.read { db in
            try String.fetchOne(db, sql: "SELECT server_id FROM cached_albums GROUP BY server_id ORDER BY COUNT(*) DESC LIMIT 1")
        }
        let id = try XCTUnwrap(server)
        let first = try await database.libraryAlbumPage(matching: LibraryAlbumQuery(serverID: id),
                                                        offset: 0, limit: 250, includeCount: true)
        XCTAssertGreaterThan(first.totalCount ?? 0, 30_000)
        XCTAssertEqual(first.albums.count, 250)
        let full = try await database.fullAlbumCatalog(serverID: id)
        XCTAssertEqual(full.count, first.totalCount)
    }
}

private actor ControlledCatalogRead {
    private var requests: [CheckedContinuation<[Album], Error>?] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var count: Int { requests.count }

    func load() async throws -> [Album] {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            for (needed, waiter) in waiters where requests.count >= needed { waiter.resume() }
            waiters.removeAll { requests.count >= $0.0 }
        }
    }

    func waitForCount(_ needed: Int) async {
        if requests.count >= needed { return }
        await withCheckedContinuation { waiters.append((needed, $0)) }
    }

    func release(_ index: Int, albums: [Album]) {
        guard requests.indices.contains(index), let request = requests[index] else { return }
        requests[index] = nil
        request.resume(returning: albums)
    }
}
