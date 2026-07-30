import XCTest
@testable import Resonance

final class FetcherAutomakeTests: XCTestCase {
    private let serverId = "srv-1"

    // MARK: - 1. Category column round-trip (v7 migration)

    func testProjectCategoryRoundTrip() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let categorized = Project(serverId: serverId, name: "Techno Digs", category: "Electronic")
            let plain = Project(serverId: serverId, name: "Hand Made")
            try database.saveProject(categorized)
            try database.saveProject(plain)

            let loaded = try database.loadProjects(serverId: serverId)
            XCTAssertEqual(loaded.first { $0.id == categorized.id }?.category, "Electronic")
            XCTAssertNil(loaded.first { $0.id == plain.id }?.category)

            try database.updateProjectCategory(id: plain.id, serverId: serverId, category: "Jazz")
            let reloaded = try database.loadProjects(serverId: serverId)
            XCTAssertEqual(reloaded.first { $0.id == plain.id }?.category, "Jazz")
        }
    }

    // MARK: - 2. Deterministic project identity

    func testDeterministicProjectIdIsStableAndScoped() {
        let a = FetcherProjectAutomake.deterministicProjectId(
            serverId: "srv-1", sourceCollectionKey: "fetcher:source_collection:apple_playlist:pl.abc"
        )
        let b = FetcherProjectAutomake.deterministicProjectId(
            serverId: "srv-1", sourceCollectionKey: "fetcher:source_collection:apple_playlist:pl.abc"
        )
        let otherServer = FetcherProjectAutomake.deterministicProjectId(
            serverId: "srv-2", sourceCollectionKey: "fetcher:source_collection:apple_playlist:pl.abc"
        )
        let otherKey = FetcherProjectAutomake.deterministicProjectId(
            serverId: "srv-1", sourceCollectionKey: "fetcher:source_collection:apple_room:boiler"
        )

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, otherServer)
        XCTAssertNotEqual(a, otherKey)
        XCTAssertTrue(a.hasPrefix("fetcher-automake:"))
    }

    // MARK: - 3. Lineage normalization

    func testNormalizedCategoryFoldsPlaylistAndRoomForms() {
        XCTAssertEqual(FetcherProjectAutomake.normalizedCategory("Electronic"), "Electronic")
        XCTAssertEqual(FetcherProjectAutomake.normalizedCategory("classical"), "Classical")
        XCTAssertEqual(FetcherProjectAutomake.normalizedCategory("Decades"), "Decades")
        XCTAssertEqual(FetcherProjectAutomake.normalizedCategory("decades"), "Decades")
        XCTAssertEqual(FetcherProjectAutomake.normalizedCategory("dj-mixes"), "DJ Mixes")
        XCTAssertEqual(FetcherProjectAutomake.normalizedCategory("apple_music_club"), "Apple Music Club")
        XCTAssertEqual(FetcherProjectAutomake.normalizedCategory("Other"), "Other")
        XCTAssertEqual(FetcherProjectAutomake.normalizedCategory("   "), "Other")
        XCTAssertEqual(FetcherProjectAutomake.normalizedCategory(nil), "Other")
    }

    func testSourceDomainParsesContractJson() {
        XCTAssertEqual(
            FetcherProjectAutomake.sourceDomain(
                from: #"{"source_kind":"apple_playlist","collection_kind":"playlist","source_domain":"Electronic"}"#
            ),
            "Electronic"
        )
        XCTAssertNil(FetcherProjectAutomake.sourceDomain(from: #"{"source_kind":"apple_room"}"#))
        XCTAssertNil(FetcherProjectAutomake.sourceDomain(from: "not json"))
        XCTAssertNil(FetcherProjectAutomake.sourceDomain(from: nil))
    }

    func testProjectNameTitleCasesSlugsAndKeepsHumanNames() {
        XCTAssertEqual(FetcherProjectAutomake.projectName(fromDisplayName: "hypnotic-techno"), "Hypnotic Techno")
        XCTAssertEqual(FetcherProjectAutomake.projectName(fromDisplayName: "uk-bass-essentials"), "Uk Bass Essentials")
        XCTAssertEqual(FetcherProjectAutomake.projectName(fromDisplayName: "Boiler Room"), "Boiler Room")
        XCTAssertEqual(FetcherProjectAutomake.projectName(fromDisplayName: "80s Essential Albums"), "80s Essential Albums")
        XCTAssertEqual(FetcherProjectAutomake.projectName(fromDisplayName: "  "), "Untitled Source")
    }

    // MARK: - 4. Collection → song resolution via exact attribution ids

    func testSongIdsBySourceCollectionKeyResolvesExactNavidromeIds() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            try database.saveSongs(
                [
                    makeSong(id: "s1", path: "Electronic/Hypnotic/one.flac"),
                    makeSong(id: "s2", path: "Electronic/Hypnotic/two.flac"),
                    makeSong(id: "s3", path: "Jazz/other.flac"),
                    makeSong(id: "s4", path: nil)
                ],
                serverId: serverId
            )
            try database.upsertSourceAttributions([
                attribution(key: "a1", localPath: "/Volumes/External/MusicLibrary/Electronic/Hypnotic/one.flac",
                            collectionKey: "col-hypnotic", songId: "s1",
                            acquiredAt: "2026-01-01T00:00:00Z"),
                attribution(key: "a2", localPath: "/Volumes/External/MusicLibrary/Electronic/Hypnotic/two.flac",
                            collectionKey: "col-hypnotic", songId: "s2",
                            acquiredAt: "2026-01-02T00:00:00Z"),
                attribution(key: "a3", localPath: "/Volumes/External/MusicLibrary/Jazz/other.flac",
                            collectionKey: "col-jazz", songId: "s3",
                            acquiredAt: "2026-01-03T00:00:00Z")
            ])

            let grouped = try database.songIdsBySourceCollectionKey(serverId: serverId)
            XCTAssertEqual(grouped["col-hypnotic"], ["s1", "s2"])
            XCTAssertEqual(grouped["col-jazz"], ["s3"])
            XCTAssertEqual(grouped.count, 2)
        }
    }

    // MARK: - 5. Automake idempotency + archive respect

    func testAutomakeIsIdempotentAndRespectsArchive() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            try database.saveSongs(
                [
                    makeSong(id: "s1", path: "Electronic/Hypnotic/one.flac"),
                    makeSong(id: "s2", path: "Electronic/Hypnotic/two.flac")
                ],
                serverId: serverId
            )
            try database.upsertSourceAttributions([
                attribution(key: "a1", localPath: "/Volumes/X/Electronic/Hypnotic/one.flac",
                            collectionKey: "col-hypnotic", songId: "s1",
                            acquiredAt: "2026-01-01T00:00:00Z"),
                attribution(key: "a2", localPath: "/Volumes/X/Electronic/Hypnotic/two.flac",
                            collectionKey: "col-hypnotic", songId: "s2",
                            acquiredAt: "2026-01-02T00:00:00Z")
            ])
            let snapshot = makeSnapshot(collections: [
                collection(key: "col-hypnotic", sourceKind: "apple_playlist",
                           displayName: "hypnotic-techno", sourceDomain: "Electronic"),
                collection(key: "col-album", sourceKind: "apple_album",
                           displayName: "some-album", sourceDomain: "Electronic")
            ])

            let first = try FetcherProjectAutomake.run(
                snapshot: snapshot, serverId: serverId, database: database
            )
            XCTAssertEqual(first.createdProjectIds.count, 1)
            XCTAssertEqual(first.addedSongCount, 2)
            XCTAssertTrue(first.didChangeAnything)

            let projects = try database.loadProjects(serverId: serverId)
            XCTAssertEqual(projects.count, 1)
            let project = try XCTUnwrap(projects.first)
            XCTAssertEqual(project.name, "Hypnotic Techno")
            XCTAssertEqual(project.kind, "collection")
            XCTAssertEqual(project.category, "Electronic")
            XCTAssertEqual(
                project.id,
                FetcherProjectAutomake.deterministicProjectId(
                    serverId: serverId, sourceCollectionKey: "col-hypnotic"
                )
            )

            // Second run: same project, no new items, nothing reported changed.
            let second = try FetcherProjectAutomake.run(
                snapshot: snapshot, serverId: serverId, database: database
            )
            XCTAssertTrue(second.createdProjectIds.isEmpty)
            XCTAssertEqual(second.addedSongCount, 0)
            XCTAssertFalse(second.didChangeAnything)
            XCTAssertEqual(try database.loadProjects(serverId: serverId).count, 1)
            let items = try database.loadProjectItems(projectId: project.id, serverId: serverId)
            XCTAssertEqual(items.count, 2)

            // Archived by md: automake must not resurrect or touch it.
            try database.archiveProject(id: project.id, serverId: serverId)
            let third = try FetcherProjectAutomake.run(
                snapshot: snapshot, serverId: serverId, database: database
            )
            XCTAssertEqual(third.skippedArchivedCount, 1)
            XCTAssertFalse(third.didChangeAnything)
            XCTAssertTrue(try database.loadProjects(serverId: serverId).isEmpty)
        }
    }

    // MARK: - Helpers

    private func attribution(
        key: String,
        localPath: String,
        collectionKey: String,
        songId: String,
        acquiredAt: String
    ) -> FetcherSourceAttribution {
        FetcherSourceAttribution(
            attributionKey: key,
            localPath: localPath,
            sourceCollectionKey: collectionKey,
            sourceKind: "apple_playlist",
            sourceDisplayName: "Display",
            downloadSource: "gamdl",
            queryContext: nil,
            acquiredAt: acquiredAt,
            contractVersion: 2,
            navidromeSongId: songId
        )
    }

    private func collection(
        key: String,
        sourceKind: String,
        displayName: String,
        sourceDomain: String?
    ) -> FetcherSourceCollection {
        let json = sourceDomain.map {
            "{\"source_kind\":\"\(sourceKind)\",\"collection_kind\":\"playlist\",\"source_domain\":\"\($0)\"}"
        }
        return FetcherSourceCollection(
            sourceCollectionKey: key,
            sourceKind: sourceKind,
            domain: "apple_music",
            displayName: displayName,
            externalUrl: nil,
            externalId: nil,
            lastObservedAt: nil,
            lastSuccessfulObservedAt: nil,
            staleState: "fresh",
            currentItemCount: 2,
            allSeenItemCount: 2,
            removedItemCount: 0,
            lastChangeAt: nil,
            sourceSpecificJson: json,
            contractVersion: 1
        )
    }

    private func makeSnapshot(collections: [FetcherSourceCollection]) -> FetcherContractSnapshot {
        FetcherContractSnapshot(
            metadata: FetcherContractMetadata(
                exportSchemaVersion: 1,
                generatedAt: "2026-07-24T00:00:00Z",
                fetcherContractVersion: 1,
                sourceDatabase: FetcherContractSourceDatabase(label: "test"),
                rowCounts: [:],
                contentHash: "test",
                files: [],
                redactedPaths: false
            ),
            sourceCollections: collections,
            sourceItems: [],
            sourceEvidence: [],
            candidateImports: [],
            identityBridge: [],
            generatedViewManifests: [],
            contractHealth: [],
            sourceAttribution: []
        )
    }

    private func makeSong(id: String, path: String?) -> Song {
        Song(
            id: id,
            title: "Title \(id)",
            album: "Album",
            albumId: "album-1",
            artist: "Artist",
            artistId: "artist-1",
            track: 1,
            discNumber: 1,
            year: 2026,
            genre: "Electronic",
            duration: 200,
            bitRate: 320,
            contentType: "audio/flac",
            suffix: "flac",
            coverArt: nil,
            path: path
        )
    }

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
