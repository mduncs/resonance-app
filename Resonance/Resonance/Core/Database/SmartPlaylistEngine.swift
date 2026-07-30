import Foundation
import GRDB

// MARK: - Rule Model

/// A single rule in a smart playlist (e.g., "genre contains Rock")
struct SmartPlaylistRule: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var field: RuleField
    var op: RuleOperator
    var value: String

    enum RuleField: String, Codable, Sendable, CaseIterable {
        case title, artist, album, genre
        case year, duration, track, discNumber
        case rating, playCount, lastPlayed
        case liked, likedAt
        case starred, starredAt
        case bitRate, suffix
    }

    enum RuleOperator: String, Codable, Sendable, CaseIterable {
        // String
        case contains, notContains, equals, notEquals
        case startsWith, endsWith
        // Numeric / Date
        case greaterThan, lessThan
        case greaterOrEqual, lessOrEqual
        case inRange
        // Boolean
        case isTrue, isFalse
        // Relative date
        case inLast, notInLast // value = "30d", "7d", "1y" etc.

        var displayName: String {
            switch self {
            case .contains: return "contains"
            case .notContains: return "does not contain"
            case .equals: return "is"
            case .notEquals: return "is not"
            case .startsWith: return "starts with"
            case .endsWith: return "ends with"
            case .greaterThan: return "greater than"
            case .lessThan: return "less than"
            case .greaterOrEqual: return "at least"
            case .lessOrEqual: return "at most"
            case .inRange: return "between"
            case .isTrue: return "is true"
            case .isFalse: return "is false"
            case .inLast: return "in the last"
            case .notInLast: return "not in the last"
            }
        }
    }
}

/// A group of rules joined by AND or OR
struct SmartPlaylistRuleGroup: Codable, Sendable, Hashable {
    var conjunction: Conjunction = .and
    var rules: [SmartPlaylistRule] = []

    enum Conjunction: String, Codable, Sendable {
        case and = "AND"
        case or = "OR"
    }
}

/// Complete smart playlist definition
struct SmartPlaylist: Identifiable, Codable, Sendable, Hashable {
    var id: String
    var name: String
    var serverId: String
    var ruleGroup: SmartPlaylistRuleGroup
    var sortBy: String
    var sortOrder: SortOrder
    var itemLimit: Int?
    var createdAt: Date
    var updatedAt: Date
    var lastEvaluated: Date?

    enum SortOrder: String, Codable, Sendable {
        case asc, desc
    }

    init(id: String = UUID().uuidString, name: String, serverId: String,
         ruleGroup: SmartPlaylistRuleGroup = SmartPlaylistRuleGroup(),
         sortBy: String = "title", sortOrder: SortOrder = .asc,
         itemLimit: Int? = nil) {
        self.id = id
        self.name = name
        self.serverId = serverId
        self.ruleGroup = ruleGroup
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.itemLimit = itemLimit
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - SQL Compilation

/// Compiles smart playlist rules into SQL WHERE clauses
enum SmartPlaylistCompiler {

    struct CompiledQuery {
        let sql: String
        let arguments: [DatabaseValueConvertible?]
    }

    /// Compile a rule group into a SQL WHERE clause against cached_songs + aggregation subqueries
    static func compile(ruleGroup: SmartPlaylistRuleGroup, serverId: String) -> CompiledQuery {
        guard !ruleGroup.rules.isEmpty else {
            return CompiledQuery(sql: "1=1", arguments: [])
        }

        var clauses: [String] = []
        var args: [DatabaseValueConvertible?] = []

        for rule in ruleGroup.rules {
            let compiled = compileRule(rule, serverId: serverId)
            clauses.append(compiled.sql)
            args.append(contentsOf: compiled.arguments)
        }

        let conjunction = ruleGroup.conjunction == .and ? " AND " : " OR "
        let combinedSQL = clauses.map { "(\($0))" }.joined(separator: conjunction)
        return CompiledQuery(sql: combinedSQL, arguments: args)
    }

    /// Build the full SELECT query for evaluating a smart playlist
    static func buildEvaluationQuery(playlist: SmartPlaylist) -> CompiledQuery {
        let whereClause = compile(ruleGroup: playlist.ruleGroup, serverId: playlist.serverId)

        let sortColumn = mapSortField(playlist.sortBy)
        let sortDir = playlist.sortOrder == .asc ? "ASC" : "DESC"
        let limitClause = playlist.itemLimit.map { "LIMIT \($0)" } ?? ""

        let sql = """
            SELECT s.id FROM cached_songs s
            LEFT JOIN (
                SELECT song_id, COUNT(*) as play_count, MAX(played_at) as last_played
                FROM play_history WHERE server_id = ?
                GROUP BY song_id
            ) ph ON s.id = ph.song_id
            LEFT JOIN (
                SELECT item_id, liked_at FROM liked_items
                WHERE item_type = 'song' AND server_id = ?
            ) li ON s.id = li.item_id
            LEFT JOIN (
                SELECT item_id, starred_at FROM starred_items
                WHERE item_type = 'song' AND server_id = ? AND unstarred_at IS NULL
            ) si ON s.id = si.item_id
            LEFT JOIN (
                SELECT item_id FROM hidden_items
                WHERE item_type = 'song' AND server_id = ?
            ) hi ON s.id = hi.item_id
            INNER JOIN library_membership lm
                ON lm.item_id = s.id
                AND lm.item_type = 'song'
                AND lm.server_id = s.server_id
                AND lm.removed_at IS NULL
            WHERE s.server_id = ? AND hi.item_id IS NULL AND (\(whereClause.sql))
            ORDER BY \(sortColumn) \(sortDir)
            \(limitClause)
            """

        var args: [DatabaseValueConvertible?] = [
            playlist.serverId, playlist.serverId, playlist.serverId, playlist.serverId, playlist.serverId
        ]
        args.append(contentsOf: whereClause.arguments)

        return CompiledQuery(sql: sql, arguments: args)
    }

    // MARK: - Private

    private static func compileRule(_ rule: SmartPlaylistRule, serverId: String) -> CompiledQuery {
        switch rule.field {
        // String fields on cached_songs
        case .title:
            return compileStringOp("s.title", rule.op, rule.value)
        case .artist:
            return compileStringOp("s.artist_name", rule.op, rule.value)
        case .album:
            return compileStringOp("s.album_name", rule.op, rule.value)
        case .genre:
            return compileStringOp("s.genre", rule.op, rule.value)
        case .suffix:
            return compileStringOp("s.suffix", rule.op, rule.value)

        // Numeric fields on cached_songs
        case .year:
            return compileNumericOp("s.year", rule.op, rule.value)
        case .duration:
            return compileNumericOp("s.duration", rule.op, rule.value)
        case .track:
            return compileNumericOp("s.track", rule.op, rule.value)
        case .discNumber:
            return compileNumericOp("s.disc_number", rule.op, rule.value)
        case .rating:
            return compileNumericOp("s.rating", rule.op, rule.value)
        case .bitRate:
            return compileNumericOp("s.bit_rate", rule.op, rule.value)

        // Aggregation fields (from subqueries)
        case .playCount:
            return compileNumericOp("COALESCE(ph.play_count, 0)", rule.op, rule.value)
        case .lastPlayed:
            return compileDateOp("ph.last_played", rule.op, rule.value)

        // Liked fields (from subquery)
        case .liked:
            return compileBoolOp("li.item_id", rule.op)
        case .likedAt:
            return compileDateOp("li.liked_at", rule.op, rule.value)

        // Starred fields (from subquery)
        case .starred:
            return compileBoolOp("si.item_id", rule.op)
        case .starredAt:
            return compileDateOp("si.starred_at", rule.op, rule.value)
        }
    }

    private static func compileStringOp(_ column: String, _ op: SmartPlaylistRule.RuleOperator, _ value: String) -> CompiledQuery {
        switch op {
        case .contains:
            return CompiledQuery(sql: "\(column) LIKE '%' || ? || '%'", arguments: [value])
        case .notContains:
            return CompiledQuery(sql: "\(column) NOT LIKE '%' || ? || '%'", arguments: [value])
        case .equals:
            return CompiledQuery(sql: "\(column) = ?", arguments: [value])
        case .notEquals:
            return CompiledQuery(sql: "\(column) != ?", arguments: [value])
        case .startsWith:
            return CompiledQuery(sql: "\(column) LIKE ? || '%'", arguments: [value])
        case .endsWith:
            return CompiledQuery(sql: "\(column) LIKE '%' || ?", arguments: [value])
        default:
            return CompiledQuery(sql: "1=1", arguments: [])
        }
    }

    private static func compileNumericOp(_ column: String, _ op: SmartPlaylistRule.RuleOperator, _ value: String) -> CompiledQuery {
        guard let num = Int(value) else {
            return CompiledQuery(sql: "1=0", arguments: [])
        }

        switch op {
        case .equals:
            return CompiledQuery(sql: "\(column) = ?", arguments: [num])
        case .notEquals:
            return CompiledQuery(sql: "\(column) != ?", arguments: [num])
        case .greaterThan:
            return CompiledQuery(sql: "\(column) > ?", arguments: [num])
        case .lessThan:
            return CompiledQuery(sql: "\(column) < ?", arguments: [num])
        case .greaterOrEqual:
            return CompiledQuery(sql: "\(column) >= ?", arguments: [num])
        case .lessOrEqual:
            return CompiledQuery(sql: "\(column) <= ?", arguments: [num])
        case .inRange:
            // value format: "min-max" e.g. "2000-2023"
            let parts = value.split(separator: "-")
            if parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) {
                return CompiledQuery(sql: "\(column) BETWEEN ? AND ?", arguments: [low, high])
            }
            return CompiledQuery(sql: "1=0", arguments: [])
        default:
            return CompiledQuery(sql: "1=1", arguments: [])
        }
    }

    private static func compileDateOp(_ column: String, _ op: SmartPlaylistRule.RuleOperator, _ value: String) -> CompiledQuery {
        switch op {
        case .inLast:
            if let date = parseDateOffset(value) {
                return CompiledQuery(sql: "\(column) >= ?", arguments: [date])
            }
            return CompiledQuery(sql: "1=0", arguments: [])
        case .notInLast:
            if let date = parseDateOffset(value) {
                return CompiledQuery(sql: "(\(column) IS NULL OR \(column) < ?)", arguments: [date])
            }
            return CompiledQuery(sql: "1=0", arguments: [])
        case .greaterThan:
            if let date = parseDateOffset(value) {
                return CompiledQuery(sql: "\(column) > ?", arguments: [date])
            }
            return CompiledQuery(sql: "1=0", arguments: [])
        case .lessThan:
            if let date = parseDateOffset(value) {
                return CompiledQuery(sql: "\(column) < ?", arguments: [date])
            }
            return CompiledQuery(sql: "1=0", arguments: [])
        default:
            return CompiledQuery(sql: "1=1", arguments: [])
        }
    }

    private static func compileBoolOp(_ column: String, _ op: SmartPlaylistRule.RuleOperator) -> CompiledQuery {
        switch op {
        case .isTrue:
            return CompiledQuery(sql: "\(column) IS NOT NULL", arguments: [])
        case .isFalse:
            return CompiledQuery(sql: "\(column) IS NULL", arguments: [])
        default:
            return CompiledQuery(sql: "1=1", arguments: [])
        }
    }

    /// Parse relative date offset like "30d", "7d", "1y", "6m"
    private static func parseDateOffset(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.count >= 2 else { return nil }

        let unit = trimmed.last!
        guard let amount = Int(trimmed.dropLast()) else { return nil }

        let calendar = Calendar.current
        switch unit {
        case "d":
            return calendar.date(byAdding: .day, value: -amount, to: Date())
        case "w":
            return calendar.date(byAdding: .weekOfYear, value: -amount, to: Date())
        case "m":
            return calendar.date(byAdding: .month, value: -amount, to: Date())
        case "y":
            return calendar.date(byAdding: .year, value: -amount, to: Date())
        default:
            return nil
        }
    }

    private static func mapSortField(_ field: String) -> String {
        switch field {
        case "title": return "s.title"
        case "artist": return "s.artist_name"
        case "album": return "s.album_name"
        case "year": return "s.year"
        case "duration": return "s.duration"
        case "rating": return "COALESCE(s.rating, 0)"
        case "playCount": return "COALESCE(ph.play_count, 0)"
        case "lastPlayed": return "ph.last_played"
        case "likedAt": return "li.liked_at"
        case "starredAt": return "si.starred_at"
        case "random": return "RANDOM()"
        default: return "s.title"
        }
    }
}

// MARK: - Operator Compatibility

extension SmartPlaylistRule.RuleField {
    /// Valid operators for this field type
    var compatibleOperators: [SmartPlaylistRule.RuleOperator] {
        switch self {
        case .title, .artist, .album, .genre, .suffix:
            return [.contains, .notContains, .equals, .notEquals, .startsWith, .endsWith]
        case .year, .duration, .track, .discNumber, .rating, .bitRate, .playCount:
            return [.equals, .notEquals, .greaterThan, .lessThan, .greaterOrEqual, .lessOrEqual, .inRange]
        case .lastPlayed, .likedAt, .starredAt:
            return [.inLast, .notInLast]
        case .liked, .starred:
            return [.isTrue, .isFalse]
        }
    }

    var displayName: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .genre: return "Genre"
        case .year: return "Year"
        case .duration: return "Duration (sec)"
        case .track: return "Track #"
        case .discNumber: return "Disc #"
        case .rating: return "Rating"
        case .playCount: return "Play Count"
        case .lastPlayed: return "Last Played"
        case .liked: return "Is Liked"
        case .likedAt: return "Liked Date"
        case .starred: return "Is Loved"
        case .starredAt: return "Loved Date"
        case .bitRate: return "Bit Rate"
        case .suffix: return "File Type"
        }
    }
}
