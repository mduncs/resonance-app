import XCTest
@testable import Resonance

final class CacheActorTests: XCTestCase {
    func testLyricsCacheSeparatesIdenticalSongIDsByServer() async throws {
        let harness = try TestHarness()
        let cache = harness.makeCacheActor()
        let serverA = UUID()
        let serverB = UUID()
        let a = CachedLyrics(songId: "same-id", source: .navidrome,
                             syncedLyrics: nil, plainLyrics: "Server A", fetchedAt: Date())
        let b = CachedLyrics(songId: "same-id", source: .navidrome,
                             syncedLyrics: nil, plainLyrics: "Server B", fetchedAt: Date())
        await cache.cacheLyrics(a, for: "same-id", serverId: serverA)
        await cache.cacheLyrics(b, for: "same-id", serverId: serverB)
        let readA = await cache.getLyrics(for: "same-id", serverId: serverA)
        let readB = await cache.getLyrics(for: "same-id", serverId: serverB)
        let unscoped = await cache.getLyrics(for: "same-id", serverId: nil)
        XCTAssertEqual(readA?.plainLyrics, "Server A")
        XCTAssertEqual(readB?.plainLyrics, "Server B")
        XCTAssertNil(unscoped)
    }

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

        try await cacheActor.clearAll()

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

    @MainActor
    func testDeletingIntentionalDownloadInvalidatesOnlyItsServerManifest() async throws {
        let harness = try TestHarness()
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        let serverA = UUID()
        let serverB = UUID()
        let song = makeSong(id: "same-song-on-two-servers", suffix: "flac")

        // Start with valid empty manifests to avoid asynchronous migration writes
        // becoming mistaken for the deletion notification under test.
        for serverId in [serverA, serverB] {
            let directory = harness.downloadsURL.appendingPathComponent(serverId.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        }
        let cacheActor = harness.makeCacheActor()
        var playbackPaths: [UUID: URL] = [:]
        for serverId in [serverA, serverB] {
            playbackPaths[serverId] = try await cacheActor.cacheAudio(
                Data([0x01, 0x02, 0x03]), for: song.id, serverId: serverId, suffix: song.suffix
            )
            await cacheActor.queueDownload(song: song, serverId: serverId)
        }
        let progress = cacheActor.downloadProgress
        try await waitForManifestRevision(progress, serverId: serverA, atLeast: 1)
        try await waitForManifestRevision(progress, serverId: serverB, atLeast: 1)
        let revisionA = progress.manifestRevisions[serverA] ?? 0
        let revisionB = progress.manifestRevisions[serverB] ?? 0
        let downloadedA = await cacheActor.isDownloaded(songId: song.id, serverId: serverA)
        let downloadedB = await cacheActor.isDownloaded(songId: song.id, serverId: serverB)
        XCTAssertTrue(downloadedA)
        XCTAssertTrue(downloadedB)
        let pathA = await cacheActor.getDownloadedAudioPath(for: song.id, serverId: serverA)
        let intentionalPathA = try XCTUnwrap(pathA)

        await cacheActor.deleteDownload(songId: song.id, serverId: serverA)
        try await waitForManifestRevision(progress, serverId: serverA, atLeast: revisionA + 1)

        let remainingA = await cacheActor.isDownloaded(songId: song.id, serverId: serverA)
        let remainingB = await cacheActor.isDownloaded(songId: song.id, serverId: serverB)
        XCTAssertFalse(remainingA)
        XCTAssertTrue(remainingB, "The same song ID on another server must remain downloaded")
        XCTAssertEqual(progress.manifestRevisions[serverA], revisionA + 1)
        XCTAssertEqual(progress.manifestRevisions[serverB], revisionB)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentionalPathA.path))
        let playbackA = try XCTUnwrap(playbackPaths[serverA])
        XCTAssertTrue(FileManager.default.fileExists(atPath: playbackA.path),
                      "Deleting an intentional download must preserve incidental playback cache")
    }

    @MainActor
    private func waitForManifestRevision(
        _ progress: DownloadProgressState,
        serverId: UUID,
        atLeast revision: UInt64
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if (progress.manifestRevisions[serverId] ?? 0) >= revision { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for server-scoped manifest revision \(revision)")
        throw NSError(domain: "CacheActorTests.ManifestRevisionTimeout", code: 1)
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
