import AppKit
import CryptoKit
import Foundation

// MARK: - Download Progress

/// Observable download progress state - updated from CacheActor
@MainActor
@Observable
final class DownloadProgressState: @unchecked Sendable {
    /// Active downloads: songId -> progress (0.0-1.0)
    var activeDownloads: [String: Double] = [:]

    /// Song titles for display: songId -> title
    var songTitles: [String: String] = [:]

    /// Completed downloads for UI refresh (cleared periodically)
    var recentlyCompleted: Set<String> = []

    /// Failed downloads with error message
    var failedDownloads: [String: String] = [:]

    /// Total bytes being downloaded
    var totalBytesDownloading: Int64 = 0

    /// Bytes downloaded so far
    var bytesDownloaded: Int64 = 0

    var isDownloading: Bool {
        !activeDownloads.isEmpty
    }

    var overallProgress: Double {
        guard totalBytesDownloading > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytesDownloading)
    }

    func setProgress(_ progress: Double, for songId: String, title: String? = nil) {
        activeDownloads[songId] = progress
        if let title = title {
            songTitles[songId] = title
        }
    }

    func markCompleted(_ songId: String) {
        activeDownloads.removeValue(forKey: songId)
        recentlyCompleted.insert(songId)
        failedDownloads.removeValue(forKey: songId)
        songTitles.removeValue(forKey: songId)
    }

    func markFailed(_ songId: String, error: String) {
        activeDownloads.removeValue(forKey: songId)
        failedDownloads[songId] = error
        songTitles.removeValue(forKey: songId)
    }

    func clearCompleted() {
        recentlyCompleted.removeAll()
    }

    /// Get display title for a song (falls back to songId if not available)
    func displayTitle(for songId: String) -> String {
        songTitles[songId] ?? songId
    }

    nonisolated init() {}
}

// MARK: - Download Item (for queue)

struct PendingDownload: Sendable {
    let songId: String
    let song: Song?
    let serverId: UUID
    let priority: Int  // Higher = more urgent
}

private struct DownloadRecord: Codable, Sendable {
    let song: Song
    let suffix: String
    let fileName: String
    let downloadedAt: Date
}

actor CacheActor {
    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let downloadsDirectory: URL
    private var accessTimes: [String: Date] = [:]
    private var responseExpiry: [String: Date] = [:]  // path -> expiry timestamp
    private let responseTTL: TimeInterval = 300  // 5 minutes
    private var downloadManifestCache: [UUID: [String: DownloadRecord]] = [:]

    // In-memory image cache (LRU via NSCache)
    // NSCache is thread-safe and auto-evicts under memory pressure
    private let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 100  // Max 100 images
        cache.totalCostLimit = 50 * 1024 * 1024  // ~50MB (cost = image byte size estimate)
        return cache
    }()

    // Default limits
    private var maxArtworkCacheSize: Int64 = 500 * 1024 * 1024  // 500 MB
    private var maxAudioCacheSize: Int64 = 10 * 1024 * 1024 * 1024  // 10 GB
    private var maxResponseCacheSize: Int64 = 50 * 1024 * 1024  // 50 MB

    // Download queue
    private var downloadQueue: [PendingDownload] = []
    private var isProcessingQueue = false
    private var currentPendingDownload: Task<Void, Never>?

    // Download state (shared with UI)
    private let progressState: DownloadProgressState

    // Callbacks for download operations
    private var downloadDataHandler: (@Sendable (String, UUID) async throws -> (Data, String))?

    init(
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil,
        downloadsDirectory: URL? = nil
    ) {
        self.fileManager = fileManager

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = cacheDirectory ?? caches.appendingPathComponent(
            PublicDemoConfiguration.appSupportDirectoryName,
            isDirectory: true
        )

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.downloadsDirectory = downloadsDirectory
            ?? appSupport
            .appendingPathComponent(PublicDemoConfiguration.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)

        // Initialize progress state on main actor
        self.progressState = DownloadProgressState()

        // Create directory structure synchronously since init is nonisolated
        try? fileManager.createDirectory(
            at: self.cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.createDirectory(
            at: self.downloadsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let subdirectories = ["artwork", "audio", "responses", "metadata"]
        for subdir in subdirectories {
            let path = self.cacheDirectory.appendingPathComponent(subdir, isDirectory: true)
            try? fileManager.createDirectory(at: path, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }
    }

    /// Get the shared progress state for UI observation
    nonisolated var downloadProgress: DownloadProgressState {
        progressState
    }

    /// Set the download handler (called by AppState to inject network capability)
    func setDownloadHandler(_ handler: @escaping @Sendable (String, UUID) async throws -> (Data, String)) {
        self.downloadDataHandler = handler
    }

    private func createDirectoryStructure() {
        try? fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let subdirectories = ["artwork", "audio", "responses", "metadata"]

        for subdir in subdirectories {
            let path = cacheDirectory.appendingPathComponent(subdir, isDirectory: true)
            try? fileManager.createDirectory(at: path, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }
    }

    // MARK: - Artwork Cache

    func cacheArtwork(_ data: Data, for id: String, size: ArtworkSize) async throws {
        let filename = "\(id)_\(size.suffix).webp"
        let path = cacheDirectory.appendingPathComponent("artwork").appendingPathComponent(filename)

        try data.write(to: path, options: .atomic)
        accessTimes[path.path] = Date()

        await evictArtworkIfNeeded()
    }

    func getArtwork(for id: String, size: ArtworkSize) async -> Data? {
        let filename = "\(id)_\(size.suffix).webp"
        let path = cacheDirectory.appendingPathComponent("artwork").appendingPathComponent(filename)

        guard fileManager.fileExists(atPath: path.path) else { return nil }

        accessTimes[path.path] = Date()
        return try? Data(contentsOf: path)
    }

    func artworkExists(for id: String, size: ArtworkSize) -> Bool {
        let filename = "\(id)_\(size.suffix).webp"
        let path = cacheDirectory.appendingPathComponent("artwork").appendingPathComponent(filename)
        return fileManager.fileExists(atPath: path.path)
    }

    /// Get artwork as NSImage with in-memory caching (prevents scroll jank)
    /// Returns immediately from memory if available, otherwise loads from disk and caches
    func getArtworkImage(for id: String, size: ArtworkSize) async -> NSImage? {
        let cacheKey = "\(id)_\(size.suffix)" as NSString

        // Fast path: check memory cache first
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        // Slow path: load from disk
        guard let data = await getArtwork(for: id, size: size),
              let image = NSImage(data: data) else {
            return nil
        }

        // Estimate memory cost (width * height * 4 bytes per pixel)
        let cost = Int(image.size.width * image.size.height * 4)
        imageCache.setObject(image, forKey: cacheKey, cost: cost)

        return image
    }

    /// Cache artwork and also add to memory cache for immediate access
    func cacheArtworkWithImage(_ data: Data, for id: String, size: ArtworkSize) async throws {
        try await cacheArtwork(data, for: id, size: size)

        // Also populate memory cache if image is valid
        if let image = NSImage(data: data) {
            let cacheKey = "\(id)_\(size.suffix)" as NSString
            let cost = Int(image.size.width * image.size.height * 4)
            imageCache.setObject(image, forKey: cacheKey, cost: cost)
        }
    }

    /// Clear the in-memory image cache (called on memory warning or explicit clear)
    func clearImageCache() {
        imageCache.removeAllObjects()
    }

    // MARK: - Audio Cache

    func cacheAudio(_ data: Data, for songId: String, serverId: UUID, suffix: String) async throws -> URL {
        let serverDir = playbackCacheDirectory(for: serverId)
        createDirectoryIfNeeded(serverDir)

        let filename = "\(songId).\(normalizedSuffix(suffix))"
        let path = serverDir.appendingPathComponent(filename)

        try data.write(to: path, options: .atomic)
        accessTimes[path.path] = Date()

        await evictAudioIfNeeded()

        return path
    }

    func getAudioPath(for songId: String, serverId: UUID, suffix: String) -> URL? {
        if let downloadedPath = getDownloadedAudioPath(for: songId, serverId: serverId, preferredSuffix: suffix) {
            return downloadedPath
        }

        return getPlaybackCachedAudioPath(for: songId, serverId: serverId, preferredSuffix: suffix)
    }

    func getDownloadedAudioPath(for songId: String, serverId: UUID, preferredSuffix: String? = nil) -> URL? {
        var manifest = sanitizedDownloadManifest(for: serverId)
        if let record = manifest[songId] {
            let path = intentionalDownloadPath(for: record, serverId: serverId)
            guard fileManager.fileExists(atPath: path.path) else {
                manifest.removeValue(forKey: songId)
                saveDownloadManifest(manifest, serverId: serverId)
                return nil
            }
            return path
        }

        guard let recoveredPath = findAudioFile(
            songId: songId,
            preferredSuffix: preferredSuffix,
            directory: intentionalDownloadsDirectory(for: serverId)
        ) else {
            return nil
        }

        return recoveredPath
    }

    private func getPlaybackCachedAudioPath(for songId: String, serverId: UUID, preferredSuffix: String?) -> URL? {
        let directory = playbackCacheDirectory(for: serverId)
        guard let path = findAudioFile(songId: songId, preferredSuffix: preferredSuffix, directory: directory) else {
            return nil
        }

        accessTimes[path.path] = Date()
        return path
    }

    func audioExists(for songId: String, serverId: UUID, suffix: String) -> Bool {
        getAudioPath(for: songId, serverId: serverId, suffix: suffix) != nil
    }

    private func enumerateCachedAudio(serverId: UUID) -> [(songId: String, suffix: String, size: Int64, path: URL)] {
        enumerateAudioFiles(in: playbackCacheDirectory(for: serverId))
    }

    func enumerateDownloadedSongs(serverId: UUID) -> [DownloadedSong] {
        sanitizedDownloadManifest(for: serverId)
            .values
            .sorted { lhs, rhs in
                lhs.song.title.localizedCaseInsensitiveCompare(rhs.song.title) == .orderedAscending
            }
            .compactMap { record in
                let path = intentionalDownloadPath(for: record, serverId: serverId)
                guard fileManager.fileExists(atPath: path.path) else { return nil }

                let size = (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                return DownloadedSong(
                    songId: record.song.id,
                    song: record.song,
                    suffix: record.suffix,
                    fileSize: size,
                    filePath: path
                )
            }
    }

    func removeAudio(at path: URL) {
        try? fileManager.removeItem(at: path)
        accessTimes.removeValue(forKey: path.path)
    }

    // MARK: - Download Queue Management

    /// Queue a song for download
    func queueDownload(song: Song, serverId: UUID, priority: Int = 0) {
        if isDownloaded(songId: song.id, serverId: serverId) {
            return
        }

        if promotePlaybackCacheToDownload(song: song, serverId: serverId) {
            Task { @MainActor in
                progressState.markCompleted(song.id)
            }
            return
        }

        if downloadQueue.contains(where: { $0.songId == song.id && $0.serverId == serverId }) {
            return
        }

        let task = PendingDownload(songId: song.id, song: song, serverId: serverId, priority: priority)
        downloadQueue.append(task)
        downloadQueue.sort { $0.priority > $1.priority }

        processQueue()
    }

    /// Queue multiple songs (e.g., for album download)
    func queueDownloads(songs: [Song], serverId: UUID, priority: Int = 0) {
        for song in songs {
            queueDownload(song: song, serverId: serverId, priority: priority)
        }
    }

    /// Check if a song is intentionally downloaded for offline playback
    func isDownloaded(songId: String, serverId: UUID) -> Bool {
        getDownloadedAudioPath(for: songId, serverId: serverId) != nil
    }

    /// Delete a downloaded song without touching incidental playback cache
    func deleteDownload(songId: String, serverId: UUID) {
        var manifest = loadDownloadManifest(for: serverId)
        if let record = manifest.removeValue(forKey: songId) {
            let path = intentionalDownloadPath(for: record, serverId: serverId)
            try? fileManager.removeItem(at: path)
        }
        saveDownloadManifest(manifest, serverId: serverId)
        removeLegacySongMetadata(songId: songId, serverId: serverId)
    }

    /// Cancel a pending download
    func cancelDownload(songId: String) {
        downloadQueue.removeAll { $0.songId == songId }
        Task { @MainActor in
            progressState.activeDownloads.removeValue(forKey: songId)
        }
    }

    /// Cancel all pending downloads
    func cancelAllDownloads() {
        downloadQueue.removeAll()
        currentPendingDownload?.cancel()
        currentPendingDownload = nil
        isProcessingQueue = false
        Task { @MainActor in
            progressState.activeDownloads.removeAll()
        }
    }

    /// Get pending download count
    var pendingDownloadCount: Int {
        downloadQueue.count
    }

    /// Process the download queue
    private func processQueue() {
        guard !isProcessingQueue else { return }
        guard let handler = downloadDataHandler else { return }
        guard !downloadQueue.isEmpty else { return }

        isProcessingQueue = true

        currentPendingDownload = Task {
            while !downloadQueue.isEmpty {
                let task = downloadQueue.removeFirst()

                // Update UI to show download starting (with title if available)
                await MainActor.run {
                    progressState.setProgress(0.0, for: task.songId, title: task.song?.title)
                }

                do {
                    let (data, returnedSuffix) = try await handler(task.songId, task.serverId)
                    let song = task.song ?? loadSongMetadata(songId: task.songId, serverId: task.serverId)
                    guard let song else {
                        throw ResonanceError.cacheCorrupted(path: task.songId)
                    }

                    await MainActor.run {
                        progressState.setProgress(0.9, for: task.songId)
                    }

                    _ = try storeDownload(
                        data,
                        song: song,
                        serverId: task.serverId,
                        fallbackSuffix: returnedSuffix
                    )

                    await MainActor.run {
                        progressState.markCompleted(task.songId)
                    }

                } catch {
                    await MainActor.run {
                        progressState.markFailed(task.songId, error: error.localizedDescription)
                    }
                }

                try? await Task.sleep(for: .milliseconds(100))
            }

            isProcessingQueue = false
        }
    }

    // MARK: - Download Storage

    /// Load song metadata from the legacy cache-based download system.
    private func loadSongMetadata(songId: String, serverId: UUID) -> Song? {
        let path = legacyMetadataDirectory(for: serverId)
            .appendingPathComponent("\(songId).json")

        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(Song.self, from: data)
    }

    private func storeDownload(
        _ data: Data,
        song: Song,
        serverId: UUID,
        fallbackSuffix: String
    ) throws -> URL {
        let serverDir = intentionalDownloadsDirectory(for: serverId)
        createDirectoryIfNeeded(serverDir)

        let suffix = normalizedSuffix(song.suffix.isEmpty ? fallbackSuffix : song.suffix)
        let filename = "\(song.id).\(suffix)"
        let destination = serverDir.appendingPathComponent(filename)

        try data.write(to: destination, options: .atomic)
        saveDownloadRecord(
            DownloadRecord(song: song, suffix: suffix, fileName: filename, downloadedAt: Date()),
            serverId: serverId
        )
        removeLegacySongMetadata(songId: song.id, serverId: serverId)

        return destination
    }

    private func promotePlaybackCacheToDownload(song: Song, serverId: UUID) -> Bool {
        guard let cachedPath = getPlaybackCachedAudioPath(
            for: song.id,
            serverId: serverId,
            preferredSuffix: song.suffix
        ) else {
            return false
        }

        do {
            let suffix = normalizedSuffix(cachedPath.pathExtension.isEmpty ? song.suffix : cachedPath.pathExtension)
            let serverDir = intentionalDownloadsDirectory(for: serverId)
            createDirectoryIfNeeded(serverDir)

            let filename = "\(song.id).\(suffix)"
            let destination = serverDir.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: cachedPath, to: destination)

            saveDownloadRecord(
                DownloadRecord(song: song, suffix: suffix, fileName: filename, downloadedAt: Date()),
                serverId: serverId
            )
            removeLegacySongMetadata(songId: song.id, serverId: serverId)
            return true
        } catch {
            return false
        }
    }

    private func saveDownloadRecord(_ record: DownloadRecord, serverId: UUID) {
        var manifest = loadDownloadManifest(for: serverId)
        if let existing = manifest[record.song.id] {
            let existingPath = intentionalDownloadPath(for: existing, serverId: serverId)
            let replacementPath = intentionalDownloadPath(for: record, serverId: serverId)
            if existingPath != replacementPath {
                try? fileManager.removeItem(at: existingPath)
            }
        }

        manifest[record.song.id] = record
        saveDownloadManifest(manifest, serverId: serverId)
    }

    private func loadDownloadManifest(for serverId: UUID) -> [String: DownloadRecord] {
        if let cached = downloadManifestCache[serverId] {
            return cached
        }

        createDirectoryIfNeeded(intentionalDownloadsDirectory(for: serverId))
        let manifestURL = downloadManifestURL(for: serverId)

        let manifest: [String: DownloadRecord]
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode([String: DownloadRecord].self, from: data) {
            manifest = decoded
        } else {
            manifest = migrateLegacyDownloads(for: serverId)
            saveDownloadManifest(manifest, serverId: serverId)
        }

        downloadManifestCache[serverId] = manifest
        return manifest
    }

    private func saveDownloadManifest(_ manifest: [String: DownloadRecord], serverId: UUID) {
        createDirectoryIfNeeded(intentionalDownloadsDirectory(for: serverId))
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: downloadManifestURL(for: serverId), options: .atomic)
        }
        downloadManifestCache[serverId] = manifest
    }

    private func sanitizedDownloadManifest(for serverId: UUID) -> [String: DownloadRecord] {
        var manifest = loadDownloadManifest(for: serverId)
        var didChange = false

        for (songId, record) in manifest {
            let path = intentionalDownloadPath(for: record, serverId: serverId)
            if !fileManager.fileExists(atPath: path.path) {
                manifest.removeValue(forKey: songId)
                didChange = true
            }
        }

        if didChange {
            saveDownloadManifest(manifest, serverId: serverId)
        }

        return manifest
    }

    private func migrateLegacyDownloads(for serverId: UUID) -> [String: DownloadRecord] {
        let metadataDir = legacyMetadataDirectory(for: serverId)
        guard let metadataFiles = try? fileManager.contentsOfDirectory(
            at: metadataDir,
            includingPropertiesForKeys: nil
        ) else {
            return [:]
        }

        createDirectoryIfNeeded(intentionalDownloadsDirectory(for: serverId))

        var manifest: [String: DownloadRecord] = [:]
        for metadataURL in metadataFiles where metadataURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: metadataURL),
                  let song = try? JSONDecoder().decode(Song.self, from: data),
                  let legacyAudio = findAudioFile(
                    songId: song.id,
                    preferredSuffix: song.suffix,
                    directory: playbackCacheDirectory(for: serverId)
                  ) else {
                continue
            }

            let suffix = normalizedSuffix(legacyAudio.pathExtension.isEmpty ? song.suffix : legacyAudio.pathExtension)
            let filename = "\(song.id).\(suffix)"
            let destination = intentionalDownloadsDirectory(for: serverId).appendingPathComponent(filename)

            if legacyAudio.path != destination.path {
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                try? fileManager.moveItem(at: legacyAudio, to: destination)
            }

            let downloadedAt = (try? destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date()
            manifest[song.id] = DownloadRecord(
                song: song,
                suffix: suffix,
                fileName: filename,
                downloadedAt: downloadedAt
            )
        }

        return manifest
    }

    private func intentionalDownloadPath(for record: DownloadRecord, serverId: UUID) -> URL {
        intentionalDownloadsDirectory(for: serverId).appendingPathComponent(record.fileName)
    }

    private func playbackCacheDirectory(for serverId: UUID) -> URL {
        cacheDirectory.appendingPathComponent("audio").appendingPathComponent(serverId.uuidString)
    }

    private func intentionalDownloadsDirectory(for serverId: UUID) -> URL {
        downloadsDirectory.appendingPathComponent(serverId.uuidString)
    }

    private func downloadManifestURL(for serverId: UUID) -> URL {
        intentionalDownloadsDirectory(for: serverId).appendingPathComponent("manifest.json")
    }

    private func legacyMetadataDirectory(for serverId: UUID) -> URL {
        cacheDirectory.appendingPathComponent("metadata").appendingPathComponent(serverId.uuidString)
    }

    private func removeLegacySongMetadata(songId: String, serverId: UUID) {
        let metadataPath = legacyMetadataDirectory(for: serverId).appendingPathComponent("\(songId).json")
        try? fileManager.removeItem(at: metadataPath)
    }

    private func createDirectoryIfNeeded(_ url: URL) {
        try? fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func normalizedSuffix(_ suffix: String) -> String {
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            return String(trimmed.dropFirst()).lowercased()
        }
        return trimmed.lowercased()
    }

    private func enumerateAudioFiles(in directory: URL) -> [(songId: String, suffix: String, size: Int64, path: URL)] {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }

        var results: [(songId: String, suffix: String, size: Int64, path: URL)] = []

        while let url = enumerator.nextObject() as? URL {
            let filename = url.deletingPathExtension().lastPathComponent
            let suffix = normalizedSuffix(url.pathExtension)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0

            results.append((songId: filename, suffix: suffix, size: size, path: url))
        }

        return results
    }

    private func findAudioFile(songId: String, preferredSuffix: String?, directory: URL) -> URL? {
        let normalizedPreferredSuffix = preferredSuffix.map(normalizedSuffix)
        let files = enumerateAudioFiles(in: directory)
            .filter { $0.songId == songId }

        if let normalizedPreferredSuffix,
           let preferred = files.first(where: { $0.suffix == normalizedPreferredSuffix }) {
            return preferred.path
        }

        return files.first?.path
    }

    // MARK: - Response Cache

    /// Filename for a cached response, derived from the endpoint key.
    ///
    /// This MUST be a real hash, not a truncated encoding of the key. The
    /// previous implementation base64-encoded the key and took `.prefix(50)`,
    /// which silently collided any two keys sharing a 36-byte prefix — because
    /// base64 maps each 3 input bytes to 4 output characters, a shared plaintext
    /// prefix produces an identical encoded prefix.
    ///
    /// That is exactly the shape of the paginated library keys:
    ///
    ///     getAlbumList2:alphabeticalByName:500:0:all
    ///     getAlbumList2:alphabeticalByName:500:500:all
    ///     getAlbumList2:alphabeticalByName:500:1000:all
    ///
    /// The common prefix is 36 bytes → 48 base64 characters, so the *offset*,
    /// the only part that distinguishes the pages, started at character 49 and
    /// was cut off. Every page of the album walk read back page one, so the
    /// library appeared to end after the first page and a 28,072-album library
    /// cached as 618 albums.
    ///
    /// SHA-256 hex is fixed-length (64 chars, well under any filename limit)
    /// and collision-resistant, so no key can mask another.
    nonisolated static func responseCacheFilename(for endpoint: String) -> String {
        let digest = SHA256.hash(data: Data(endpoint.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func responseCacheFilename(for endpoint: String) -> String {
        Self.responseCacheFilename(for: endpoint)
    }

    func cacheResponse(_ data: Data, for endpoint: String, serverId: UUID) async throws {
        let serverDir = cacheDirectory.appendingPathComponent("responses").appendingPathComponent(serverId.uuidString)
        try? fileManager.createDirectory(at: serverDir, withIntermediateDirectories: true)

        let path = serverDir.appendingPathComponent(responseCacheFilename(for: endpoint))

        try data.write(to: path, options: .atomic)
        let now = Date()
        accessTimes[path.path] = now
        responseExpiry[path.path] = now.addingTimeInterval(responseTTL)

        await evictResponsesIfNeeded()
    }

    func getResponse(for endpoint: String, serverId: UUID) async -> Data? {
        let path = cacheDirectory
            .appendingPathComponent("responses")
            .appendingPathComponent(serverId.uuidString)
            .appendingPathComponent(responseCacheFilename(for: endpoint))

        let now = Date()

        // Check in-memory expiry first (fast path)
        if let expiry = responseExpiry[path.path] {
            if now >= expiry {
                // Expired - clean up memory tracking
                responseExpiry.removeValue(forKey: path.path)
                accessTimes.removeValue(forKey: path.path)
                return nil
            }
            // Valid in memory - read file
            accessTimes[path.path] = now
            return try? Data(contentsOf: path)
        }

        // Not in memory cache - check filesystem (cold start case)
        guard fileManager.fileExists(atPath: path.path) else { return nil }

        // Fall back to filesystem TTL check for entries cached before restart
        if let attrs = try? fileManager.attributesOfItem(atPath: path.path),
           let modDate = attrs[.modificationDate] as? Date {
            let age = now.timeIntervalSince(modDate)
            if age > responseTTL {
                return nil
            }
            // Valid - populate memory cache for next lookup
            let remainingTTL = responseTTL - age
            responseExpiry[path.path] = now.addingTimeInterval(remainingTTL)
            accessTimes[path.path] = now
            return try? Data(contentsOf: path)
        }

        return nil
    }

    // MARK: - Eviction

    private func evictArtworkIfNeeded() async {
        await evictFromDirectory(
            cacheDirectory.appendingPathComponent("artwork"),
            maxSize: maxArtworkCacheSize
        )
    }

    private func evictAudioIfNeeded() async {
        await evictFromDirectory(
            cacheDirectory.appendingPathComponent("audio"),
            maxSize: maxAudioCacheSize
        )
    }

    private func evictResponsesIfNeeded() async {
        await evictFromDirectory(
            cacheDirectory.appendingPathComponent("responses"),
            maxSize: maxResponseCacheSize
        )
    }

    private func evictFromDirectory(_ directory: URL, maxSize: Int64) async {
        guard let currentSize = directorySize(directory), currentSize > maxSize else { return }

        let targetSize = Int64(Double(maxSize) * 0.8)

        // Get all files with access times
        var files: [(URL, Date)] = []
        if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let url = enumerator.nextObject() as? URL {
                let accessTime = accessTimes[url.path] ?? (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date.distantPast
                files.append((url, accessTime))
            }
        }

        // Sort by access time (oldest first)
        files.sort { $0.1 < $1.1 }

        // Delete until under target
        var freedSpace: Int64 = 0
        for (url, _) in files {
            guard currentSize - freedSpace > targetSize else { break }

            if let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64 {
                try? fileManager.removeItem(at: url)
                accessTimes.removeValue(forKey: url.path)
                freedSpace += size
            }
        }
    }

    private func directorySize(_ directory: URL) -> Int64? {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }

        var totalSize: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }

        return totalSize
    }

    // MARK: - Settings

    func setMaxArtworkCacheSize(_ size: Int64) {
        maxArtworkCacheSize = size
    }

    func setMaxAudioCacheSize(_ size: Int64) {
        maxAudioCacheSize = size
    }

    // MARK: - Lyrics Cache

    func cacheLyrics(_ lyrics: CachedLyrics, for songId: String) {
        let lyricsDir = cacheDirectory.appendingPathComponent("lyrics")
        try? fileManager.createDirectory(at: lyricsDir, withIntermediateDirectories: true)

        let path = lyricsDir.appendingPathComponent("\(songId).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(lyrics) {
            try? data.write(to: path, options: .atomic)
        }
    }

    func getLyrics(for songId: String) -> CachedLyrics? {
        let path = cacheDirectory.appendingPathComponent("lyrics")
            .appendingPathComponent("\(songId).json")

        guard let data = try? Data(contentsOf: path) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let cached = try? decoder.decode(CachedLyrics.self, from: data) else {
            return nil
        }

        // Re-fetch "not found" after 7 days
        if cached.source == .notFound {
            let age = Date().timeIntervalSince(cached.fetchedAt)
            if age > 7 * 24 * 60 * 60 {
                try? fileManager.removeItem(at: path)
                return nil
            }
        }

        return cached
    }

    // MARK: - Cleanup

    func clearAllCaches() async throws {
        try fileManager.removeItem(at: cacheDirectory)
        accessTimes = [:]
        responseExpiry = [:]
        imageCache.removeAllObjects()
        createDirectoryStructure()
    }

    func clearArtworkCache() async throws {
        let artworkDir = cacheDirectory.appendingPathComponent("artwork")
        try fileManager.removeItem(at: artworkDir)
        try fileManager.createDirectory(at: artworkDir, withIntermediateDirectories: true)

        accessTimes = accessTimes.filter { !$0.key.contains("/artwork/") }
        imageCache.removeAllObjects()
    }

    func clearAudioCache() async throws {
        let audioDir = cacheDirectory.appendingPathComponent("audio")
        try fileManager.removeItem(at: audioDir)
        try fileManager.createDirectory(at: audioDir, withIntermediateDirectories: true)

        accessTimes = accessTimes.filter { !$0.key.contains("/audio/") }
    }

    // MARK: - Stats

    /// Returns total size of all cached files in bytes
    func totalSize() async -> Int64 {
        let artworkSize = directorySize(cacheDirectory.appendingPathComponent("artwork")) ?? 0
        let audioSize = directorySize(cacheDirectory.appendingPathComponent("audio")) ?? 0
        let responseSize = directorySize(cacheDirectory.appendingPathComponent("responses")) ?? 0
        return artworkSize + audioSize + responseSize
    }

    /// Removes all cached artwork and audio files, recreates directory structure
    func clearAll() async {
        try? fileManager.removeItem(at: cacheDirectory)
        accessTimes = [:]
        responseExpiry = [:]
        imageCache.removeAllObjects()
        createDirectoryStructure()
    }

    func getCacheStats() async -> CacheStats {
        let artworkSize = directorySize(cacheDirectory.appendingPathComponent("artwork")) ?? 0
        let audioSize = directorySize(cacheDirectory.appendingPathComponent("audio")) ?? 0
        let responseSize = directorySize(cacheDirectory.appendingPathComponent("responses")) ?? 0
        let downloadSize = directorySize(downloadsDirectory) ?? 0
        let cacheSize = artworkSize + audioSize + responseSize

        return CacheStats(
            artworkSize: artworkSize,
            audioSize: audioSize,
            responseSize: responseSize,
            downloadSize: downloadSize,
            totalSize: cacheSize + downloadSize
        )
    }
}

// MARK: - Supporting Types

struct CacheStats: Sendable {
    let artworkSize: Int64
    let audioSize: Int64
    let responseSize: Int64
    let downloadSize: Int64
    let totalSize: Int64

    var formattedArtworkSize: String { formatBytes(artworkSize) }
    var formattedAudioSize: String { formatBytes(audioSize) }
    var formattedResponseSize: String { formatBytes(responseSize) }
    var formattedDownloadSize: String { formatBytes(downloadSize) }
    var formattedTotalSize: String { formatBytes(totalSize) }
    var cacheSize: Int64 { artworkSize + audioSize + responseSize }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Represents a downloaded song with metadata
struct DownloadedSong: Identifiable, Sendable {
    let songId: String
    let song: Song?
    let suffix: String
    let fileSize: Int64
    let filePath: URL

    var id: String { songId }

    var displayTitle: String {
        song?.title ?? songId
    }

    var displayArtist: String {
        song?.artist ?? "Unknown Artist"
    }

    var displayAlbum: String {
        song?.album ?? "Unknown Album"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var coverArtId: String? {
        song?.coverArt
    }
}
