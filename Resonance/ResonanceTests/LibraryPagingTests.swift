import XCTest
import GRDB
@testable import Resonance

final class LibraryPagingTests: XCTestCase {
    private let serverID = "library-paging-server"

    func testQueryPreservesUnicodeSearchReleaseFallbackAndAllHiddenScopes() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let database = fixture.database

        try insertAlbum(id: "album-visible", releaseDate: "2024-05-06", into: database)
        let songs = [
            makeSong(id: "visible", title: "Élan", albumID: "album-visible", artistID: "artist-visible"),
            makeSong(id: "hidden-song", title: "Élan Song", albumID: "album-visible", artistID: "artist-visible"),
            makeSong(id: "hidden-album", title: "Élan Album", albumID: "album-hidden", artistID: "artist-visible"),
            makeSong(id: "hidden-artist", title: "Élan Artist", albumID: "album-visible", artistID: "artist-hidden"),
        ]
        try insert(songs, into: database)
        try database.hideItem(id: "hidden-song", type: "song", serverId: serverID)
        try database.hideItem(id: "album-hidden", type: "album", serverId: serverID)
        try database.hideItem(id: "artist-hidden", type: "artist", serverId: serverID)

        let query = LibrarySongQuery(serverID: serverID, searchText: "éL", sort: .title)
        let page = try await database.librarySongPage(matching: query, offset: 0, limit: 2, includeCount: true)

        XCTAssertEqual(page.totalCount, 1)
        XCTAssertEqual(page.songs.map(\.id), ["visible"])
        XCTAssertEqual(page.songs.first?.releaseDate?.storageValue, "2024-05-06")
        let matchingIDs = try await database.librarySongIDs(matching: query)
        XCTAssertEqual(matchingIDs, ["visible"])
    }

    func testDatabaseOrderingMatchesAllEightLegacyColumnsInBothDirections() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let database = fixture.database
        try insertAlbum(id: "a1", releaseDate: "2020-02-03", into: database)

        var songs = [
            makeSong(id: "s3", title: "file10", album: "Zulu", albumID: "a3", artist: "Éclair", artistID: "r3", duration: 300, plays: nil, added: nil, release: "2022", groupings: ["Work 10"]),
            makeSong(id: "s1", title: "File2", album: "alpha", albumID: "a1", artist: "beta", artistID: "r1", duration: 100, plays: 7, added: Date(timeIntervalSince1970: 100), release: nil, groupings: ["Work 2"]),
            makeSong(id: "s2", title: "apple", album: "Beta", albumID: "a2", artist: "Alpha", artistID: "r2", duration: 200, plays: 2, added: Date(timeIntervalSince1970: 200), release: "2021-01", groupings: ["Alpha"]),
        ]
        try insert(songs, into: database)
        songs[1].releaseDate = MediaReleaseDate(storageValue: "2020-02-03")

        for sort in LibrarySongSort.allCases {
            for ascending in [true, false] {
                let query = LibrarySongQuery(serverID: serverID, sort: sort, ascending: ascending)
                let actual = try await database.librarySongIDs(matching: query)
                let expected = legacySorted(songs, by: sort, ascending: ascending).map(\.id)
                XCTAssertEqual(actual, expected, "\(sort.rawValue), ascending=\(ascending)")
            }
        }
    }

    func testHundredThousandCatalogLoadsOnePageButExplicitWholeQueryResolvesEverything() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let database = fixture.database
        try database.write { [serverID] db in
            try db.execute(sql: """
                WITH RECURSIVE sequence(value) AS (
                    VALUES(0) UNION ALL SELECT value + 1 FROM sequence WHERE value < 99999
                )
                INSERT INTO cached_songs
                    (id, server_id, title, album_name, album_id, artist_name, artist_id,
                     duration, content_type, suffix, last_fetched)
                SELECT printf('song-%06d', value), ?, printf('Track %06d', 99999 - value),
                       'Large Album', 'large-album', 'Large Artist', 'large-artist',
                       180, 'audio/flac', 'flac', CURRENT_TIMESTAMP
                FROM sequence
                """, arguments: [serverID])
            try db.execute(sql: """
                INSERT INTO library_membership
                    (item_id, item_type, server_id, admitted_at, admitted_by)
                SELECT id, 'song', server_id, CURRENT_TIMESTAMP, 'navidrome_library'
                FROM cached_songs WHERE server_id = ?
                """, arguments: [serverID])
        }

        let query = LibrarySongQuery(serverID: serverID)
        let page = try await database.librarySongPage(matching: query, offset: 0, limit: 500, includeCount: true)
        XCTAssertEqual(page.totalCount, 100_000)
        XCTAssertEqual(page.songs.count, 500)

        let selectedIDs = try await database.librarySongIDs(matching: query)
        XCTAssertEqual(selectedIDs.count, 100_000, "Command-A must select the full query")
        let playback = try await database.librarySongs(matching: query)
        XCTAssertEqual(playback.count, 100_000, "explicit Play All must not stop at the loaded page")
        XCTAssertEqual(playback.first?.id, page.songs.first?.id)
        XCTAssertEqual(playback.last?.id, "song-000000")
    }

    func testNewerQueryGenerationRejectsLatePage() async throws {
        let gate = QueryGate()
        let client = LibrarySongQueryClient(
            page: { query, _, _, _ in
                if query.searchText == "old" {
                    await gate.markOldStarted()
                    try await Task.sleep(for: .milliseconds(200))
                }
                return LibrarySongPage(
                    songs: [Self.makeSong(id: query.searchText, title: query.searchText)],
                    totalCount: 1
                )
            },
            ids: { _, _ in [] },
            songs: { _, _ in [] }
        )
        let store = await MainActor.run { LibrarySongQueryStore(client: client, pageSize: 2) }
        let oldQuery = LibrarySongQuery(serverID: serverID, searchText: "old")
        let newQuery = LibrarySongQuery(serverID: serverID, searchText: "new")

        let oldTask = Task { await store.loadFirstPage(matching: oldQuery) }
        await gate.waitUntilOldStarted()
        await store.loadFirstPage(matching: newQuery)
        await oldTask.value

        let result = await MainActor.run { store.songs.map(\.id) }
        XCTAssertEqual(result, ["new"])
    }

    func testAdditiveNativeSelectionRetainsUnloadedIDs() {
        let merged = LibraryTableSelection.applyingNativeSelection(
            global: ["unloaded", "loaded-old"],
            loadedIDs: ["loaded-old", "loaded-new"],
            table: ["loaded-new"],
            isAdditive: true
        )
        XCTAssertEqual(merged, ["unloaded", "loaded-new"])
    }

    func testReplacementNativeSelectionDropsUnloadedGlobalIDs() {
        let replaced = LibraryTableSelection.applyingNativeSelection(
            global: ["unloaded-1", "unloaded-2", "loaded-old"],
            loadedIDs: ["loaded-old", "loaded-new"],
            table: ["loaded-new"],
            isAdditive: false
        )
        XCTAssertEqual(replaced, ["loaded-new"])
    }

    func testContextMenuOnlyExpandsWhenNativeTargetIsCurrentSelection() {
        XCTAssertTrue(LibraryTableSelection.contextTargetsGlobalSelection(
            nativeTarget: ["loaded-selected"],
            tableSelection: ["loaded-selected"],
            globalSelection: ["loaded-selected", "unloaded-selected"]
        ))
        XCTAssertFalse(LibraryTableSelection.contextTargetsGlobalSelection(
            nativeTarget: ["right-clicked-unselected"],
            tableSelection: ["loaded-selected"],
            globalSelection: ["loaded-selected", "unloaded-selected"]
        ))
        XCTAssertFalse(LibraryTableSelection.contextTargetsGlobalSelection(
            nativeTarget: [],
            tableSelection: ["loaded-selected"],
            globalSelection: ["loaded-selected"]
        ))
    }

    func testMoreFailureIsRecoverableWithoutDiscardingLoadedRows() async {
        let source = LibraryPageSequence([
            .success(LibrarySongPage(
                songs: [Self.makeSong(id: "a", title: "A")], totalCount: 2
            )),
            .failure(ResonanceError.notConfigured),
            .success(LibrarySongPage(
                songs: [Self.makeSong(id: "b", title: "B")], totalCount: nil
            )),
        ])
        let store = await makeStore(source: source)
        await store.loadFirstPage(matching: LibrarySongQuery(serverID: serverID))
        await store.loadNextPage()
        await MainActor.run {
            XCTAssertEqual(store.state, .loaded)
            XCTAssertEqual(store.songs.map(\.id), ["a"])
            XCTAssertNotNil(store.moreError)
        }
        await store.retryNextPage()
        await MainActor.run {
            XCTAssertEqual(store.songs.map(\.id), ["a", "b"])
            XCTAssertNil(store.moreError)
            XCTAssertFalse(store.hasMore)
        }
    }

    func testRawOffsetProgressesAcrossDuplicateRows() async {
        let source = LibraryPageSequence([
            .success(LibrarySongPage(
                songs: [Self.makeSong(id: "a", title: "A"), Self.makeSong(id: "b", title: "B")],
                totalCount: 4
            )),
            .success(LibrarySongPage(
                songs: [Self.makeSong(id: "b", title: "B"), Self.makeSong(id: "c", title: "C")],
                totalCount: nil
            )),
        ])
        let store = await makeStore(source: source)
        await store.loadFirstPage(matching: LibrarySongQuery(serverID: serverID))
        await store.loadNextPage()
        await MainActor.run {
            XCTAssertEqual(store.consumedRawOffset, 4)
            XCTAssertEqual(store.songs.map(\.id), ["a", "b", "c"])
            XCTAssertFalse(store.hasMore)
        }
    }

    func testEmptyPageBelowStaleCountTerminatesPagination() async {
        let source = LibraryPageSequence([
            .success(LibrarySongPage(
                songs: [Self.makeSong(id: "a", title: "A")], totalCount: 10
            )),
            .success(LibrarySongPage(songs: [], totalCount: nil)),
        ])
        let store = await makeStore(source: source)
        await store.loadFirstPage(matching: LibrarySongQuery(serverID: serverID))
        await store.loadNextPage()
        await MainActor.run {
            XCTAssertEqual(store.totalCount, 1)
            XCTAssertFalse(store.hasMore)
        }
    }

    func testCancelThenQueuedMoreDoesNotInvokeSource() async {
        let source = LibraryPageSequence([
            .success(LibrarySongPage(
                songs: [Self.makeSong(id: "a", title: "A")], totalCount: 2
            )),
            .success(LibrarySongPage(
                songs: [Self.makeSong(id: "b", title: "B")], totalCount: nil
            )),
        ])
        let store = await makeStore(source: source)
        await store.loadFirstPage(matching: LibrarySongQuery(serverID: serverID))
        await MainActor.run { store.cancel() }
        await store.loadNextPage()

        let callCount = await source.callCount
        XCTAssertEqual(callCount, 1)
        await MainActor.run {
            XCTAssertNil(store.context)
            XCTAssertEqual(store.state, .idle)
        }
    }

    private func makeStore(source: LibraryPageSequence) async -> LibrarySongQueryStore {
        let client = LibrarySongQueryClient(
            page: { _, _, _, _ in try await source.next() },
            ids: { _, _ in [] },
            songs: { _, _ in [] }
        )
        return await MainActor.run { LibrarySongQueryStore(client: client, pageSize: 2) }
    }

    private func legacySorted(_ songs: [Song], by sort: LibrarySongSort, ascending: Bool) -> [Song] {
        let direction: ComparisonResult = ascending ? .orderedAscending : .orderedDescending
        switch sort {
        case .title:
            return songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == direction }
        case .artist:
            return songs.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == direction }
        case .album:
            return songs.sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == direction }
        case .duration:
            return songs.sorted { ascending ? $0.duration < $1.duration : $0.duration > $1.duration }
        case .plays:
            return songs.sorted(using: KeyPathComparator(\Song.playCount, order: ascending ? .forward : .reverse))
        case .dateAdded:
            return songs.sorted(using: KeyPathComparator(\Song.addedAt, order: ascending ? .forward : .reverse))
        case .releaseDate:
            return songs.sorted(using: KeyPathComparator(\Song.releaseDate, order: ascending ? .forward : .reverse))
        case .grouping:
            return songs.sorted(using: KeyPathComparator(\Song.groupingDisplay, order: ascending ? .forward : .reverse))
        }
    }

    private struct Fixture {
        let database: DatabaseManager
        let root: URL
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-library-paging-\(UUID().uuidString)", isDirectory: true)
        let database = try DatabaseManager(databaseURL: root.appendingPathComponent("test.db"))
        return Fixture(database: database, root: root)
    }

    private func insertAlbum(id: String, releaseDate: String, into database: DatabaseManager) throws {
        try database.write { [serverID] db in
            try db.execute(sql: """
                INSERT INTO cached_albums
                    (id, server_id, name, artist_name, artist_id, song_count, duration, release_date, last_fetched)
                VALUES (?, ?, ?, 'Artist', 'artist', 1, 180, ?, CURRENT_TIMESTAMP)
                """, arguments: [id, serverID, "Album \(id)", releaseDate])
        }
    }

    private func insert(_ songs: [Song], into database: DatabaseManager) throws {
        try database.write { [serverID] db in
            for song in songs {
                try db.execute(sql: """
                    INSERT INTO cached_songs
                        (id, server_id, title, album_name, album_id, artist_name, artist_id,
                         duration, content_type, suffix, server_play_count, server_added_at,
                         release_date, groupings, last_fetched)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                    """, arguments: [
                        song.id, serverID, song.title, song.album, song.albumId, song.artist,
                        song.artistId, song.duration, song.contentType, song.suffix,
                        song.playCount, song.addedAt, song.releaseDate?.storageValue, song.groupingsStorage,
                    ])
                try db.execute(sql: """
                    INSERT INTO library_membership
                        (item_id, item_type, server_id, admitted_at, admitted_by)
                    VALUES (?, 'song', ?, CURRENT_TIMESTAMP, 'navidrome_library')
                    """, arguments: [song.id, serverID])
            }
        }
    }

    private static func makeSong(id: String, title: String) -> Song {
        makeSong(id: id, title: title, albumID: "album", artistID: "artist")
    }

    private static func makeSong(
        id: String,
        title: String,
        album: String = "Album",
        albumID: String,
        artist: String = "Artist",
        artistID: String,
        duration: Int = 180,
        plays: Int? = nil,
        added: Date? = nil,
        release: String? = nil,
        groupings: [String]? = nil
    ) -> Song {
        var song = Song(
            id: id, title: title, album: album, albumId: albumID,
            artist: artist, artistId: artistID, track: nil, discNumber: nil,
            year: nil, genre: "Ambient", duration: duration, bitRate: nil,
            contentType: "audio/flac", suffix: "flac", coverArt: nil,
            starred: nil, rating: nil
        )
        song.playCount = plays
        song.addedAt = added
        song.releaseDate = MediaReleaseDate(storageValue: release)
        song.groupings = groupings
        return song
    }

    private func makeSong(
        id: String,
        title: String,
        album: String = "Album",
        albumID: String,
        artist: String = "Artist",
        artistID: String,
        duration: Int = 180,
        plays: Int? = nil,
        added: Date? = nil,
        release: String? = nil,
        groupings: [String]? = nil
    ) -> Song {
        Self.makeSong(
            id: id, title: title, album: album, albumID: albumID,
            artist: artist, artistID: artistID, duration: duration,
            plays: plays, added: added, release: release, groupings: groupings
        )
    }
}

private actor QueryGate {
    private var oldStarted = false

    func markOldStarted() { oldStarted = true }

    func waitUntilOldStarted() async {
        while !oldStarted { await Task.yield() }
    }
}

private actor LibraryPageSequence {
    private var results: [Result<LibrarySongPage, Error>]
    private(set) var callCount = 0

    init(_ results: [Result<LibrarySongPage, Error>]) {
        self.results = results
    }

    func next() throws -> LibrarySongPage {
        callCount += 1
        guard !results.isEmpty else { throw ResonanceError.notConfigured }
        return try results.removeFirst().get()
    }
}
