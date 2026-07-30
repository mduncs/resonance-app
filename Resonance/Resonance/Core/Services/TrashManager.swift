import Foundation

/// Manages moving songs/albums to macOS system Trash with undo support.
/// Flow: confirm → move to Trash → show undo toast → if no undo, trigger rescan.
@MainActor
final class TrashManager {
    private let networkActor: NetworkActor
    private let databaseManager: DatabaseManager
    private var pendingUndo: PendingUndo?
    private var undoTimer: Task<Void, Never>?

    /// Callback to show undo toast in the UI
    var onUndoAvailable: ((UndoInfo) -> Void)?
    /// Callback to clear undo toast
    var onUndoDismissed: (() -> Void)?

    struct UndoInfo {
        let message: String
        let action: () -> Void
    }

    private struct PendingUndo {
        let trashedFiles: [(originalURL: URL, trashURL: URL)]
        let description: String
    }

    init(networkActor: NetworkActor, databaseManager: DatabaseManager) {
        self.networkActor = networkActor
        self.databaseManager = databaseManager
    }

    /// Delete a single song. Returns true if successful.
    func trashSong(_ song: Song) async throws {
        guard !PublicDemoConfiguration.isReadOnly else {
            throw TrashError.publicDemoReadOnly
        }
        let (path, libraryPath) = try await networkActor.fetchSongFilePath(id: song.id)
        let fullPath = resolveFullPath(path: path, libraryPath: libraryPath)

        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw TrashError.fileNotFound(fullPath)
        }

        let fileURL = URL(fileURLWithPath: fullPath)
        var trashURL: NSURL?
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashURL)

        guard let trashedAt = trashURL as URL? else {
            throw TrashError.trashFailed
        }

        setPendingUndo(
            files: [(originalURL: fileURL, trashURL: trashedAt)],
            description: "\"\(song.title)\" by \(song.artist)"
        )
    }

    /// Delete all songs in an album. Returns true if successful.
    func trashAlbum(_ album: Album, songs: [Song]) async throws {
        guard !PublicDemoConfiguration.isReadOnly else {
            throw TrashError.publicDemoReadOnly
        }
        var trashedFiles: [(originalURL: URL, trashURL: URL)] = []

        for song in songs {
            do {
                let (path, libraryPath) = try await networkActor.fetchSongFilePath(id: song.id)
                let fullPath = resolveFullPath(path: path, libraryPath: libraryPath)
                let fileURL = URL(fileURLWithPath: fullPath)

                guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

                var trashURL: NSURL?
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashURL)

                if let trashedAt = trashURL as URL? {
                    trashedFiles.append((originalURL: fileURL, trashURL: trashedAt))
                }
            } catch {
                // Continue with remaining songs even if one fails
                print("Failed to trash song \(song.title): \(error)")
            }
        }

        guard !trashedFiles.isEmpty else {
            throw TrashError.noFilesFound
        }

        // Try to remove empty album directory after trashing songs
        if let firstFile = trashedFiles.first {
            let albumDir = firstFile.originalURL.deletingLastPathComponent()
            let remaining = (try? FileManager.default.contentsOfDirectory(atPath: albumDir.path)) ?? []
            if remaining.isEmpty {
                try? FileManager.default.removeItem(at: albumDir)
            }
        }

        setPendingUndo(
            files: trashedFiles,
            description: "\"\(album.name)\" (\(trashedFiles.count) songs)"
        )
    }

    /// Undo the last trash operation — moves files back from Trash.
    func undo() {
        guard let pending = pendingUndo else { return }

        undoTimer?.cancel()
        undoTimer = nil

        for file in pending.trashedFiles {
            do {
                // Recreate parent directory if needed
                let parentDir = file.originalURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: file.trashURL, to: file.originalURL)
            } catch {
                print("Failed to restore \(file.originalURL.lastPathComponent): \(error)")
            }
        }

        pendingUndo = nil
        onUndoDismissed?()
    }

    // MARK: - Private

    private func resolveFullPath(path: String, libraryPath: String) -> String {
        if libraryPath.isEmpty {
            // path might already be absolute
            if path.hasPrefix("/") { return path }
            // Can't resolve without libraryPath — try common locations
            return path
        }
        // libraryPath is the base, path is relative within it
        return (libraryPath as NSString).appendingPathComponent(path)
    }

    private func setPendingUndo(files: [(originalURL: URL, trashURL: URL)], description: String) {
        // Cancel any existing undo timer
        undoTimer?.cancel()
        pendingUndo = PendingUndo(trashedFiles: files, description: description)

        onUndoAvailable?(UndoInfo(
            message: "Deleted \(description)",
            action: { [weak self] in self?.undo() }
        ))

        // After 10 seconds, commit the delete (trigger rescan)
        undoTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.commitDelete()
        }
    }

    private func commitDelete() {
        pendingUndo = nil
        onUndoDismissed?()

        // Trigger navidrome rescan so it notices the missing files
        Task {
            try? await networkActor.startScan()
        }
    }

    enum TrashError: LocalizedError {
        case fileNotFound(String)
        case trashFailed
        case noFilesFound
        case publicDemoReadOnly

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "File not found: \(path)"
            case .trashFailed: return "Failed to move file to Trash"
            case .noFilesFound: return "No files found to delete"
            case .publicDemoReadOnly: return "The Forty demo library is read-only"
            }
        }
    }
}
