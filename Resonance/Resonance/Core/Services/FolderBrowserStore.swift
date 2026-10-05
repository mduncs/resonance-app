import Foundation

/// Per-folder-view state that is deliberately independent of network paging.
/// Subsonic directories arrive as complete child lists, so the window is a UI
/// convenience only; actions always traverse the complete directory tree.
@MainActor
final class FolderBrowserStore {
    struct CacheKey: Hashable {
        let serverID: String?
        let directoryID: String
    }

    private let capacity: Int
    private var cache: [CacheKey: MusicDirectory] = [:]
    private var recency: [CacheKey] = []

    init(capacity: Int = 32) {
        self.capacity = max(1, capacity)
    }

    func cachedDirectory(serverID: String?, id: String) -> MusicDirectory? {
        let key = CacheKey(serverID: serverID, directoryID: id)
        guard let directory = cache[key] else { return nil }
        touch(key)
        return directory
    }

    func cache(_ directory: MusicDirectory, serverID: String?, under requestedID: String? = nil) {
        let key = CacheKey(serverID: serverID, directoryID: requestedID ?? directory.id)
        cache[key] = directory
        touch(key)
        while recency.count > capacity {
            cache.removeValue(forKey: recency.removeFirst())
        }
    }

    func remove(serverID: String?, id: String) {
        let key = CacheKey(serverID: serverID, directoryID: id)
        cache.removeValue(forKey: key)
        recency.removeAll { $0 == key }
    }

    func clear() {
        cache.removeAll()
        recency.removeAll()
    }

    private func touch(_ key: CacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

/// Keeps an async folder action's busy state tied to the active request.  A
/// cancelled or superseded request can never clear a newer request's spinner.
struct FolderBrowserActionLifecycle: Sendable {
    private(set) var generation = 0
    private(set) var isBusy = false

    mutating func begin() -> Int {
        generation &+= 1
        isBusy = true
        return generation
    }

    mutating func cancel() {
        generation &+= 1
        isBusy = false
    }

    mutating func finish(_ requestGeneration: Int) {
        guard requestGeneration == generation else { return }
        isBusy = false
    }

    func isCurrent(_ requestGeneration: Int) -> Bool {
        requestGeneration == generation
    }
}

/// A stable, already-sorted view of one server directory.  Construct this when
/// its inputs change instead of re-sorting from `View.body` for each render.
struct FolderBrowserProjection: Sendable {
    let folders: [MusicFolder]
    let songs: [Song]

    static let empty = FolderBrowserProjection(folders: [], songs: [])

    private init(folders: [MusicFolder], songs: [Song]) {
        self.folders = folders
        self.songs = songs
    }

    init(directory: MusicDirectory?, query: String, hiddenSongIDs: Set<String>) {
        guard let directory else {
            folders = []
            songs = []
            return
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        folders = directory.children.compactMap { child in
            guard case .folder(let folder) = child,
                  Self.matches(folder.name, query: trimmedQuery) else { return nil }
            return folder
        }
        .sorted(by: Self.stableFolderOrder)

        songs = directory.children.compactMap { child in
            guard case .song(let song) = child,
                  !hiddenSongIDs.contains(song.id),
                  Self.matches(song, query: trimmedQuery) else { return nil }
            return song
        }
        .sorted(by: Self.stableSongOrder)
    }

    var count: Int { folders.count + songs.count }

    func displayed(limit: Int) -> FolderBrowserDisplayWindow {
        FolderBrowserDisplayWindow(projection: self, limit: limit)
    }

    private static func matches(_ name: String, query: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }

    private static func matches(_ song: Song, query: String) -> Bool {
        query.isEmpty
            || song.title.localizedCaseInsensitiveContains(query)
            || song.artist.localizedCaseInsensitiveContains(query)
            || song.album.localizedCaseInsensitiveContains(query)
    }

    private static func stableFolderOrder(_ lhs: MusicFolder, _ rhs: MusicFolder) -> Bool {
        stableNameOrder(lhs.name, lhs.id, rhs.name, rhs.id)
    }

    private static func stableSongOrder(_ lhs: Song, _ rhs: Song) -> Bool {
        stableNameOrder(lhs.title, lhs.id, rhs.title, rhs.id)
    }

    private static func stableNameOrder(_ lhsName: String, _ lhsID: String, _ rhsName: String, _ rhsID: String) -> Bool {
        let comparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
        return comparison == .orderedSame ? lhsID < rhsID : comparison == .orderedAscending
    }
}

/// The currently materialized UI window.  It is rebuilt only when the limit or
/// projection changes, so rows and dividers do not repeatedly slice arrays.
struct FolderBrowserDisplayWindow: Sendable {
    let folders: [MusicFolder]
    let songs: [Song]

    static let empty = FolderBrowserDisplayWindow(folders: [], songs: [])

    private init(folders: [MusicFolder], songs: [Song]) {
        self.folders = folders
        self.songs = songs
    }

    init(projection: FolderBrowserProjection, limit: Int) {
        folders = Array(projection.folders.prefix(limit))
        songs = Array(projection.songs.prefix(max(0, limit - folders.count)))
    }
}
