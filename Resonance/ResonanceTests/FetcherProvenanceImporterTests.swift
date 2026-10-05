import Foundation
import CryptoKit
import GRDB
import XCTest
@testable import Resonance

final class FetcherProvenanceImporterTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
        try super.tearDownWithError()
    }

    func testSharedFileKeepsBothCollectionsAndProjects() throws {
        let database = try makeDatabase()
        let serverId = "server-a"
        try database.saveSongs([song(id: "song-1")], serverId: serverId)
        let sharedPath = "/music/Shared/track.flac"
        let rows = [
            attribution(key: "attr:playlist-a", path: sharedPath, collection: "playlist:a", songId: "song-1"),
            attribution(key: "attr:playlist-b", path: sharedPath, collection: "playlist:b", songId: "song-1")
        ]

        try database.upsertFetcherAttributionFacts(rows, serverId: serverId)
        // A partial new export must not hide unrelated retained legacy evidence.
        try database.upsertSourceAttributions([
            attribution(key: "legacy:other", path: "/music/Other/track.flac", collection: "legacy:other", songId: "song-1")
        ])
        XCTAssertEqual(try database.songIdsBySourceCollectionKey(serverId: serverId), [
            "legacy:other": ["song-1"],
            "playlist:a": ["song-1"],
            "playlist:b": ["song-1"]
        ])
        XCTAssertEqual(
            try database.sourceVoices(forAlbumId: "album-1").compactMap(\.sourceCollectionKey).sorted(),
            ["legacy:other", "playlist:a", "playlist:b"]
        )
        XCTAssertTrue(["attr:playlist-a", "attr:playlist-b"].contains(
            try database.sourceAttribution(forSongId: "song-1", serverId: serverId)?.attributionKey ?? ""
        ))
        XCTAssertTrue(["attr:playlist-a", "attr:playlist-b"].contains(
            try database.sourceAttributionsBySongId(songs: [song(id: "song-1")], serverId: serverId)["song-1"]?.attributionKey ?? ""
        ))

        let summary = try FetcherProjectAutomake.run(
            collections: [collection(key: "playlist:a"), collection(key: "playlist:b")],
            serverId: serverId,
            database: database
        )
        XCTAssertEqual(summary.createdProjectIds.count, 2)
        XCTAssertEqual(try database.loadProjects(serverId: serverId).count, 2)
    }

    func testFactsAreServerScopedWhileLegacyRowsRemainFallbackForOtherServers() throws {
        let database = try makeDatabase()
        try database.saveSongs([song(id: "song-a")], serverId: "server-a")
        try database.saveSongs([song(id: "song-b")], serverId: "server-b")
        try database.upsertSourceAttributions([
            attribution(key: "legacy", path: "/music/legacy.flac", collection: "legacy", songId: "song-b")
        ])
        try database.upsertFetcherAttributionFacts([
            attribution(key: "server-a", path: "/music/a.flac", collection: "facts-a", songId: "song-a")
        ], serverId: "server-a")

        XCTAssertEqual(try database.songIdsBySourceCollectionKey(serverId: "server-a"), ["facts-a": ["song-a"]])
        XCTAssertEqual(try database.songIdsBySourceCollectionKey(serverId: "server-b"), ["legacy": ["song-b"]])
    }

    func testV3DirectoryAcquisitionLinksEveryExactTrackWithoutChoosingAScalarWinner() throws {
        let database = try makeDatabase()
        let serverId = "server-a"
        try database.saveSongs([song(id: "song-1"), song(id: "song-2")], serverId: serverId)
        let acquisition = FetcherSourceAttribution(
            attributionKey: "attr:room-directory",
            localPath: "/music/Rooms/Album",
            sourceCollectionKey: "room:exact",
            sourceKind: "apple_room",
            sourceDisplayName: "Exact room",
            downloadSource: "fetcher",
            queryContext: nil,
            acquiredAt: "2026-09-12T00:00:00Z",
            contractVersion: 3,
            navidromeSongId: nil,
            resolvedTracks: [
                .init(navidromeSongId: "song-1", localFileRelativePath: "Rooms/Album/01.flac", resolutionMethod: "local_directory_exact"),
                .init(navidromeSongId: "song-2", localFileRelativePath: "Rooms/Album/02.flac", resolutionMethod: "local_directory_exact")
            ]
        )

        try database.upsertFetcherAttributionFacts([acquisition], serverId: serverId)

        XCTAssertEqual(try database.songIdsBySourceCollectionKey(serverId: serverId), ["room:exact": ["song-1", "song-2"]])
        XCTAssertEqual(try database.sourceAttribution(forSongId: "song-2", serverId: serverId)?.attributionKey, "attr:room-directory")
        XCTAssertEqual(
            try database.sourceAttributionsBySongId(songs: [song(id: "song-1"), song(id: "song-2")], serverId: serverId).keys.sorted(),
            ["song-1", "song-2"]
        )
        XCTAssertEqual(try database.sourceVoices(forAlbumId: "album-1").filter { $0.attributionKey == "attr:room-directory" }.count, 1)

        let summary = try FetcherProjectAutomake.run(
            collections: [collection(key: "room:exact")], serverId: serverId, database: database
        )
        XCTAssertEqual(summary.createdProjectIds.count, 1)
        XCTAssertEqual(try database.fetcherResolvedAttributionFactCount(serverId: serverId), 1)
    }

    func testV3ContractDecodesExporterSerializedResolvedTrackArray() throws {
        let directory = try makeProvenanceDirectory(collections: [collection(key: "room:exact")], attribution: [])
        let payload = """
        [{"attribution_key":"attr:room","local_path":"/music/Rooms/Exact","source_collection_key":"room:exact","source_kind":"apple_room","source_display_name":"Exact room","download_source":null,"query_context":null,"acquired_at":null,"navidrome_song_id":null,"resolution_method":null,"resolved_tracks":"[{\\"navidrome_song_id\\":\\"song-1\\",\\"local_file_relative_path\\":\\"Rooms/Exact/01.flac\\",\\"resolution_method\\":\\"catalog_room_directory_lineage\\"}]","contract_version":3}]
        """
        try Data(payload.utf8).write(to: directory.appendingPathComponent("source-attribution-v3.json"))

        let bundle = try FetcherContractLoader().loadProvenanceBundle(from: directory)
        XCTAssertEqual(bundle.attribution.first?.navidromeSongId, nil)
        XCTAssertEqual(bundle.attribution.first?.resolvedTracks?.map(\.navidromeSongId), ["song-1"])
    }

    func testUnresolvedMappingsRetryAfterSongCacheAndOnlyThenMarkCurrent() async throws {
        let directory = try makeProvenanceDirectory(
            collections: [collection(key: "playlist:a")],
            attribution: [attribution(key: "attr:a", path: "/music/a.flac", collection: "playlist:a", songId: "song-a")]
        )
        let database = try makeDatabase()
        let importer = FetcherProvenanceImporter()
        let serverId = "server-a"
        let obsoleteExternalMarker = "fetcherAttributionImportedMarker.\(serverId)"
        UserDefaults.standard.set("obsolete-success", forKey: obsoleteExternalMarker)
        defer { UserDefaults.standard.removeObject(forKey: obsoleteExternalMarker) }

        let first = await importer.importIfNeeded(directory: directory, serverId: serverId, database: database)
        XCTAssertEqual(first, .awaitingSongCache(count: 1, bySourceKind: ["apple_playlist": 1]))
        XCTAssertNotNil(try database.fetcherImportState(serverId: serverId)?.factsMarker)

        try database.saveSongs([song(id: "song-a")], serverId: serverId)
        let second = await importer.importIfNeeded(directory: directory, serverId: serverId, database: database)
        XCTAssertEqual(second, .imported)
        XCTAssertNotNil(try database.fetcherImportMarker(serverId: serverId))
        let third = await importer.importIfNeeded(directory: directory, serverId: serverId, database: database)
        XCTAssertEqual(third, .current)
    }

    func testUnreadableExportRecordsFailureWithoutSuccessMarker() async throws {
        let database = try makeDatabase()
        let importer = FetcherProvenanceImporter()
        let directory = try makeDirectory()
        try Data("not JSON".utf8).write(to: directory.appendingPathComponent("contract-version.json"))

        let result = await importer.importIfNeeded(directory: directory, serverId: "server-a", database: database)
        guard case .failed = result else {
            return XCTFail("expected import failure")
        }
        XCTAssertNil(try database.fetcherImportMarker(serverId: "server-a"))
    }

    func testPublishedHashMismatchGatesFactsBeforeAnyWrite() async throws {
        let directory = try makeProvenanceDirectory(
            collections: [collection(key: "playlist:a")],
            attribution: [attribution(key: "attr:a", path: "/music/a.flac", collection: "playlist:a", songId: "song-a")]
        )
        let metadata = FetcherContractMetadata(
            exportSchemaVersion: 1,
            generatedAt: "2026-09-12T00:00:00Z",
            fetcherContractVersion: 2,
            sourceDatabase: FetcherContractSourceDatabase(label: "test"),
            rowCounts: [:],
            contentHash: "sha256:published",
            files: [
                FetcherContractFileSummary(path: "source-collections.json", view: "collections", rowCount: 1, sortKeys: [], contentHash: "sha256:not-the-file"),
                FetcherContractFileSummary(path: "source-attribution-v2.json", view: "attribution", rowCount: 1, sortKeys: [], contentHash: "sha256:not-the-file")
            ],
            redactedPaths: false
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("contract-version.json"))
        let database = try makeDatabase()

        let outcome = await FetcherProvenanceImporter().importIfNeeded(directory: directory, serverId: "server-a", database: database)

        guard case .failed = outcome else { return XCTFail("expected publication hash failure") }
        XCTAssertEqual(try database.fetcherAttributionFactCount(serverId: "server-a"), 0)
        XCTAssertNil(try database.fetcherImportState(serverId: "server-a")?.factsMarker)
    }

    func testCancelledImportNeverMarksSuccess() async throws {
        let directory = try makeProvenanceDirectory(
            collections: [collection(key: "playlist:a")],
            attribution: [attribution(key: "attr:a", path: "/music/a.flac", collection: "playlist:a", songId: "song-a")]
        )
        let database = try makeDatabase()
        let importer = FetcherProvenanceImporter()
        let task = Task { () -> FetcherProvenanceImporter.Outcome in
            try? await Task.sleep(for: .seconds(1))
            return await importer.importIfNeeded(directory: directory, serverId: "server-a", database: database)
        }
        task.cancel()

        let outcome = await task.value
        XCTAssertEqual(outcome, .failed("Fetcher import cancelled"))
        XCTAssertNil(try database.fetcherImportMarker(serverId: "server-a"))
        XCTAssertFalse(try database.hasFetcherAttributionFacts(serverId: "server-a"))
    }

    func testDuplicatePublicationPathsFailWithoutWritingFacts() async throws {
        let directory = try makeProvenanceDirectory(
            collections: [collection(key: "playlist:a")],
            attribution: [attribution(key: "a", path: "/music/a.flac", collection: "playlist:a", songId: "a")]
        )
        try publishHashes(in: directory, filenames: ["source-collections.json", "source-collections.json", "source-attribution-v2.json"])
        let database = try makeDatabase()
        let result = await FetcherProvenanceImporter().importIfNeeded(directory: directory, serverId: "server-a", database: database)
        guard case let .failed(message) = result else { return XCTFail("duplicate publication entries must fail") }
        XCTAssertTrue(message.contains("duplicate metadata"))
        XCTAssertEqual(try database.fetcherAttributionFactCount(serverId: "server-a"), 0)
    }

    func testMissingPublishedV3DoesNotSilentlyImportOlderV2() async throws {
        let directory = try makeProvenanceDirectory(
            collections: [collection(key: "playlist:a")],
            attribution: [attribution(key: "a", path: "/music/a.flac", collection: "playlist:a", songId: "a")]
        )
        let v3 = directory.appendingPathComponent("source-attribution-v3.json")
        try Data("[]".utf8).write(to: v3)
        try publishHashes(in: directory, filenames: ["source-collections.json", "source-attribution-v2.json", "source-attribution-v3.json"])
        try FileManager.default.removeItem(at: v3)
        let database = try makeDatabase()
        let result = await FetcherProvenanceImporter().importIfNeeded(directory: directory, serverId: "server-a", database: database)
        guard case .failed = result else { return XCTFail("missing published v3 must fail") }
        XCTAssertEqual(try database.fetcherAttributionFactCount(serverId: "server-a"), 0)
    }

    func testMalformedPublicationDoesNotPartiallyImportValidPrefix() throws {
        let database = try makeDatabase()
        let existing = attribution(key: "retained", path: "/music/retained.flac", collection: "retained", songId: "retained")
        let valid = attribution(key: "new", path: "/music/new.flac", collection: "new", songId: "new")
        try database.upsertFetcherAttributionFacts([existing], serverId: "server-a")
        for invalid in [
            attribution(key: "bad", path: "/music/bad.flac", collection: "  ", songId: "bad"),
            attribution(key: "bad", path: "  ", collection: "bad", songId: "bad"),
            attribution(key: " new ", path: "/music/other.flac", collection: "other", songId: "other")
        ] {
            XCTAssertThrowsError(try database.upsertFetcherAttributionFacts([valid, invalid], serverId: "server-a"))
            XCTAssertEqual(try database.fetcherAttributionFactCount(serverId: "server-a"), 1)
            XCTAssertEqual(try database.fetcherAttributionLinkCount(serverId: "server-a"), 1)
        }
    }

    func testRepeatedTrackIdentityRejectsWholeDirectoryFact() throws {
        let database = try makeDatabase()
        let row = FetcherSourceAttribution(
            attributionKey: "room", localPath: "/music/room", sourceCollectionKey: "room",
            sourceKind: "apple_room", sourceDisplayName: "Room", downloadSource: nil,
            queryContext: nil, acquiredAt: nil, contractVersion: 3,
            resolvedTracks: [
                .init(navidromeSongId: "same", localFileRelativePath: "room/01.m4a", resolutionMethod: "exact"),
                .init(navidromeSongId: "same", localFileRelativePath: "room/02.m4a", resolutionMethod: "exact")
            ]
        )
        XCTAssertThrowsError(try database.upsertFetcherAttributionFacts([row], serverId: "server-a"))
        XCTAssertEqual(try database.fetcherAttributionFactCount(serverId: "server-a"), 0)
    }

    func testMissingLinkIsRepairedEvenWhenFactCountAndExportAreUnchanged() async throws {
        let directory = try makeProvenanceDirectory(
            collections: [collection(key: "playlist:a")],
            attribution: [attribution(key: "attr:a", path: "/music/a.flac", collection: "playlist:a", songId: "song-a")]
        )
        let database = try makeDatabase()
        try database.saveSongs([song(id: "song-a")], serverId: "server-a")
        let importer = FetcherProvenanceImporter()
        let first = await importer.importIfNeeded(directory: directory, serverId: "server-a", database: database)
        XCTAssertEqual(first, .imported)
        try await database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM fetcher_acquisition_song_links WHERE server_id = 'server-a'")
        }
        let repaired = await importer.importIfNeeded(directory: directory, serverId: "server-a", database: database)
        XCTAssertEqual(repaired, .imported)
        XCTAssertEqual(try database.fetcherAttributionLinkCount(serverId: "server-a"), 1)
        XCTAssertEqual(try database.fetcherAttributionFactCount(serverId: "server-a"), 1)
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER no_repeated_fact_updates BEFORE UPDATE ON fetcher_source_attribution_facts
                BEGIN SELECT RAISE(ABORT, 'unchanged export rewrote facts'); END
                """)
        }
        let unchanged = await importer.importIfNeeded(directory: directory, serverId: "server-a", database: database)
        XCTAssertEqual(unchanged, .current)
    }

    /// Opt-in only: this never opens a user's database. CI skips it unless the
    /// lead explicitly injects the prepared backup and three-file export.
    func testExplicitInjectedBackupRehearsalIsIdempotent() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rehearsalRoot = environment["RESONANCE_FETCHER_IMPORT_REHEARSAL_DIR"],
              !rehearsalRoot.isEmpty
        else {
            throw XCTSkip("Set RESONANCE_FETCHER_IMPORT_REHEARSAL_DIR to run the isolated Fetcher import rehearsal.")
        }

        let root = URL(fileURLWithPath: rehearsalRoot, isDirectory: true)
        let contractDirectory = root.appendingPathComponent("contract", isDirectory: true)
        let before = root.appendingPathComponent("resonance-before.db")
        let scratchDirectory = try makeDirectory()
        let after = scratchDirectory.appendingPathComponent("resonance-after.db")
        try FileManager.default.copyItem(at: before, to: after)
        let database = try DatabaseManager(databaseURL: after)
        let serverIds = try await database.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT server_id FROM cached_songs ORDER BY server_id")
        }
        let serverId = try XCTUnwrap(serverIds.only)
        XCTAssertEqual(try database.fetcherAttributionFactCount(serverId: serverId), 0)
        let expected = try FetcherContractLoader().loadProvenanceBundle(from: contractDirectory)
        let expectedFacts = expected.attribution.count
        let expectedResolved = expected.attribution.filter { !($0.resolvedTracks ?? $0.navidromeSongId.map { [.init(navidromeSongId: $0, localFileRelativePath: nil, resolutionMethod: nil)] } ?? []).isEmpty }.count
        let expectedLinks = expected.attribution.reduce(0) { partial, row in
            partial + (row.resolvedTracks?.count ?? (row.navidromeSongId == nil ? 0 : 1))
        }
        let userRowsBefore = try await database.dbPool.read { db in try Self.retainedUserRows(db) }

        let importer = FetcherProvenanceImporter()
        let first = await importer.importIfNeeded(directory: contractDirectory, serverId: serverId, database: database)
        guard case let .awaitingSongCache(count, bySourceKind) = first else {
            return XCTFail("expected unresolved directory-attribution diagnostics, got \(first)")
        }
        XCTAssertEqual(try database.fetcherAttributionFactCount(serverId: serverId), expectedFacts)
        XCTAssertEqual(try database.fetcherResolvedAttributionFactCount(serverId: serverId), expectedResolved)
        let persistedLinks = try await database.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fetcher_acquisition_song_links WHERE server_id = ?", arguments: [serverId]) ?? 0
        }
        XCTAssertEqual(persistedLinks, expectedLinks)
        let expectedLinkSet = Set(expected.attribution.flatMap { row in
            (row.resolvedTracks?.map(\.navidromeSongId) ?? row.navidromeSongId.map { [$0] } ?? [])
                .map { AcquisitionLink(acquisition: row.attributionKey, song: $0) }
        })
        let persistedLinkSet = try await database.dbPool.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT attribution_key,navidrome_song_id FROM fetcher_acquisition_song_links WHERE server_id = ?", arguments: [serverId])
                .map { AcquisitionLink(acquisition: $0["attribution_key"], song: $0["navidrome_song_id"]) })
        }
        XCTAssertEqual(persistedLinkSet, expectedLinkSet)
        let userRowsAfter = try await database.dbPool.read { db in try Self.retainedUserRows(db) }
        for (table, oldRows) in userRowsBefore {
            XCTAssertEqual(oldRows.subtracting(userRowsAfter[table] ?? []).count, 0, "Existing user rows changed in \(table)")
        }
        if expectedLinks == 55_016 {
            XCTAssertEqual(count, 4)
            XCTAssertNil(bySourceKind["apple_room"])
            XCTAssertNil(bySourceKind["dj_mix_room"])
        } else {
            XCTAssertEqual(count, 18)
            XCTAssertEqual(bySourceKind["apple_room"], 11)
            XCTAssertEqual(bySourceKind["dj_mix_room"], 3)
        }
        XCTAssertNotNil(try database.fetcherImportState(serverId: serverId)?.factsMarker)

        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER no_repeated_fact_updates BEFORE UPDATE ON fetcher_source_attribution_facts
                BEGIN SELECT RAISE(ABORT, 'unchanged export rewrote facts'); END
                """)
        }

        let second = await importer.importIfNeeded(directory: contractDirectory, serverId: serverId, database: database)
        // Facts stay current without another 29k-row import, while unresolved
        // directory/schedule diagnostics remain visible until cache changes.
        XCTAssertEqual(second, first)
        XCTAssertEqual(try database.fetcherAttributionFactCount(serverId: serverId), expectedFacts)
        let report: [String: Any] = [
            "facts": expectedFacts, "resolved_acquisitions": expectedResolved,
            "exact_link_pairs": persistedLinkSet.count, "link_set_matches_export": persistedLinkSet == expectedLinkSet,
            "unresolved_collections": count, "unresolved_by_kind": bySourceKind,
            "existing_user_rows_preserved": userRowsBefore.allSatisfy { table, rows in rows.isSubset(of: userRowsAfter[table] ?? []) },
            "unchanged_export_did_not_rewrite_facts": second == first,
            "scope": "injected copies only; no live DB import"
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("final-import-rehearsal-result.json"), options: .atomic)
    }

    private struct AcquisitionLink: Hashable, Sendable {
        let acquisition: String
        let song: String
    }

    private static func retainedUserRows(_ db: Database) throws -> [String: Set<String>] {
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        var result: [String: Set<String>] = [:]
        for table in tables where !table.hasPrefix("cached_") && !table.hasPrefix("fetcher_")
            && !table.hasPrefix("sqlite_") && !table.hasPrefix("grdb_") {
            let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
            result[table] = Set(try Row.fetchAll(db, sql: "SELECT * FROM \"\(quoted)\"").map { String(describing: $0) })
        }
        return result
    }

    private func makeDatabase() throws -> DatabaseManager {
        let directory = try makeDirectory()
        return try DatabaseManager(databaseURL: directory.appendingPathComponent("scratch.sqlite"))
    }

    private func publishHashes(in directory: URL, filenames: [String]) throws {
        let metadataURL = directory.appendingPathComponent("contract-version.json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata["files"] = try filenames.map { filename -> [String: Any] in
            let data = try Data(contentsOf: directory.appendingPathComponent(filename))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let rowCount = (try JSONSerialization.jsonObject(with: data) as? [Any])?.count ?? 0
            return ["path": filename, "view": "fixture", "row_count": rowCount, "sort_keys": [], "content_hash": "sha256:\(hash)"]
        }
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
    }

    private func makeProvenanceDirectory(
        collections: [FetcherSourceCollection],
        attribution: [FetcherSourceAttribution]
    ) throws -> URL {
        let directory = try makeDirectory()
        let metadata = FetcherContractMetadata(
            exportSchemaVersion: 1,
            generatedAt: "2026-09-12T00:00:00Z",
            fetcherContractVersion: 2,
            sourceDatabase: FetcherContractSourceDatabase(label: "test"),
            rowCounts: [:],
            contentHash: "sha256:test",
            files: [],
            redactedPaths: true
        )
        let encoder = JSONEncoder()
        try encoder.encode(metadata).write(to: directory.appendingPathComponent("contract-version.json"))
        try encoder.encode(collections).write(to: directory.appendingPathComponent("source-collections.json"))
        try encoder.encode(attribution).write(to: directory.appendingPathComponent("source-attribution-v2.json"))
        return directory
    }

    private func makeDirectory() throws -> URL {
        let scratchRoot = ProcessInfo.processInfo.environment["RESONANCE_FETCHER_IMPORT_REHEARSAL_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = scratchRoot
            .appendingPathComponent("FetcherProvenanceImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryURLs.append(directory)
        return directory
    }

    private func collection(key: String) -> FetcherSourceCollection {
        FetcherSourceCollection(
            sourceCollectionKey: key,
            sourceKind: "apple_playlist",
            domain: "apple_music",
            displayName: key,
            externalUrl: nil,
            externalId: nil,
            lastObservedAt: nil,
            lastSuccessfulObservedAt: nil,
            staleState: "fresh",
            currentItemCount: 1,
            allSeenItemCount: 1,
            removedItemCount: 0,
            lastChangeAt: nil,
            sourceSpecificJson: nil,
            contractVersion: 2
        )
    }

    private func attribution(key: String, path: String, collection: String, songId: String) -> FetcherSourceAttribution {
        FetcherSourceAttribution(
            attributionKey: key,
            localPath: path,
            sourceCollectionKey: collection,
            sourceKind: "apple_playlist",
            sourceDisplayName: collection,
            downloadSource: "fetcher",
            queryContext: nil,
            acquiredAt: "2026-09-12T00:00:00Z",
            contractVersion: 2,
            navidromeSongId: songId
        )
    }

    private func song(id: String) -> Song {
        Song(
            id: id,
            title: id,
            album: "Album",
            albumId: "album-1",
            artist: "Artist",
            artistId: "artist-1",
            track: 1,
            discNumber: 1,
            year: 2026,
            genre: "Electronic",
            duration: 180,
            bitRate: 320,
            contentType: "audio/flac",
            suffix: "flac",
            coverArt: nil,
            path: "Electronic/track.flac"
        )
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
