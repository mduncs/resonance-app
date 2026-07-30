import XCTest
import GRDB
@testable import Resonance

final class SourceAttributionTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for tempDir in tempDirs {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDirs = []
        try super.tearDownWithError()
    }

    // MARK: - Contract decode

    func testLoaderDecodesV1SourceAttributionUnchanged() throws {
        let directory = try writeContractFixture(includeAttribution: true)

        let snapshot = try FetcherContractLoader().loadSnapshot(from: directory)

        XCTAssertEqual(snapshot.sourceAttribution.count, 2)

        let first = try XCTUnwrap(snapshot.sourceAttribution.first { $0.attributionKey == "attr:one" })
        XCTAssertEqual(first.localPath, "/srv/music/Rock/Artist/01 Track.flac")
        XCTAssertEqual(first.sourceCollectionKey, "fetcher:source_collection:alpha")
        XCTAssertEqual(first.sourceKind, "apple_playlist")
        XCTAssertEqual(first.sourceDisplayName, "Alpha Source")
        XCTAssertEqual(first.downloadSource, "gamdl")
        XCTAssertEqual(first.queryContext, "artist track")
        XCTAssertEqual(first.acquiredAt, "2026-05-02T00:00:00.000Z")
        XCTAssertEqual(first.contractVersion, 1)
        XCTAssertNil(first.navidromeSongId)
        XCTAssertNil(first.resolutionMethod)
        XCTAssertNil(first.title)
        XCTAssertNil(first.artist)
        XCTAssertNil(first.album)
        XCTAssertNil(first.durationMs)
        XCTAssertNil(first.isrc)

        let second = try XCTUnwrap(snapshot.sourceAttribution.first { $0.attributionKey == "attr:two" })
        XCTAssertNil(second.downloadSource)
        XCTAssertNil(second.queryContext)
        XCTAssertNil(second.acquiredAt)
    }

    func testLoaderDecodesV2SourceAttributionAndPrefersItOverV1() throws {
        let directory = try writeContractFixture(includeAttribution: true)
        try write(
            """
            [
              {
                "attribution_key": "attr:v2",
                "local_path": "/srv/fetcher/Apple/Playlists/Dance/Marsh - Stay.m4a",
                "source_collection_key": "fetcher:source_collection:dance",
                "source_kind": "apple_playlist",
                "source_display_name": "Dance",
                "download_source": "gamdl",
                "query_context": "Marsh Stay",
                "acquired_at": "2026-07-25T18:00:00.000Z",
                "navidrome_song_id": "f2ad13a0",
                "resolution_method": "local_path_exact",
                "title": "Stay",
                "artist": "Marsh",
                "album": "Stay - Single",
                "duration_ms": 234567,
                "isrc": "GBABC2600001",
                "contract_version": 2
              },
              {
                "attribution_key": "attr:v2-unresolved",
                "local_path": "/srv/fetcher/unresolved.m4a",
                "source_collection_key": "fetcher:source_collection:dance",
                "source_kind": "apple_playlist",
                "source_display_name": "Dance",
                "download_source": "gamdl",
                "query_context": null,
                "acquired_at": null,
                "navidrome_song_id": null,
                "resolution_method": null,
                "title": null,
                "artist": null,
                "album": null,
                "duration_ms": null,
                "isrc": null,
                "contract_version": 2
              }
            ]
            """,
            named: FetcherContractLoader.sourceAttributionV2Filename,
            in: directory
        )

        let snapshot = try FetcherContractLoader().loadSnapshot(from: directory)

        XCTAssertEqual(snapshot.sourceAttribution.count, 2, "v2 must win when both files exist")
        let resolved = try XCTUnwrap(
            snapshot.sourceAttribution.first { $0.attributionKey == "attr:v2" }
        )
        XCTAssertEqual(resolved.navidromeSongId, "f2ad13a0")
        XCTAssertEqual(resolved.resolutionMethod, "local_path_exact")
        XCTAssertEqual(resolved.title, "Stay")
        XCTAssertEqual(resolved.artist, "Marsh")
        XCTAssertEqual(resolved.album, "Stay - Single")
        XCTAssertEqual(resolved.durationMs, 234_567)
        XCTAssertEqual(resolved.isrc, "GBABC2600001")
        XCTAssertEqual(resolved.contractVersion, 2)

        let unresolved = try XCTUnwrap(
            snapshot.sourceAttribution.first { $0.attributionKey == "attr:v2-unresolved" }
        )
        XCTAssertNil(unresolved.navidromeSongId)
        XCTAssertNil(unresolved.resolutionMethod)
        XCTAssertNil(unresolved.durationMs)
    }

    func testLoaderAcceptsEnvelopeContractVersion2() throws {
        let directory = try writeContractFixture(
            includeAttribution: true,
            fetcherContractVersion: 2
        )

        let snapshot = try FetcherContractLoader().loadSnapshot(from: directory)

        XCTAssertEqual(snapshot.metadata.fetcherContractVersion, 2)
        XCTAssertEqual(snapshot.metadata.exportSchemaVersion, 1)
    }

    func testLoaderTreatsMissingSourceAttributionFileAsEmpty() throws {
        let directory = try writeContractFixture(includeAttribution: false)

        let snapshot = try FetcherContractLoader().loadSnapshot(from: directory)

        // Absence is tolerated: no attribution, and the rest of the contract still decodes.
        XCTAssertTrue(snapshot.sourceAttribution.isEmpty)
        XCTAssertEqual(snapshot.metadata.fetcherContractVersion, 1)
        XCTAssertEqual(snapshot.metadata.exportSchemaVersion, 1)
    }

    func testLoaderThrowsWhenSourceAttributionFileIsMalformed() throws {
        let directory = try writeContractFixture(includeAttribution: false)
        try write("{ not an array", named: FetcherContractLoader.sourceAttributionFilename, in: directory)

        // A present-but-broken export should surface, not be silently swallowed.
        XCTAssertThrowsError(try FetcherContractLoader().loadSnapshot(from: directory))
    }

    // MARK: - Persistence: upsert idempotence

    func testUpsertSourceAttributionsIsIdempotentAndUpdatesInPlace() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let path = "/srv/music/Rock/Artist/01 Track.flac"

            try database.upsertSourceAttributions([
                makeRow(key: "attr:one", localPath: path, displayName: "Alpha Source"),
                makeRow(key: "attr:blank", localPath: "   ", displayName: "Skipped")
            ])
            // Second import of the same key with a changed display name.
            try database.upsertSourceAttributions([
                makeRow(key: "attr:one", localPath: path, displayName: "Alpha Source Renamed")
            ])

            let count = try database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source_attribution") ?? 0
            }
            // The blank-path row is skipped; the keyed row exists exactly once.
            XCTAssertEqual(count, 1)

            let record = try XCTUnwrap(database.sourceAttribution(forPath: path))
            XCTAssertEqual(record.sourceDisplayName, "Alpha Source Renamed")
            XCTAssertNotNil(record.importedAt)
        }
    }

    func testUpsertV2SourceAttributionStoresNavidromeSongId() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let path = "/srv/fetcher/Apple/Playlists/Dance/Marsh - Stay.m4a"

            try database.upsertSourceAttributions([
                makeRow(
                    key: "attr:v2",
                    localPath: path,
                    displayName: "Dance",
                    navidromeSongId: "navidrome-song-1",
                    contractVersion: 2
                )
            ])

            XCTAssertEqual(
                try database.sourceAttribution(forPath: path)?.navidromeSongId,
                "navidrome-song-1"
            )
        }
    }

    func testUpsertV2NullNavidromeSongIdPreservesExistingId() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let path = "/srv/fetcher/Apple/Playlists/Dance/Marsh - Stay.m4a"

            try database.upsertSourceAttributions([
                makeRow(
                    key: "attr:v2-resolved",
                    localPath: path,
                    displayName: "Dance",
                    navidromeSongId: "navidrome-song-1",
                    contractVersion: 2
                )
            ])
            try database.upsertSourceAttributions([
                makeRow(
                    key: "attr:v2-unresolved",
                    localPath: path,
                    displayName: "Dance",
                    navidromeSongId: nil,
                    contractVersion: 2
                )
            ])

            XCTAssertEqual(
                try database.sourceAttribution(forPath: path)?.navidromeSongId,
                "navidrome-song-1"
            )
        }
    }

    func testUpsertV1RowWithoutNavidromeSongIdPreservesExistingId() throws {
        let directory = try writeContractFixture(includeAttribution: true)
        let snapshot = try FetcherContractLoader().loadSnapshot(from: directory)
        let v1Row = try XCTUnwrap(
            snapshot.sourceAttribution.first { $0.attributionKey == "attr:one" }
        )

        try withTemporaryUserHome {
            let database = try DatabaseManager()
            try database.upsertSourceAttributions([
                makeRow(
                    key: "attr:v2-resolved",
                    localPath: v1Row.localPath,
                    displayName: "Dance",
                    navidromeSongId: "navidrome-song-1",
                    contractVersion: 2
                )
            ])

            try database.upsertSourceAttributions([v1Row])

            XCTAssertEqual(
                try database.sourceAttribution(forPath: v1Row.localPath)?.navidromeSongId,
                "navidrome-song-1"
            )
        }
    }

    func testMigrationAddsNavidromeSongIdColumnAndIndex() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.create(table: "source_attribution") { table in
                table.primaryKey("file_path", .text)
            }

            try DatabaseManager.migrateSourceAttributionSongId(db)

            let columns = try Row.fetchAll(
                db,
                sql: "PRAGMA table_info(source_attribution)"
            ).map { $0["name"] as String }
            XCTAssertTrue(columns.contains("navidrome_song_id"))

            let indexes = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'index'
                      AND name = 'idx_source_attribution_navidrome_song_id'
                    """
            )
            XCTAssertEqual(indexes, ["idx_source_attribution_navidrome_song_id"])
        }
    }

    func testSongIdJoinIgnoresSyntheticNavidromePath() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let song = Song(
                id: "navidrome-media-file-id",
                title: "Stay",
                album: "Stay - Single",
                albumId: "album-1",
                artist: "Marsh",
                artistId: "artist-1",
                track: 1,
                discNumber: 1,
                year: 2026,
                genre: nil,
                duration: 235,
                bitRate: 256,
                contentType: "audio/mp4",
                suffix: "m4a",
                coverArt: nil,
                path: "Marsh/Stay - Single/01-01 - Stay.m4a"
            )
            try database.saveSongs([song], serverId: "server-1")
            try database.upsertSourceAttributions([
                makeRow(
                    key: "attr:v2",
                    localPath: "/Ingest/music-fetcher/Apple/Playlists/Dance/Marsh - Stay.m4a",
                    displayName: "Apple Music",
                    navidromeSongId: song.id,
                    contractVersion: 2
                ),
                makeRow(
                    key: "attr:path-decoy",
                    localPath: song.path ?? "",
                    displayName: "Wrong path row",
                    navidromeSongId: "different-song",
                    contractVersion: 2
                )
            ])

            let direct = try XCTUnwrap(database.sourceAttribution(forSongId: song.id))
            XCTAssertEqual(direct.attributionKey, "attr:v2")

            let batch = try database.sourceAttributionsBySongId(songs: [song])
            XCTAssertEqual(batch[song.id]?.attributionKey, "attr:v2")
            XCTAssertNotEqual(batch[song.id]?.attributionKey, "attr:path-decoy")
        }
    }

    // MARK: - Persistence: exact lookup

    func testSourceAttributionForPathExactMatch() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            try database.upsertSourceAttributions([
                makeRow(key: "attr:one", localPath: "/srv/music/x.flac", displayName: "Alpha")
            ])

            XCTAssertEqual(try database.sourceAttribution(forPath: "/srv/music/x.flac")?.attributionKey, "attr:one")
            // Trailing/leading whitespace is tolerated on the query.
            XCTAssertEqual(try database.sourceAttribution(forPath: "  /srv/music/x.flac  ")?.attributionKey, "attr:one")
            XCTAssertNil(try database.sourceAttribution(forPath: "/srv/music/y.flac"))
            XCTAssertNil(try database.sourceAttribution(forPath: "   "))
        }
    }

    // MARK: - Persistence: suffix lookup

    func testSourceAttributionSuffixMatchJoinsRelativeNavidromePath() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            try database.upsertSourceAttributions([
                makeRow(key: "attr:one", localPath: "/srv/music/Rock/Artist/01 Track.flac", displayName: "Alpha")
            ])

            // Navidrome's path is relative to the music-folder root — a full suffix.
            XCTAssertEqual(
                try database.sourceAttribution(matchingSuffixOf: "Rock/Artist/01 Track.flac")?.attributionKey,
                "attr:one"
            )
            XCTAssertEqual(
                try database.sourceAttribution(matchingSuffixOf: "Artist/01 Track.flac")?.attributionKey,
                "attr:one"
            )
            // Empty / non-suffix queries do not match.
            XCTAssertNil(try database.sourceAttribution(matchingSuffixOf: ""))
            XCTAssertNil(try database.sourceAttribution(matchingSuffixOf: "Pop/Artist/01 Track.flac"))
        }
    }

    func testSourceAttributionSuffixMatchPrefersLongestAndBreaksTiesDeterministically() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            try database.upsertSourceAttributions([
                makeRow(key: "attr:a", localPath: "/srv/music/Rock/Artist/track.flac", displayName: "A"),
                makeRow(key: "attr:b", localPath: "/srv/other/Artist/track.flac", displayName: "B")
            ])

            // Three-component suffix only fully matches A; B differs above "Artist".
            XCTAssertEqual(
                try database.sourceAttribution(matchingSuffixOf: "Rock/Artist/track.flac")?.attributionKey,
                "attr:a"
            )
            // Both match the two-component suffix; tie broken by file_path ascending → A.
            XCTAssertEqual(
                try database.sourceAttribution(matchingSuffixOf: "Artist/track.flac")?.attributionKey,
                "attr:a"
            )
        }
    }

    func testSourceAttributionSuffixMatchPreservesBackslashInTitle() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            try database.upsertSourceAttributions([
                makeRow(
                    key: "attr:title",
                    localPath: #"/srv/music/Rock/Fuck You! Overkill (Men At Work \ Lily Allen).mp3"#,
                    displayName: "Title"
                )
            ])

            XCTAssertEqual(
                try database.sourceAttribution(
                    matchingSuffixOf: #"Rock/Fuck You! Overkill (Men At Work \ Lily Allen).mp3"#
                )?.attributionKey,
                "attr:title"
            )
        }
    }

    func testPathComponentHelpersHandlePosixSeparatorsAndDots() {
        XCTAssertEqual(
            DatabaseManager.normalizedPathComponents("/a/b//c/"),
            ["a", "b", "c"]
        )
        XCTAssertEqual(
            DatabaseManager.normalizedPathComponents(#"a\b\./c"#),
            [#"a\b\."#, "c"]
        )
        XCTAssertEqual(
            DatabaseManager.commonSuffixLength(["x", "b", "c"], ["a", "b", "c"]),
            2
        )
        XCTAssertEqual(
            DatabaseManager.commonSuffixLength([], ["a"]),
            0
        )
    }

    // MARK: - Fixtures & helpers

    private func makeRow(
        key: String,
        localPath: String,
        displayName: String,
        navidromeSongId: String? = nil,
        contractVersion: Int = 1
    ) -> FetcherSourceAttribution {
        FetcherSourceAttribution(
            attributionKey: key,
            localPath: localPath,
            sourceCollectionKey: "fetcher:source_collection:alpha",
            sourceKind: "apple_playlist",
            sourceDisplayName: displayName,
            downloadSource: "gamdl",
            queryContext: "ctx",
            acquiredAt: "2026-05-02T00:00:00.000Z",
            contractVersion: contractVersion,
            navidromeSongId: navidromeSongId
        )
    }

    private func writeContractFixture(
        includeAttribution: Bool,
        fetcherContractVersion: Int = 1
    ) throws -> URL {
        let directory = try makeTempDir()

        try write(
            """
            {
              "export_schema_version": 1,
              "generated_at": "2026-05-02T00:00:00.000Z",
              "fetcher_contract_version": \(fetcherContractVersion),
              "source_database": { "label": "fixture" },
              "row_counts": {},
              "content_hash": "sha256:fixture",
              "files": [],
              "redacted_paths": false
            }
            """,
            named: "contract-version.json",
            in: directory
        )

        for filename in [
            "source-collections.json",
            "source-items.json",
            "source-evidence.json",
            "candidate-imports.json",
            "identity-bridge.json",
            "generated-view-manifests.json",
            "contract-health.json"
        ] {
            try write("[]", named: filename, in: directory)
        }

        if includeAttribution {
            try write(
                """
                [
                  {
                    "attribution_key": "attr:one",
                    "local_path": "/srv/music/Rock/Artist/01 Track.flac",
                    "source_collection_key": "fetcher:source_collection:alpha",
                    "source_kind": "apple_playlist",
                    "source_display_name": "Alpha Source",
                    "download_source": "gamdl",
                    "query_context": "artist track",
                    "acquired_at": "2026-05-02T00:00:00.000Z",
                    "contract_version": 1
                  },
                  {
                    "attribution_key": "attr:two",
                    "local_path": "/srv/music/Jazz/Other/02 Second.mp3",
                    "source_collection_key": "fetcher:source_collection:beta",
                    "source_kind": "soundcloud_set",
                    "source_display_name": "Beta Source",
                    "download_source": null,
                    "query_context": null,
                    "acquired_at": null,
                    "contract_version": 1
                  }
                ]
                """,
                named: FetcherContractLoader.sourceAttributionFilename,
                in: directory
            )
        }

        return directory
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-source-attribution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    private func write(_ contents: String, named filename: String, in directory: URL) throws {
        try contents.write(to: directory.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }

    /// Isolates DatabaseManager's on-disk store to a throwaway home directory,
    /// mirroring the pattern used by CurationModelDraftTests.
    private func withTemporaryUserHome<T>(_ body: () throws -> T) throws -> T {
        let fileManager = FileManager.default
        let homeURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let previousHome = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
        setenv("CFFIXED_USER_HOME", homeURL.path, 1)

        defer {
            if let previousHome {
                setenv("CFFIXED_USER_HOME", previousHome, 1)
            } else {
                unsetenv("CFFIXED_USER_HOME")
            }
            try? fileManager.removeItem(at: homeURL)
        }

        return try body()
    }
}
