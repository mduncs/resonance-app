import XCTest
@testable import Resonance

final class UnclassifiedDockTests: XCTestCase {
    private let serverId = "srv-1"

    func testBatchAttributionResolvesExactSongIdsRegardlessOfPaths() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let exact = makeSong(id: "exact", path: "/srv/music/Artist/Album/01.flac")
            let suffix = makeSong(id: "suffix", path: "Artist/Album/02.flac")
            let unmatched = makeSong(id: "unmatched", path: "Other/Album/03.flac")
            try database.saveSongs([exact, suffix, unmatched], serverId: serverId)
            try database.upsertSourceAttributions([
                makeAttr(
                    key: "attr:exact",
                    localPath: "/different/fetcher/path/one.flac",
                    songId: exact.id
                ),
                makeAttr(
                    key: "attr:suffix",
                    localPath: "/another/unrelated/fetcher/path/two.flac",
                    songId: suffix.id
                )
            ])

            let records = try database.sourceAttributionsBySongId(
                songs: [exact, suffix, unmatched]
            )

            XCTAssertEqual(Set(records.keys), [exact.id, suffix.id])
            XCTAssertEqual(records[exact.id]?.attributionKey, "attr:exact")
            XCTAssertEqual(records[suffix.id]?.attributionKey, "attr:suffix")
        }
    }

    func testBatchAttributionDoesNotUsePathsAsFallback() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let nilPath = makeSong(id: "nil-path", path: nil)
            let emptyPath = makeSong(id: "empty-path", path: "")
            let exact = makeSong(id: "exact", path: "Artist/Album/Track.flac")
            try database.saveSongs([nilPath, emptyPath, exact], serverId: serverId)
            try database.upsertSourceAttributions([
                makeAttr(
                    key: "attr:suffix-competitor",
                    localPath: "/Volumes/Archive/Artist/Album/Track.flac",
                    songId: "different-song"
                ),
                makeAttr(
                    key: "attr:exact",
                    localPath: "/Fetcher/Path/Does Not Match.flac",
                    songId: exact.id
                ),
                makeAttr(
                    key: "attr:nil-path",
                    localPath: "/Fetcher/nil.flac",
                    songId: nilPath.id
                )
            ])

            let records = try database.sourceAttributionsBySongId(
                songs: [nilPath, emptyPath, exact]
            )

            XCTAssertEqual(Set(records.keys), [nilPath.id, exact.id])
            XCTAssertEqual(records[nilPath.id]?.attributionKey, "attr:nil-path")
            XCTAssertEqual(records[exact.id]?.attributionKey, "attr:exact")
        }
    }

    func testClearedTodayCountsBothSourcesAndDeduplicatesItemIds() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            let staged = makeSong(id: "staged", path: nil)
            try database.upsertWaitingRoomItem(
                song: staged,
                serverId: serverId,
                source: "unclassified"
            )
            try database.setWaitingRoomState(
                songId: staged.id,
                serverId: serverId,
                state: .admitted
            )
            try database.hideItem(
                id: "hidden",
                type: "song",
                serverId: serverId,
                reason: "unclassified_reject"
            )

            XCTAssertEqual(try database.unclassifiedClearedTodayCount(serverId: serverId), 2)

            try database.hideItem(
                id: staged.id,
                type: "song",
                serverId: serverId,
                reason: "unclassified_reject"
            )

            XCTAssertEqual(try database.unclassifiedClearedTodayCount(serverId: serverId), 2)
        }
    }

    func testClearedTodayExcludesOtherServersReasonsAndSources() throws {
        try withTemporaryUserHome {
            let database = try DatabaseManager()
            try database.upsertWaitingRoomItem(
                song: makeSong(id: "foreign", path: nil),
                serverId: "srv-other",
                source: "unclassified"
            )
            try database.hideItem(
                id: "manual-hide",
                type: "song",
                serverId: serverId,
                reason: "manual"
            )
            try database.upsertWaitingRoomItem(
                song: makeSong(id: "quick-capture", path: nil),
                serverId: serverId,
                source: "quick_capture"
            )

            XCTAssertEqual(try database.unclassifiedClearedTodayCount(serverId: serverId), 0)
        }
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
            genre: "Rock",
            duration: 200,
            bitRate: 320,
            contentType: "audio/flac",
            suffix: "flac",
            coverArt: nil,
            path: path
        )
    }

    private func makeAttr(
        key: String,
        localPath: String,
        songId: String
    ) -> FetcherSourceAttribution {
        FetcherSourceAttribution(
            attributionKey: key,
            localPath: localPath,
            sourceCollectionKey: "collection:\(key)",
            sourceKind: "apple_playlist",
            sourceDisplayName: "Display \(key)",
            downloadSource: "gamdl",
            queryContext: "ctx",
            acquiredAt: "2026-02-01T00:00:00.000Z",
            contractVersion: 2,
            navidromeSongId: songId
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
