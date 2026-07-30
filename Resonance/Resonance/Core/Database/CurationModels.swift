import Foundation

enum LibraryItemType: String, Codable, Sendable, CaseIterable, Hashable {
    case song
    case album
    case artist
}

enum LibraryAdmissionSource: String, Codable, Sendable, CaseIterable, Hashable {
    case navidromeLibrary = "navidrome_library"
    case manual
    case importBatch = "import"
    case appleMusic = "apple_music"
    case project
}

enum ImportPolicyDefaults {
    static let autoAdmitNavidromeLibrary = "importPolicyAutoAdmitNavidromeLibrary"
    static let stageServerImports = "importPolicyStageServerImports"
    static let keepUnclassifiedOutOfLibrary = "importPolicyKeepUnclassifiedOutOfLibrary"
    static let autoMarkPartialAuditions = "importPolicyAutoMarkPartialAuditions"
    static let autoMarkHeardAuditions = "importPolicyAutoMarkHeardAuditions"

    static let allKeys = [
        autoAdmitNavidromeLibrary,
        stageServerImports,
        keepUnclassifiedOutOfLibrary,
        autoMarkPartialAuditions,
        autoMarkHeardAuditions
    ]

    static let defaultValues: [String: Bool] = [
        autoAdmitNavidromeLibrary: true,
        stageServerImports: false,
        keepUnclassifiedOutOfLibrary: true,
        autoMarkPartialAuditions: true,
        autoMarkHeardAuditions: true
    ]

    static func defaultValue(for key: String) -> Bool? {
        defaultValues[key]
    }

    static func bool(for key: String) -> Bool {
        bool(for: key, in: .standard, default: defaultValue(for: key) ?? false)
    }

    static func bool(for key: String, default defaultValue: Bool) -> Bool {
        bool(for: key, in: .standard, default: defaultValue)
    }

    static func bool(for key: String, in userDefaults: UserDefaults, default defaultValue: Bool) -> Bool {
        if userDefaults.object(forKey: key) == nil {
            return defaultValue
        }
        return userDefaults.bool(forKey: key)
    }

    static func bool(for key: String, in userDefaults: UserDefaults) -> Bool {
        bool(for: key, in: userDefaults, default: defaultValue(for: key) ?? false)
    }

    static func register(in userDefaults: UserDefaults = .standard) {
        userDefaults.register(defaults: defaultValues.reduce(into: [String: Any]()) { defaults, entry in
            defaults[entry.key] = entry.value
        })
    }

    static func shouldAdmitImportedMedia(in userDefaults: UserDefaults = .standard) -> Bool {
        bool(
            for: autoAdmitNavidromeLibrary,
            in: userDefaults,
            default: defaultValue(for: autoAdmitNavidromeLibrary) ?? true
        ) || !bool(
            for: keepUnclassifiedOutOfLibrary,
            in: userDefaults,
            default: defaultValue(for: keepUnclassifiedOutOfLibrary) ?? true
        )
    }

    static func shouldStageImportedSongs(in userDefaults: UserDefaults = .standard) -> Bool {
        !shouldAdmitImportedMedia(in: userDefaults) && bool(
            for: stageServerImports,
            in: userDefaults,
            default: defaultValue(for: stageServerImports) ?? false
        )
    }
}

enum AttentionMarkType: String, Codable, Sendable, CaseIterable, Hashable {
    case liked
    case loved
    case later
    case interesting
    case hidden
    case dismissed
    case moreLikeThis = "more_like_this"
}

enum WaitingRoomState: String, Codable, Sendable, CaseIterable, Hashable {
    case unheard
    case partlyHeard = "partly_heard"
    case heard
    case skipped
    case replayed
    case interesting
    case admitted
    case rejected

    var isDecided: Bool {
        self == .admitted || self == .rejected
    }
}

struct Project: Identifiable, Codable, Sendable, Hashable {
    var id: String
    var serverId: String
    var name: String
    var kind: String
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    var notes: String?
    /// Lineage bucket for the pseudo-hierarchy (e.g. "Electronic", "Classical").
    /// Derived from the Fetcher collection's `source_domain` for automade
    /// projects; nil groups under "Uncategorized". One level only by design.
    var category: String?

    init(
        id: String = UUID().uuidString,
        serverId: String,
        name: String,
        kind: String = "collection",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil,
        notes: String? = nil,
        category: String? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.notes = notes
        self.category = category
    }
}

struct ProjectItem: Identifiable, Codable, Sendable, Hashable {
    var projectId: String
    var itemId: String
    var itemType: LibraryItemType
    var serverId: String
    var position: Int
    var addedAt: Date
    var addedBy: String?
    var note: String?

    var id: String { "\(projectId):\(itemType.rawValue):\(itemId)" }
}

struct ProjectSongItem: Identifiable, Codable, Sendable, Hashable {
    var projectItem: ProjectItem
    var song: Song?

    var id: String { projectItem.id }
}

struct WaitingRoomItem: Identifiable, Codable, Sendable, Hashable {
    var song: Song
    var serverId: String
    var state: WaitingRoomState
    var source: String
    var addedAt: Date
    var updatedAt: Date
    var firstAuditionedAt: Date?
    var lastAuditionedAt: Date?
    var auditionCount: Int
    var auditionSeconds: Int
    var lastPositionSeconds: Int?
    var admittedAt: Date?
    var rejectedAt: Date?
    var notes: String?

    var id: String { song.id }
}
