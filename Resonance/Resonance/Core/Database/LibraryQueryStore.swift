import Foundation
import GRDB
import Observation

enum LibrarySongSort: String, CaseIterable, Sendable {
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    case duration = "Time"
    case plays = "Plays"
    case dateAdded = "Date Added"
    case releaseDate = "Release Date"
    case grouping = "Grouping"
}

struct LibrarySongQuery: Hashable, Sendable {
    let serverID: String
    var searchText: String = ""
    var sort: LibrarySongSort = .title
    var ascending = true

    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hasSameSelectionScope(as other: Self) -> Bool {
        serverID == other.serverID && normalizedSearchText == other.normalizedSearchText
    }
}

struct LibrarySongPage: Sendable, Equatable {
    let songs: [Song]
    let totalCount: Int?
}

private struct LibrarySongSQL {
    let query: LibrarySongQuery
    let restrictingIDs: Set<String>?

    var fromAndPredicate: String {
        var sql = """
            FROM cached_songs s
            INNER JOIN library_membership lm
                ON lm.item_id = s.id
                AND lm.item_type = 'song'
                AND lm.server_id = s.server_id
                AND lm.removed_at IS NULL
            LEFT JOIN cached_albums a
                ON a.id = s.album_id AND a.server_id = s.server_id
            WHERE s.server_id = ?
                AND NOT EXISTS (
                    SELECT 1 FROM hidden_items h
                    WHERE h.server_id = s.server_id
                        AND h.item_type = 'song' AND h.item_id = s.id
                )
                AND NOT EXISTS (
                    SELECT 1 FROM hidden_items h
                    WHERE h.server_id = s.server_id
                        AND h.item_type = 'album' AND h.item_id = s.album_id
                )
                AND NOT EXISTS (
                    SELECT 1 FROM hidden_items h
                    WHERE h.server_id = s.server_id
                        AND h.item_type = 'artist' AND h.item_id = s.artist_id
                )
                AND (
                    ? = ''
                    OR resonanceLocalizedStandardContains(s.title, ?)
                    OR resonanceLocalizedStandardContains(s.artist_name, ?)
                    OR resonanceLocalizedStandardContains(s.album_name, ?)
                    OR resonanceLocalizedStandardContains(COALESCE(s.genre, ''), ?)
                    OR resonanceLocalizedStandardContains(resonanceGroupingDisplay(s.groupings), ?)
                )
            """
        if restrictingIDs != nil {
            sql += " AND s.id IN (SELECT value FROM json_each(?))"
        }
        return sql
    }

    var arguments: StatementArguments {
        let text = query.normalizedSearchText
        var values: [DatabaseValue] = [
            query.serverID.databaseValue,
            text.databaseValue,
            text.databaseValue,
            text.databaseValue,
            text.databaseValue,
            text.databaseValue,
            text.databaseValue,
        ]
        if let restrictingIDs {
            let encoded = (try? JSONEncoder().encode(restrictingIDs.sorted())) ?? Data("[]".utf8)
            values.append((String(data: encoded, encoding: .utf8) ?? "[]").databaseValue)
        }
        return StatementArguments(values)
    }

    var orderBy: String {
        let direction = query.ascending ? "ASC" : "DESC"
        let localizedCI = DatabaseCollation.localizedCaseInsensitiveCompare.name
        let localizedStandard = DatabaseCollation.localizedStandardCompare.name
        let expression: String
        switch query.sort {
        case .title: expression = "s.title COLLATE \(localizedCI)"
        case .artist: expression = "s.artist_name COLLATE \(localizedCI)"
        case .album: expression = "s.album_name COLLATE \(localizedCI)"
        case .duration: expression = "s.duration"
        case .plays: expression = "s.server_play_count"
        case .dateAdded: expression = "s.server_added_at"
        case .releaseDate: expression = "COALESCE(s.release_date, a.release_date)"
        case .grouping: expression = "resonanceGroupingDisplay(s.groupings) COLLATE \(localizedStandard)"
        }
        return "ORDER BY \(expression) \(direction), s.id COLLATE BINARY ASC"
    }
}

extension DatabaseManager {
    func hasAdmittedLibrarySongs(serverID: String) async throws -> Bool {
        try await dbPool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM library_membership
                        WHERE server_id = ? AND item_type = 'song' AND removed_at IS NULL
                    )
                    """,
                arguments: [serverID]
            ) ?? false
        }
    }

    func librarySongPage(
        matching query: LibrarySongQuery,
        offset: Int,
        limit: Int,
        includeCount: Bool
    ) async throws -> LibrarySongPage {
        let offset = max(0, offset)
        let limit = max(1, limit)
        return try await dbPool.read { db in
            try Task.checkCancellation()
            let request = LibrarySongSQL(query: query, restrictingIDs: nil)
            let totalCount: Int?
            if includeCount {
                totalCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(DISTINCT s.id) \(request.fromAndPredicate)",
                    arguments: request.arguments
                ) ?? 0
            } else {
                totalCount = nil
            }
            try Task.checkCancellation()
            var arguments = request.arguments
            arguments += [limit, offset]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.*, COALESCE(s.release_date, a.release_date) AS resolved_release_date
                    \(request.fromAndPredicate)
                    \(request.orderBy)
                    LIMIT ? OFFSET ?
                    """,
                arguments: arguments
            )
            try Task.checkCancellation()
            return LibrarySongPage(
                songs: rows.map { $0.songFromCachedColumns(releaseDateColumn: "resolved_release_date") },
                totalCount: totalCount
            )
        }
    }

    func librarySongIDs(
        matching query: LibrarySongQuery,
        restrictedTo ids: Set<String>? = nil
    ) async throws -> [String] {
        guard ids?.isEmpty != true else { return [] }
        return try await dbPool.read { db in
            try Task.checkCancellation()
            let request = LibrarySongSQL(query: query, restrictingIDs: ids)
            return try String.fetchAll(
                db,
                sql: "SELECT s.id \(request.fromAndPredicate) \(request.orderBy)",
                arguments: request.arguments
            )
        }
    }

    func librarySongs(
        matching query: LibrarySongQuery,
        restrictedTo ids: Set<String>? = nil
    ) async throws -> [Song] {
        guard ids?.isEmpty != true else { return [] }
        return try await dbPool.read { db in
            try Task.checkCancellation()
            let request = LibrarySongSQL(query: query, restrictingIDs: ids)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.*, COALESCE(s.release_date, a.release_date) AS resolved_release_date
                    \(request.fromAndPredicate)
                    \(request.orderBy)
                    """,
                arguments: request.arguments
            )
            try Task.checkCancellation()
            return rows.map { $0.songFromCachedColumns(releaseDateColumn: "resolved_release_date") }
        }
    }
}

struct LibrarySongQueryClient: Sendable {
    var page: @Sendable (LibrarySongQuery, Int, Int, Bool) async throws -> LibrarySongPage
    var ids: @Sendable (LibrarySongQuery, Set<String>?) async throws -> [String]
    var songs: @Sendable (LibrarySongQuery, Set<String>?) async throws -> [Song]

    init(database: DatabaseManager) {
        page = { try await database.librarySongPage(matching: $0, offset: $1, limit: $2, includeCount: $3) }
        ids = { try await database.librarySongIDs(matching: $0, restrictedTo: $1) }
        songs = { try await database.librarySongs(matching: $0, restrictedTo: $1) }
    }

    init(
        page: @escaping @Sendable (LibrarySongQuery, Int, Int, Bool) async throws -> LibrarySongPage,
        ids: @escaping @Sendable (LibrarySongQuery, Set<String>?) async throws -> [String],
        songs: @escaping @Sendable (LibrarySongQuery, Set<String>?) async throws -> [Song]
    ) {
        self.page = page
        self.ids = ids
        self.songs = songs
    }
}

@MainActor
@Observable
final class LibrarySongQueryStore {
    struct Context: Hashable, Sendable {
        let query: LibrarySongQuery
        fileprivate let generation: UUID
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var songs: [Song] = []
    private(set) var totalCount = 0
    private(set) var state: LoadState = .idle
    private(set) var isLoadingMore = false
    private(set) var moreError: String?
    private(set) var consumedRawOffset = 0
    #if DEBUG
    @ObservationIgnored private(set) var diagnosticPageRequestCount = 0
    #endif

    private let client: LibrarySongQueryClient
    private let pageSize: Int
    private var query: LibrarySongQuery?
    private var generation = UUID()
    private var activePageTask: Task<LibrarySongPage, Error>?
    private var isActive = false

    init(client: LibrarySongQueryClient, pageSize: Int = 500) {
        self.client = client
        self.pageSize = max(1, pageSize)
    }

    convenience init(database: DatabaseManager, pageSize: Int = 500) {
        self.init(client: LibrarySongQueryClient(database: database), pageSize: pageSize)
    }

    var context: Context? {
        guard isActive else { return nil }
        return query.map { Context(query: $0, generation: generation) }
    }

    var hasMore: Bool { isActive && consumedRawOffset < totalCount }

    func loadFirstPage(matching newQuery: LibrarySongQuery) async {
        activePageTask?.cancel()
        generation = UUID()
        let requestGeneration = generation
        query = newQuery
        isActive = true
        songs = []
        totalCount = 0
        consumedRawOffset = 0
        state = .loading
        isLoadingMore = false
        moreError = nil

        do {
            #if DEBUG
            diagnosticPageRequestCount += 1
            #endif
            let task = Task { try await client.page(newQuery, 0, pageSize, true) }
            activePageTask = task
            let page = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isCurrent(newQuery, requestGeneration) else { return }
            activePageTask = nil
            songs = page.songs
            consumedRawOffset = page.songs.count
            totalCount = page.totalCount ?? page.songs.count
            if consumedRawOffset > totalCount { totalCount = consumedRawOffset }
            state = .loaded
        } catch is CancellationError {
            if isCurrent(newQuery, requestGeneration) { activePageTask = nil }
            return
        } catch {
            guard isCurrent(newQuery, requestGeneration) else { return }
            activePageTask = nil
            state = .failed(error.localizedDescription)
        }
    }

    func loadNextPage() async {
        guard let query, hasMore, !isLoadingMore, state == .loaded else { return }
        let requestGeneration = generation
        let offset = consumedRawOffset
        isLoadingMore = true
        moreError = nil
        defer {
            if isCurrent(query, requestGeneration) { isLoadingMore = false }
        }
        do {
            #if DEBUG
            diagnosticPageRequestCount += 1
            #endif
            let task = Task { try await client.page(query, offset, pageSize, false) }
            activePageTask = task
            let page = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isCurrent(query, requestGeneration) else { return }
            activePageTask = nil
            if page.songs.isEmpty {
                // The count and rows came from separate snapshots or the cache
                // changed between pages. Stop rather than requesting the same
                // exhausted offset forever.
                totalCount = min(totalCount, consumedRawOffset)
                return
            }
            consumedRawOffset += page.songs.count
            if consumedRawOffset > totalCount { totalCount = consumedRawOffset }
            let existing = Set(songs.map(\.id))
            songs.append(contentsOf: page.songs.filter { !existing.contains($0.id) })
        } catch is CancellationError {
            if isCurrent(query, requestGeneration) { activePageTask = nil }
            return
        } catch {
            guard isCurrent(query, requestGeneration) else { return }
            activePageTask = nil
            moreError = error.localizedDescription
        }
    }

    func retryNextPage() async {
        guard moreError != nil else { return }
        await loadNextPage()
    }

    func cancel() {
        activePageTask?.cancel()
        activePageTask = nil
        generation = UUID()
        isActive = false
        query = nil
        state = .idle
        isLoadingMore = false
        moreError = nil
    }

    func shouldLoadMore(afterVisibleSongID id: String) -> Bool {
        guard hasMore, !isLoadingMore else { return false }
        return songs.suffix(40).contains { $0.id == id }
    }

    func allIDs(in context: Context) async throws -> [String]? {
        let ids = try await client.ids(context.query, nil)
        return isCurrent(context) ? ids : nil
    }

    func validIDs(_ ids: Set<String>, in context: Context) async throws -> Set<String>? {
        let matching = try await client.ids(context.query, ids)
        return isCurrent(context) ? Set(matching) : nil
    }

    func resolveSongs(_ ids: Set<String>, in context: Context) async throws -> [Song]? {
        let songs = try await client.songs(context.query, ids)
        return isCurrent(context) ? songs : nil
    }

    func materializeSongs(in context: Context) async throws -> [Song]? {
        let songs = try await client.songs(context.query, nil)
        return isCurrent(context) ? songs : nil
    }

    private func isCurrent(_ query: LibrarySongQuery, _ requestGeneration: UUID) -> Bool {
        isActive && !Task.isCancelled
            && self.query == query && generation == requestGeneration
    }

    private func isCurrent(_ context: Context) -> Bool {
        isCurrent(context.query, context.generation)
    }
}

enum LibraryTableSelection {
    static func contextTargetsGlobalSelection(
        nativeTarget: Set<String>,
        tableSelection: Set<String>,
        globalSelection: Set<String>
    ) -> Bool {
        !nativeTarget.isEmpty
            && nativeTarget == tableSelection
            && nativeTarget.isSubset(of: globalSelection)
    }

    /// Applies a selection written by the native Table control. Plain clicks,
    /// arrow moves, and Shift ranges replace global truth. Only Command-style
    /// additive selection retains identities that are not in the loaded page.
    static func applyingNativeSelection(
        global: Set<String>,
        loadedIDs: Set<String>,
        table: Set<String>,
        isAdditive: Bool
    ) -> Set<String> {
        guard isAdditive else { return table }
        return merging(global: global, loadedIDs: loadedIDs, table: table)
    }

    static func merging(
        global: Set<String>,
        loadedIDs: Set<String>,
        table: Set<String>
    ) -> Set<String> {
        global.subtracting(loadedIDs).union(table)
    }
}
