import XCTest
@testable import Resonance

final class CacheActorTests: XCTestCase {
    func testQueueDownloadPromotesPlaybackCacheIntoIntentionalDownloads() async throws {
        let harness = try TestHarness()
        let cacheActor = harness.makeCacheActor()
        let serverId = UUID()
        let song = makeSong(id: "song-flac", suffix: "flac")

        let playbackPath = try await cacheActor.cacheAudio(
            Data([0x01, 0x02, 0x03]),
            for: song.id,
            serverId: serverId,
            suffix: song.suffix
        )

        await cacheActor.queueDownload(song: song, serverId: serverId)

        let downloadedPath = await cacheActor.getDownloadedAudioPath(
            for: song.id,
            serverId: serverId,
            preferredSuffix: song.suffix
        )
        let resolvedPlaybackPath = await cacheActor.getAudioPath(
            for: song.id,
            serverId: serverId,
            suffix: song.suffix
        )

        XCTAssertNotNil(downloadedPath)
        XCTAssertEqual(resolvedPlaybackPath?.path, downloadedPath?.path)
        XCTAssertEqual(downloadedPath?.pathExtension, "flac")
        XCTAssertNotEqual(downloadedPath?.path, playbackPath.path)
        let isDownloaded = await cacheActor.isDownloaded(songId: song.id, serverId: serverId)
        let downloads = await cacheActor.enumerateDownloadedSongs(serverId: serverId)
        XCTAssertTrue(isDownloaded)
        XCTAssertEqual(downloads.count, 1)
    }

    func testQueueDownloadUsesQueuedSongSuffixForIntentionalDownloads() async throws {
        let harness = try TestHarness()
        let cacheActor = harness.makeCacheActor()
        let serverId = UUID()
        let song = makeSong(id: "song-lossless", suffix: "alac")

        await cacheActor.setDownloadHandler { _, _ in
            (Data([0x0A, 0x0B, 0x0C]), "mp3")
        }

        await cacheActor.queueDownload(song: song, serverId: serverId)

        let downloadedPath = try await waitForDownloadedPath(
            cacheActor: cacheActor,
            songId: song.id,
            serverId: serverId,
            preferredSuffix: song.suffix
        )

        XCTAssertEqual(downloadedPath.pathExtension, "alac")

        let downloads = await cacheActor.enumerateDownloadedSongs(serverId: serverId)
        XCTAssertEqual(downloads.map(\.songId), [song.id])
        XCTAssertEqual(downloads.first?.suffix, "alac")
    }

    func testCacheStatsSeparatePlaybackCacheFromOfflineDownloads() async throws {
        let harness = try TestHarness()
        let cacheActor = harness.makeCacheActor()
        let serverId = UUID()
        let song = makeSong(id: "song-stats", suffix: "flac")

        _ = try await cacheActor.cacheAudio(
            Data([0x01, 0x02, 0x03]),
            for: song.id,
            serverId: serverId,
            suffix: song.suffix
        )
        await cacheActor.queueDownload(song: song, serverId: serverId)

        let stats = await cacheActor.getCacheStats()
        XCTAssertGreaterThanOrEqual(stats.audioSize, 3)
        XCTAssertGreaterThanOrEqual(stats.downloadSize, 3)

        await cacheActor.clearAll()

        let clearedStats = await cacheActor.getCacheStats()
        let downloadedPath = await cacheActor.getDownloadedAudioPath(
            for: song.id,
            serverId: serverId,
            preferredSuffix: song.suffix
        )

        XCTAssertEqual(clearedStats.audioSize, 0)
        XCTAssertGreaterThanOrEqual(clearedStats.downloadSize, 3)
        XCTAssertNotNil(downloadedPath)
    }

    private func waitForDownloadedPath(
        cacheActor: CacheActor,
        songId: String,
        serverId: UUID,
        preferredSuffix: String,
        timeout: TimeInterval = 2
    ) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let path = await cacheActor.getDownloadedAudioPath(
                for: songId,
                serverId: serverId,
                preferredSuffix: preferredSuffix
            ) {
                return path
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTFail("Timed out waiting for download \(songId)")
        return URL(fileURLWithPath: "/dev/null")
    }

    private func makeSong(id: String, suffix: String) -> Song {
        Song(
            id: id,
            title: "Test Song \(id)",
            album: "Album",
            albumId: "album",
            artist: "Artist",
            artistId: "artist",
            track: 1,
            discNumber: 1,
            year: 2026,
            genre: "Rock",
            duration: 180,
            bitRate: 320,
            contentType: "audio/\(suffix)",
            suffix: suffix,
            coverArt: nil,
            starred: nil,
            rating: nil,
            replayGain: nil,
            isExplicit: false
        )
    }
}

private struct TestHarness {
    let rootURL: URL
    let cacheURL: URL
    let downloadsURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        cacheURL = rootURL.appendingPathComponent("Cache", isDirectory: true)
        downloadsURL = rootURL.appendingPathComponent("Downloads", isDirectory: true)

        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
    }

    func makeCacheActor() -> CacheActor {
        CacheActor(cacheDirectory: cacheURL, downloadsDirectory: downloadsURL)
    }
}
