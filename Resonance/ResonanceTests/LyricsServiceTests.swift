import XCTest
@testable import Resonance

final class LyricsServiceTests: XCTestCase {
    func testValidNegativeCacheSkipsBothSources() async throws {
        let harness = try await LyricsServiceHarness()
        defer { harness.cleanup() }
        let probe = LyricsSourceProbe()
        await harness.cache.cacheLyrics(
            .notFound(songId: Song.placeholder.id),
            for: Song.placeholder.id,
            serverId: harness.serverID
        )
        let service = harness.makeService(probe: probe)

        let result = await service.lookupLyrics(for: .placeholder)

        guard case .notFound = result else {
            return XCTFail("Expected a cached no-lyrics result")
        }
        let counts = await probe.counts
        XCTAssertEqual(counts.navidrome, 0)
        XCTAssertEqual(counts.lrclib, 0)
    }

    func testPersonalSourceFailureAndLRCLibMissRemainRetryable() async throws {
        let harness = try await LyricsServiceHarness()
        defer { harness.cleanup() }
        let probe = LyricsSourceProbe(
            navidromeResult: .failed,
            lrclibResult: .notFound
        )
        let service = harness.makeService(probe: probe)

        let result = await service.lookupLyrics(for: .placeholder)

        guard case .failed = result else {
            return XCTFail("An external miss cannot prove personal lyrics are absent")
        }
        let cached = await harness.cache.getLyrics(
            for: Song.placeholder.id,
            serverId: harness.serverID
        )
        XCTAssertNil(cached)
        let counts = await probe.counts
        XCTAssertEqual(counts.navidrome, 1)
        XCTAssertEqual(counts.lrclib, 1)
    }

    func testCancellationStopsFallbackAndNegativeCacheWrite() async throws {
        let harness = try await LyricsServiceHarness()
        defer { harness.cleanup() }
        let probe = LyricsSourceProbe(
            navidromeResult: .notFound,
            lrclibResult: .notFound,
            navidromeDelay: .seconds(5)
        )
        let service = harness.makeService(probe: probe)
        let lookup = Task { await service.lookupLyrics(for: .placeholder) }
        try await waitForNavidromeStart(probe)

        lookup.cancel()
        let result = await lookup.value

        guard case .failed = result else {
            return XCTFail("Canceled lookup should not publish an empty or error fallback")
        }
        let counts = await probe.counts
        XCTAssertEqual(counts.navidrome, 1)
        XCTAssertEqual(counts.lrclib, 0)
        XCTAssertEqual(counts.canceledNavidrome, 1)
        let cached = await harness.cache.getLyrics(
            for: Song.placeholder.id,
            serverId: harness.serverID
        )
        XCTAssertNil(cached)
    }

    func testCooperativeSourceDeadlineCompletesAndCancelsSlowChild() async throws {
        let harness = try await LyricsServiceHarness()
        defer { harness.cleanup() }
        let probe = LyricsSourceProbe(
            navidromeResult: .notFound,
            lrclibResult: .notFound,
            navidromeDelay: .seconds(5)
        )
        let service = harness.makeService(
            probe: probe,
            navidromeDeadline: .milliseconds(20)
        )
        let clock = ContinuousClock()
        let start = clock.now

        let result = await service.lookupLyrics(for: .placeholder)
        let elapsed = start.duration(to: clock.now)

        guard case .failed = result else {
            return XCTFail("A timed-out personal source must remain retryable")
        }
        XCTAssertLessThan(elapsed, .seconds(1))
        let counts = await probe.counts
        XCTAssertEqual(counts.canceledNavidrome, 1)
        XCTAssertEqual(counts.lrclib, 1)
    }

    func testLRCFractionPrecisionUsesDigitCount() throws {
        let cases: [(String, Double)] = [
            ("[01:02.003] line", 62.003),
            ("[01:02.03] line", 62.03),
            ("[00:00.099] line", 0.099),
            ("[00:00.99] line", 0.99),
            ("[00:00.000] line", 0),
            ("[00:00.999] line", 0.999)
        ]
        for (input, expected) in cases {
            let line = try XCTUnwrap(LRCParser.parse(input).first)
            XCTAssertEqual(try XCTUnwrap(line.timestamp), expected, accuracy: 0.000_001)
            XCTAssertEqual(line.text, "line")
        }
    }

    func testPreferredLyricsFallsBackFromBlankSyncedTextToPlainText() {
        let cached = CachedLyrics(
            songId: "song",
            source: .lrclib,
            syncedLyrics: "  \n\t",
            plainLyrics: "A real plain lyric",
            fetchedAt: Date()
        )

        XCTAssertEqual(cached.preferredLyricsText, "A real plain lyric")
    }

    func testCancellableParserRejectsMoreThanTheDisplayLineLimit() {
        let content = Array(repeating: "line", count: 4).joined(separator: "\n")

        XCTAssertThrowsError(try LRCParser.parseCancellable(content, maximumLines: 3)) { error in
            XCTAssertEqual(error as? LyricsParsingError, .payloadTooLarge)
        }
    }

    func testDocumentParserRejectsOversizedPayloadBeforeBuildingLines() async {
        let content = String(
            repeating: "x",
            count: LyricsDocumentParser.maximumUTF8Bytes + 1
        )

        do {
            _ = try await LyricsDocumentParser.parse(content)
            XCTFail("Expected the oversized payload to be rejected")
        } catch let error as LyricsParsingError {
            XCTAssertEqual(error, .payloadTooLarge)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testParserHonorsTaskCancellation() async {
        let content = Array(repeating: "[00:01.00] line", count: 10_000)
            .joined(separator: "\n")
        let task = Task { () throws -> [LyricLine] in
            await Task.yield()
            return try LRCParser.parseCancellable(content, maximumLines: .max)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected parsing to stop after cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    
    // MARK: - LRCLIB Response Parsing
    
    func testLRCLibResponseDecoding() throws {
        let json = """
        {
            "id": 123,
            "trackName": "Test Song",
            "artistName": "Test Artist",
            "albumName": "Test Album",
            "duration": 180.5,
            "instrumental": false,
            "plainLyrics": "Line 1\\nLine 2\\nLine 3",
            "syncedLyrics": "[00:12.34] Line 1\\n[00:24.56] Line 2\\n[00:36.78] Line 3"
        }
        """.data(using: .utf8)!
        
        let response = try JSONDecoder().decode(LRCLibResponse.self, from: json)
        
        XCTAssertEqual(response.id, 123)
        XCTAssertEqual(response.trackName, "Test Song")
        XCTAssertEqual(response.artistName, "Test Artist")
        XCTAssertEqual(response.albumName, "Test Album")
        XCTAssertEqual(response.duration, 180.5)
        XCTAssertEqual(response.instrumental, false)
        XCTAssertNotNil(response.plainLyrics)
        XCTAssertNotNil(response.syncedLyrics)
    }
    
    func testLRCLibResponseInstrumental() throws {
        let json = """
        {
            "id": 456,
            "trackName": "Instrumental Track",
            "artistName": "Artist",
            "instrumental": true
        }
        """.data(using: .utf8)!
        
        let response = try JSONDecoder().decode(LRCLibResponse.self, from: json)
        
        XCTAssertEqual(response.instrumental, true)
        XCTAssertNil(response.plainLyrics)
        XCTAssertNil(response.syncedLyrics)
    }
    
    // MARK: - CachedLyrics
    
    func testCachedLyricsCoding() throws {
        let original = CachedLyrics(
            songId: "song123",
            source: .lrclib,
            syncedLyrics: "[00:00.00] Test",
            plainLyrics: "Test",
            fetchedAt: Date()
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CachedLyrics.self, from: data)
        
        XCTAssertEqual(decoded.songId, original.songId)
        XCTAssertEqual(decoded.source, original.source)
        XCTAssertEqual(decoded.syncedLyrics, original.syncedLyrics)
        XCTAssertEqual(decoded.plainLyrics, original.plainLyrics)
    }
    
    func testCachedLyricsIsNotFound() {
        let notFound = CachedLyrics(
            songId: "song1",
            source: .notFound,
            syncedLyrics: nil,
            plainLyrics: nil,
            fetchedAt: Date()
        )
        XCTAssertTrue(notFound.isNotFound)

        let found = CachedLyrics(
            songId: "song2",
            source: .lrclib,
            syncedLyrics: "[00:00.00] Lyrics",
            plainLyrics: nil,
            fetchedAt: Date()
        )
        XCTAssertFalse(found.isNotFound)
    }

    func testCachedLyricsValidity() {
        let recentNotFound = CachedLyrics.notFound(songId: "song1")
        XCTAssertTrue(recentNotFound.isValid(ttl: 86400), "Recent not-found should be valid")

        let foundLyrics = CachedLyrics(
            songId: "song2",
            source: .lrclib,
            syncedLyrics: "[00:00.00] Test",
            plainLyrics: nil,
            fetchedAt: Date.distantPast
        )
        XCTAssertTrue(foundLyrics.isValid(), "Found lyrics should always be valid")
    }
    
    // MARK: - LyricsSource
    
    func testLyricsSourceCoding() throws {
        let sources: [LyricsSource] = [.navidrome, .lrclib, .notFound]
        
        for source in sources {
            let data = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(LyricsSource.self, from: data)
            XCTAssertEqual(decoded, source)
        }
    }
}

final class LibrarySearchFieldLifecycleTests: XCTestCase {
    func testDeactivationRejectsDeferredGeneration() {
        var lifecycle = LibrarySearchFieldLifecycle()
        let mounted = lifecycle.activate()
        XCTAssertTrue(lifecycle.permits(mounted))

        lifecycle.deactivate()

        XCTAssertFalse(lifecycle.permits(mounted))
    }

    func testRemountRejectsCallbacksFromEarlierMount() {
        var lifecycle = LibrarySearchFieldLifecycle()
        let firstMount = lifecycle.activate()
        lifecycle.deactivate()
        let secondMount = lifecycle.activate()

        XCTAssertFalse(lifecycle.permits(firstMount))
        XCTAssertTrue(lifecycle.permits(secondMount))
    }
}

final class PlaylistDetailStabilityTests: XCTestCase {
    func testVisibilityProjectionPreservesDuplicateOccurrencesAndOrder() throws {
        let duplicate = makeSong(id: "duplicate", albumID: "album", artistID: "artist")
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let entries = [
            PlaylistSongEntry(id: firstID, song: duplicate),
            PlaylistSongEntry(id: secondID, song: duplicate)
        ]

        let visible = PlaylistVisibilityProjection.visibleEntries(
            from: entries,
            hiddenSongIDs: [],
            hiddenAlbumIDs: [],
            hiddenArtistIDs: []
        )

        XCTAssertEqual(visible.map(\.id), [firstID, secondID])
        XCTAssertEqual(visible.map(\.song.id), ["duplicate", "duplicate"])
    }

    func testVisibilityProjectionRespondsToEveryHiddenScope() {
        let entries = [
            PlaylistSongEntry(song: makeSong(id: "hidden-song", albumID: "a1", artistID: "r1")),
            PlaylistSongEntry(song: makeSong(id: "hidden-album", albumID: "a2", artistID: "r2")),
            PlaylistSongEntry(song: makeSong(id: "hidden-artist", albumID: "a3", artistID: "r3")),
            PlaylistSongEntry(song: makeSong(id: "visible", albumID: "a4", artistID: "r4"))
        ]

        let visible = PlaylistVisibilityProjection.visibleEntries(
            from: entries,
            hiddenSongIDs: ["hidden-song"],
            hiddenAlbumIDs: ["a2"],
            hiddenArtistIDs: ["r3"]
        )

        XCTAssertEqual(visible.map(\.song.id), ["visible"])
    }

    func testVisibilityProjectionHandlesLargeDuplicatePlaylistWithoutLosingOccurrences() {
        let song = makeSong(id: "repeated", albumID: "album", artistID: "artist")
        let entries = (0..<50_000).map { _ in PlaylistSongEntry(song: song) }

        let visible = PlaylistVisibilityProjection.visibleEntries(
            from: entries,
            hiddenSongIDs: [],
            hiddenAlbumIDs: [],
            hiddenArtistIDs: []
        )

        XCTAssertEqual(visible.count, entries.count)
        XCTAssertEqual(visible.map(\.id), entries.map(\.id))
    }

    private func makeSong(id: String, albumID: String, artistID: String) -> Song {
        Song(
            id: id,
            title: id,
            album: "Album",
            albumId: albumID,
            artist: "Artist",
            artistId: artistID,
            track: nil,
            discNumber: nil,
            year: nil,
            genre: nil,
            duration: 180,
            bitRate: nil,
            contentType: "audio/mpeg",
            suffix: "mp3",
            coverArt: nil,
            starred: nil,
            rating: nil,
            replayGain: nil
        )
    }
}

private actor LyricsSourceProbe {
    struct Counts: Sendable {
        let navidrome: Int
        let lrclib: Int
        let canceledNavidrome: Int
    }

    private let navidromeResult: LyricsService.SourceResult
    private let lrclibResult: LyricsService.SourceResult
    private let navidromeDelay: Duration?
    private var navidromeCount = 0
    private var lrclibCount = 0
    private var canceledNavidromeCount = 0

    init(
        navidromeResult: LyricsService.SourceResult = .failed,
        lrclibResult: LyricsService.SourceResult = .failed,
        navidromeDelay: Duration? = nil
    ) {
        self.navidromeResult = navidromeResult
        self.lrclibResult = lrclibResult
        self.navidromeDelay = navidromeDelay
    }

    func fetchNavidrome(song: Song, serverID: UUID?) async -> LyricsService.SourceResult {
        _ = song
        _ = serverID
        navidromeCount += 1
        if let navidromeDelay {
            do {
                try await Task.sleep(for: navidromeDelay)
            } catch {
                canceledNavidromeCount += 1
                return .failed
            }
        }
        return navidromeResult
    }

    func fetchLRCLib(song: Song) -> LyricsService.SourceResult {
        _ = song
        lrclibCount += 1
        return lrclibResult
    }

    var counts: Counts {
        Counts(
            navidrome: navidromeCount,
            lrclib: lrclibCount,
            canceledNavidrome: canceledNavidromeCount
        )
    }
}

private struct LyricsServiceHarness {
    let rootURL: URL
    let cache: CacheActor
    let network: NetworkActor
    let serverID: UUID

    init() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheURL = rootURL.appendingPathComponent("Cache", isDirectory: true)
        let downloadsURL = rootURL.appendingPathComponent("Downloads", isDirectory: true)
        cache = CacheActor(cacheDirectory: cacheURL, downloadsDirectory: downloadsURL)
        network = NetworkActor()
        serverID = UUID()
        let server = Server(
            id: serverID,
            name: "Lyrics service test",
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:4534")),
            username: "test"
        )
        await network.configure(server: server, password: "test")
    }

    func makeService(
        probe: LyricsSourceProbe,
        navidromeDeadline: Duration = .seconds(1),
        lrclibDeadline: Duration = .seconds(1)
    ) -> LyricsService {
        LyricsService(
            networkActor: network,
            cacheActor: cache,
            navidromeSource: { song, serverID in
                await probe.fetchNavidrome(song: song, serverID: serverID)
            },
            lrclibSource: { song in
                await probe.fetchLRCLib(song: song)
            },
            navidromeDeadline: navidromeDeadline,
            lrclibDeadline: lrclibDeadline
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private func waitForNavidromeStart(_ probe: LyricsSourceProbe) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
        if await probe.counts.navidrome > 0 { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for the injected Navidrome source")
}
