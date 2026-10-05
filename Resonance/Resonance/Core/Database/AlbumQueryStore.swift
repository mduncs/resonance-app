import Foundation
import GRDB
import Observation

enum LibraryAlbumSort: String, CaseIterable, Sendable {
    case name = "Name"
    case artist = "Artist"
    case year = "Year"
    case recentlyAdded = "Recently Added"
}

struct LibraryAlbumQuery: Hashable, Sendable {
    let serverID: String
    var searchText = ""
    var minimumSongCount = 1
    var sort: LibraryAlbumSort = .name

    var normalizedSearchText: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct LibraryAlbumPage: Sendable {
    let albums: [Album]
    let totalCount: Int?
}

/// cached_albums.id is a primary key; EXISTS below avoids multiplying it by
/// duplicate membership facts. Title validity is the same global predicate as
/// AlbumSanitizer, applied before search, minimum-song filter and LIMIT.
private struct LibraryAlbumSQL {
    let query: LibraryAlbumQuery

    var predicate: String {
        """
        FROM cached_albums a
        WHERE a.server_id = ?
          AND EXISTS (
            SELECT 1 FROM library_membership lm
            WHERE lm.item_id = a.id AND lm.item_type = 'album'
              AND lm.server_id = a.server_id AND lm.removed_at IS NULL
          )
          AND NOT EXISTS (
            SELECT 1 FROM hidden_items h
            WHERE h.server_id = a.server_id AND h.item_type = 'album' AND h.item_id = a.id
          )
          AND resonanceAlbumTitleValid(a.name)
          AND a.song_count >= ?
          AND (
            ? = '' OR resonanceLocalizedStandardContains(a.name, ?)
            OR resonanceLocalizedStandardContains(a.artist_name, ?)
          )
        """
    }

    var arguments: StatementArguments {
        let text = query.normalizedSearchText
        return StatementArguments([
            query.serverID.databaseValue,
            (query.minimumSongCount > 1 ? query.minimumSongCount : Int.min).databaseValue,
            text.databaseValue, text.databaseValue, text.databaseValue
        ])
    }

    var orderBy: String {
        let localized = DatabaseCollation.localizedCaseInsensitiveCompare.name
        switch query.sort {
        case .name:
            return "ORDER BY a.name COLLATE \(localized) ASC, a.id COLLATE BINARY ASC"
        case .artist:
            return "ORDER BY a.artist_name COLLATE \(localized) ASC, a.name COLLATE \(localized) ASC, a.id COLLATE BINARY ASC"
        case .year:
            return "ORDER BY a.year IS NULL ASC, a.year DESC, a.name COLLATE \(localized) ASC, a.id COLLATE BINARY ASC"
        case .recentlyAdded:
            return "ORDER BY a.added_at IS NULL ASC, a.added_at DESC, a.id COLLATE BINARY ASC"
        }
    }
}

extension DatabaseManager {
    func admittedAlbums(ids: [String], serverID: String) throws -> [String: Album] {
        guard !ids.isEmpty else { return [:] }
        return try dbPool.read { db in
            let request = LibraryAlbumSQL(query: LibraryAlbumQuery(serverID: serverID))
            var arguments = request.arguments
            arguments += StatementArguments(ids.map(\.databaseValue))
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: "SELECT a.* \(request.predicate) AND a.id IN (\(placeholders))", arguments: arguments)
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let album = row.albumFromCachedColumns()
                return (album.id, album)
            })
        }
    }

    func libraryAlbumPage(matching query: LibraryAlbumQuery, offset: Int, limit: Int, includeCount: Bool) async throws -> LibraryAlbumPage {
        let offset = max(0, offset)
        let limit = max(1, limit)
        return try await dbPool.read { db in
            try Task.checkCancellation()
            let request = LibraryAlbumSQL(query: query)
            let count: Int?
            if includeCount {
                count = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(request.predicate)", arguments: request.arguments) ?? 0
            } else {
                count = nil
            }
            try Task.checkCancellation()
            var arguments = request.arguments
            arguments += [limit, offset]
            let rows = try Row.fetchAll(db, sql: "SELECT a.* \(request.predicate) \(request.orderBy) LIMIT ? OFFSET ?", arguments: arguments)
            try Task.checkCancellation()
            return LibraryAlbumPage(albums: rows.map { $0.albumFromCachedColumns() }, totalCount: count)
        }
    }

    /// Explicit full-query order for bulk actions, never inferred from a page.
    func libraryAlbumIDs(matching query: LibraryAlbumQuery) async throws -> [String] {
        try await dbPool.read { db in
            try Task.checkCancellation()
            let request = LibraryAlbumSQL(query: query)
            return try String.fetchAll(db, sql: "SELECT a.id \(request.predicate) \(request.orderBy)", arguments: request.arguments)
        }
    }

    /// Point lookup does not enumerate the album catalog or assume a page is complete.
    func cachedAlbum(id: String, serverID: String) async throws -> Album? {
        try await dbPool.read { db in
            try Task.checkCancellation()
            let request = LibraryAlbumSQL(query: LibraryAlbumQuery(serverID: serverID))
            var arguments = request.arguments
            arguments += [id]
            let row = try Row.fetchOne(db, sql: "SELECT a.* \(request.predicate) AND a.id = ?", arguments: arguments)
            return row.map { $0.albumFromCachedColumns() }
        }
    }

    /// Explicit complete catalog for Plane. Never used by Albums' paged UI or startup.
    func fullAlbumCatalog(serverID: String) async throws -> [Album] {
        try await dbPool.read { db in
            try Task.checkCancellation()
            let request = LibraryAlbumSQL(query: LibraryAlbumQuery(serverID: serverID))
            let rows = try Row.fetchAll(db, sql: "SELECT a.* \(request.predicate) \(request.orderBy)", arguments: request.arguments)
            try Task.checkCancellation()
            return rows.map { $0.albumFromCachedColumns() }
        }
    }
}

struct LibraryAlbumQueryClient: Sendable {
    var page: @Sendable (LibraryAlbumQuery, Int, Int, Bool) async throws -> LibraryAlbumPage

    init(database: DatabaseManager) {
        page = { try await database.libraryAlbumPage(matching: $0, offset: $1, limit: $2, includeCount: $3) }
    }

    init(page: @escaping @Sendable (LibraryAlbumQuery, Int, Int, Bool) async throws -> LibraryAlbumPage) {
        self.page = page
    }
}

@MainActor @Observable
final class LibraryAlbumQueryStore {
    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var albums: [Album] = []
    private(set) var totalCount = 0
    private(set) var state: LoadState = .idle
    private(set) var isLoadingMore = false
    private(set) var moreError: String?
    private(set) var consumedOffset = 0

    private let client: LibraryAlbumQueryClient
    private let pageSize: Int
    private var query: LibraryAlbumQuery?
    private var generation = UUID()
    private var activeTask: Task<LibraryAlbumPage, Error>?

    init(client: LibraryAlbumQueryClient, pageSize: Int = 250) {
        self.client = client
        self.pageSize = max(1, pageSize)
    }

    convenience init(database: DatabaseManager, pageSize: Int = 250) {
        self.init(client: LibraryAlbumQueryClient(database: database), pageSize: pageSize)
    }

    var hasMore: Bool { query != nil && consumedOffset < totalCount }

    func loadFirstPage(matching newQuery: LibraryAlbumQuery) async {
        activeTask?.cancel()
        generation = UUID()
        let token = generation
        query = newQuery
        albums = []
        totalCount = 0
        consumedOffset = 0
        state = .loading
        isLoadingMore = false
        moreError = nil
        do {
            let task = Task { try await client.page(newQuery, 0, pageSize, true) }
            activeTask = task
            let page = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard isCurrent(newQuery, token) else { return }
            activeTask = nil
            albums = page.albums
            consumedOffset = page.albums.count
            totalCount = max(page.totalCount ?? page.albums.count, consumedOffset)
            state = .loaded
        } catch is CancellationError {
            if isCurrent(newQuery, token) { activeTask = nil }
        } catch {
            guard isCurrent(newQuery, token) else { return }
            activeTask = nil
            state = .failed(error.localizedDescription)
        }
    }

    func loadNextPage() async {
        guard let query, hasMore, !isLoadingMore, state == .loaded else { return }
        let token = generation
        let offset = consumedOffset
        isLoadingMore = true
        moreError = nil
        defer { if isCurrent(query, token) { isLoadingMore = false } }
        do {
            let task = Task { try await client.page(query, offset, pageSize, false) }
            activeTask = task
            let page = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard isCurrent(query, token) else { return }
            activeTask = nil
            if page.albums.isEmpty { totalCount = consumedOffset; return }
            consumedOffset += page.albums.count
            totalCount = max(totalCount, consumedOffset)
            let existing = Set(albums.map(\.id))
            albums.append(contentsOf: page.albums.filter { !existing.contains($0.id) })
        } catch is CancellationError {
            if isCurrent(query, token) { activeTask = nil }
        } catch {
            guard isCurrent(query, token) else { return }
            activeTask = nil
            moreError = error.localizedDescription
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        generation = UUID()
        query = nil
        state = .idle
        isLoadingMore = false
        moreError = nil
    }

    func shouldLoadMore(afterVisibleAlbumID id: String) -> Bool {
        hasMore && !isLoadingMore && albums.suffix(30).contains { $0.id == id }
    }

    private func isCurrent(_ query: LibraryAlbumQuery, _ token: UUID) -> Bool {
        !Task.isCancelled && self.query == query && generation == token
    }
}

/// Coalesces only an explicit full-catalog request. Invalidation owns a
/// separate epoch from connection changes: a same-server refresh/hide must
/// reject an old result even when its underlying loader ignores cancellation.
@MainActor
final class FullAlbumCatalogLoader {
    private struct Pending {
        let serverID: String
        let token: UUID
        let task: Task<[Album], Error>
    }

    private(set) var generation: UInt64 = 0
    private(set) var loadedServerID: String?
    private var loadedAlbums: [Album] = []
    private var pending: Pending?

    func invalidate() {
        generation &+= 1
        pending?.task.cancel()
        pending = nil
        loadedServerID = nil
        loadedAlbums = []
    }

    func ensure(
        serverID: String,
        load: @escaping @Sendable () async throws -> [Album]
    ) async throws -> [Album] {
        if loadedServerID == serverID { return loadedAlbums }
        if let pending, pending.serverID != serverID { invalidate() }
        let epoch = generation
        let request: Pending
        if let pending {
            request = pending
        } else {
            request = Pending(serverID: serverID, token: UUID(), task: Task { try await load() })
            pending = request
        }

        // One cancelled view waiter must not cancel or clear a shared read.
        // Only an actual underlying failure, healthy publication, or explicit
        // invalidation may release the request's ownership.
        let albums: [Album]
        do {
            albums = try await request.task.value
        } catch {
            if !Task.isCancelled, generation == epoch, pending?.token == request.token {
                pending = nil
            }
            throw error
        }
        guard !Task.isCancelled, generation == epoch else { throw CancellationError() }
        if loadedServerID == serverID { return loadedAlbums }
        guard pending?.token == request.token else { throw CancellationError() }
        loadedAlbums = albums
        loadedServerID = serverID
        pending = nil
        return albums
    }
}

/// In-memory curation presentation while the next authoritative album fetch
/// is pending. Field-level revisions let a refresh clear its old overlays
/// without erasing a newer action made during that fetch.
struct AlbumPresentationStore: Sendable {
    private struct RatingAction: Sendable {
        let value: Int?
    }

    private struct Override: Sendable {
        var starredRevision: UInt64?
        var starred: Date?
        var lastAcknowledgedStarredAt: UInt64?
        var lastAcknowledgedStarred: Date?
        var ratingRevision: UInt64?
        var ratingConfirmedRevision: UInt64?
        var rating: Int?
        var pendingRatings: [UInt64: RatingAction] = [:]
        var lastAcknowledgedAction: UInt64?
        var lastAcknowledgedAt: UInt64?
        var lastAcknowledgedRating: Int?
    }

    private(set) var revision: UInt64 = 0
    private(set) var confirmedThrough: UInt64 = 0
    private var overrides: [String: Override] = [:]

    mutating func reset() {
        overrides = [:]
        confirmedThrough = 0
        revision &+= 1
    }

    mutating func setStarred(_ starred: Date?, for id: String) {
        revision &+= 1
        var override = overrides[id] ?? Override()
        override.starredRevision = revision
        override.starred = starred
        override.lastAcknowledgedStarredAt = revision
        override.lastAcknowledgedStarred = starred
        overrides[id] = override
    }

    @discardableResult
    mutating func setRating(_ rating: Int?, for id: String) -> UInt64 {
        revision &+= 1
        var override = overrides[id] ?? Override()
        override.ratingRevision = revision
        override.ratingConfirmedRevision = nil
        override.rating = rating
        override.pendingRatings[revision] = RatingAction(value: rating)
        overrides[id] = override
        return revision
    }

    mutating func confirmRating(for id: String, actionRevision: UInt64) {
        guard var override = overrides[id],
              let action = override.pendingRatings.removeValue(forKey: actionRevision) else { return }
        revision &+= 1
        if override.lastAcknowledgedAction.map({ actionRevision >= $0 }) ?? true {
            override.lastAcknowledgedAction = actionRevision
            override.lastAcknowledgedAt = revision
            override.lastAcknowledgedRating = action.value
        }
        if override.ratingRevision == actionRevision {
            override.ratingConfirmedRevision = revision
        }
        overrides[id] = override
    }

    @discardableResult
    mutating func rejectRating(for id: String, actionRevision: UInt64) -> Bool {
        guard var override = overrides[id],
              override.pendingRatings.removeValue(forKey: actionRevision) != nil else { return false }
        revision &+= 1
        let rejectedCurrentAction = override.ratingRevision == actionRevision
        if rejectedCurrentAction {
            // A later confirmed library snapshot may have superseded the old
            // acknowledgement; only restore it while that snapshot is absent.
            if let acknowledgedAt = override.lastAcknowledgedAt,
               acknowledgedAt > confirmedThrough {
                override.ratingRevision = override.lastAcknowledgedAction
                override.ratingConfirmedRevision = acknowledgedAt
                override.rating = override.lastAcknowledgedRating
            } else {
                override.ratingRevision = nil
                override.ratingConfirmedRevision = nil
                override.rating = nil
            }
        }
        if override.starredRevision == nil && override.ratingRevision == nil
            && override.pendingRatings.isEmpty && override.lastAcknowledgedAt == nil
            && override.lastAcknowledgedStarredAt == nil {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = override
        }
        return rejectedCurrentAction
    }

    func presented(_ album: Album) -> Album {
        guard let override = overrides[album.id] else { return album }
        var presented = album
        if override.starredRevision != nil { presented.starred = override.starred }
        if override.ratingRevision != nil { presented.rating = override.rating }
        return presented
    }

    /// Only server-acknowledged actions may advance an open detail's fallback.
    /// Pending presentation is deliberately excluded, so a failed action can
    /// return to the last confirmed value even when its point cache is stale.
    func acknowledged(_ album: Album, newerThan confirmedRevision: UInt64) -> Album {
        guard let override = overrides[album.id] else { return album }
        var result = album
        if let at = override.lastAcknowledgedStarredAt, at > confirmedRevision {
            result.starred = override.lastAcknowledgedStarred
        }
        if let at = override.lastAcknowledgedAt, at > confirmedRevision {
            result.rating = override.lastAcknowledgedRating
        }
        return result
    }

    mutating func reconcile(through confirmedRevision: UInt64) {
        confirmedThrough = max(confirmedThrough, confirmedRevision)
        var changed = false
        for id in Array(overrides.keys) {
            guard var override = overrides[id] else { continue }
            if let fieldRevision = override.starredRevision, fieldRevision <= confirmedRevision {
                override.starredRevision = nil
                override.starred = nil
                changed = true
            }
            if let acknowledged = override.ratingConfirmedRevision,
               acknowledged <= confirmedRevision {
                override.ratingRevision = nil
                override.ratingConfirmedRevision = nil
                override.rating = nil
                changed = true
            }
            if override.starredRevision == nil && override.ratingRevision == nil
                && override.pendingRatings.isEmpty && override.lastAcknowledgedAt == nil
                && override.lastAcknowledgedStarredAt == nil {
                overrides.removeValue(forKey: id)
            } else {
                overrides[id] = override
            }
        }
        if changed { revision &+= 1 }
    }
}

/// Detail-owned point metadata. `base` never contains an optimistic action.
/// A completed library refresh is applied only when its exact cache row arrives;
/// until then, the last acknowledged value remains visible without flicker.
struct AlbumDetailPresentationState {
    private(set) var base: Album
    private var pointConfirmedThrough: UInt64 = 0

    init(navigation: Album) { base = navigation }

    mutating func absorbAcknowledged(_ store: AlbumPresentationStore) {
        base = store.acknowledged(base, newerThan: pointConfirmedThrough)
    }

    mutating func updatePoint(_ refreshed: Album?, store: AlbumPresentationStore) {
        guard let refreshed else { return }
        pointConfirmedThrough = store.confirmedThrough
        base = store.acknowledged(refreshed, newerThan: pointConfirmedThrough)
    }

    func displayed(using store: AlbumPresentationStore) -> Album {
        store.presented(base)
    }
}
