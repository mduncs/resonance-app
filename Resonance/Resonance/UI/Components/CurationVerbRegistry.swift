import SwiftUI

/// What a curation verb acts on: the current subject plus the app services it
/// needs. Built at the call site (deck, menu, future ⌘K HUD) from environment.
@MainActor
struct CurationVerbContext {
    let appState: AppState
    let song: Song?
    let album: Album?
}

/// Result of performing a verb — `message` feeds toast confirmations.
struct CurationVerbOutcome: Sendable, Equatable {
    let message: String?
    let detail: String?
    let style: CurationVerbFeedbackStyle
    /// Whether the local mutation was persisted, even if an optional remote
    /// sync failed. Quick Capture uses this to reconcile its optimistic label.
    let localChangeApplied: Bool
    /// The action completed for a server that is no longer active. Consumers
    /// must not publish its feedback into the replacement server's UI.
    let isStale: Bool

    init(
        message: String?,
        detail: String? = nil,
        style: CurationVerbFeedbackStyle = .success,
        localChangeApplied: Bool = false,
        isStale: Bool = false
    ) {
        self.message = message
        self.detail = detail
        self.style = style
        self.localChangeApplied = localChangeApplied
        self.isStale = isStale
    }
}

enum CurationVerbFeedbackStyle: Sendable, Equatable {
    case success
    case info
    case warning
    case error

    var appFeedbackStyle: FeedbackStyle {
        switch self {
        case .success: return .success
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }
}

/// One curation verb: identity, presentation, availability, action.
/// The unusual vocabulary (Capture / Mark / Project / Admit) is the product's
/// core loop.
@MainActor
struct CurationVerb: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// Short key hint shown on the deck (bare key at Player distance).
    let keyHint: String?
    /// Primary verbs get accent treatment on the deck (Admit).
    let isPrimary: Bool
    /// Destructive verbs (Reject, Delete) must cost keystrokes: the ⌘K HUD
    /// only surfaces them once the type-ahead query matches — never in the
    /// browse list.
    var isDestructive: Bool = false
    let isAvailable: (CurationVerbContext) -> Bool
    let perform: (CurationVerbContext) async -> CurationVerbOutcome
}

/// The single source of truth for curation verbs. The deck, QuickCaptureMenu,
/// and the future ⌘K HUD all render from here so they cannot drift.
///
/// The `perform` closures are thin adapters: they resolve the subject
/// (`song`, else `album` fanned out to its tracks) and delegate every database
/// write to the static helpers in the "Write helpers" section below. Those
/// helpers are the ONE place the writes live; `QuickCaptureMenu` and the tests
/// call the same helpers, so the menu, deck, and DB layer cannot diverge.
@MainActor
enum CurationVerbRegistry {
    /// The four deck verbs, in deck order: Capture, Mark, Project, Admit.
    /// Presentation (`id`/`title`/`keyHint`/`isPrimary`) is pinned — the deck
    /// lane renders these directly, so only `perform`/`isAvailable` may change.
    static func deckVerbs() -> [CurationVerb] {
        [
            CurationVerb(
                id: "capture", title: "Capture", systemImage: "bolt.circle",
                keyHint: "K", isPrimary: false,
                isAvailable: { $0.song != nil || $0.album != nil },
                perform: { context in
                    guard let serverId = context.appState.activeServerId else {
                        return CurationVerbOutcome(message: nil)
                    }
                    let songs = await resolvedSongs(context)
                    guard !songs.isEmpty else { return CurationVerbOutcome(message: nil) }
                    do {
                        for song in songs {
                            try captureSong(song, serverId: serverId, database: context.appState.databaseManager)
                        }
                        let message = songs.count > 1
                            ? "Captured \(songs.count) songs to Waiting Room"
                            : "Captured to Waiting Room"
                        return CurationVerbOutcome(message: message)
                    } catch {
                        return CurationVerbOutcome(message: nil)
                    }
                }
            ),
            CurationVerb(
                id: "mark", title: "Mark", systemImage: "heart",
                keyHint: "M", isPrimary: false,
                isAvailable: { $0.song != nil || $0.album != nil },
                perform: { context in
                    guard let serverId = context.appState.activeServerId else {
                        return CurationVerbOutcome(message: nil)
                    }
                    let songs = await resolvedSongs(context)
                    guard let first = songs.first else { return CurationVerbOutcome(message: nil) }
                    let database = context.appState.databaseManager
                    do {
                        // Cycle the representative song, then bring the rest of an
                        // album fan-out to the same resulting mark so they move together.
                        let newMark = try cycleAttentionMark(first, serverId: serverId, database: database)
                        for song in songs.dropFirst() {
                            try setAttentionMark(song, to: newMark, serverId: serverId, database: database)
                        }
                        let message: String
                        switch newMark {
                        case .loved: message = "Marked ♥"
                        case .interesting: message = "Marked ✳ interesting"
                        default: message = "Mark cleared"
                        }
                        return CurationVerbOutcome(message: message)
                    } catch {
                        return CurationVerbOutcome(message: nil)
                    }
                }
            ),
            CurationVerb(
                id: "project", title: "Project", systemImage: "tray.full",
                keyHint: "P", isPrimary: false,
                isAvailable: { $0.song != nil || $0.album != nil },
                perform: { context in
                    // Interim OP-3 behavior: the deck cannot host a project picker
                    // yet, so the subject lands in the most-recently-updated active
                    // project (or spawns a listening project when none exist). The
                    // ⌘K HUD adds the real picker later; QuickCaptureMenu already
                    // has one and calls the same `addSongToProject` writes.
                    guard let serverId = context.appState.activeServerId else {
                        return CurationVerbOutcome(message: nil)
                    }
                    let songs = await resolvedSongs(context)
                    guard let first = songs.first else { return CurationVerbOutcome(message: nil) }
                    let database = context.appState.databaseManager
                    do {
                        let projects = (try? database.loadProjects(serverId: serverId)) ?? []
                        if let recent = projects.first {
                            for song in songs {
                                try addSongToProject(song, project: recent, serverId: serverId, database: database)
                            }
                            return CurationVerbOutcome(message: "Added to \(recent.name)")
                        } else {
                            let project = try createListeningProject(from: first, serverId: serverId, database: database)
                            for song in songs.dropFirst() {
                                try addSongToProject(song, project: project, serverId: serverId, database: database)
                            }
                            return CurationVerbOutcome(message: "Created project \(project.name)")
                        }
                    } catch {
                        return CurationVerbOutcome(message: nil)
                    }
                }
            ),
            CurationVerb(
                id: "admit", title: "Admit", systemImage: "checkmark.circle",
                keyHint: "A", isPrimary: true,
                // Admission needs an active server to write membership against.
                isAvailable: { ($0.song != nil || $0.album != nil) && $0.appState.activeServerId != nil },
                perform: { context in
                    guard let serverId = context.appState.activeServerId else {
                        return CurationVerbOutcome(message: nil)
                    }
                    let songs = await resolvedSongs(context)
                    guard !songs.isEmpty else { return CurationVerbOutcome(message: nil) }
                    let database = context.appState.databaseManager
                    do {
                        let alreadyAllPresent = try songs.allSatisfy {
                            try database.isInLibrary(id: $0.id, type: .song, serverId: serverId)
                        }
                        for song in songs {
                            try admitSong(song, serverId: serverId, database: database)
                        }
                        context.appState.refreshHiddenIds()
                        context.appState.refreshLibraryMembershipIds()
                        return CurationVerbOutcome(
                            message: alreadyAllPresent ? "Already in the Library" : "Admitted to Library"
                        )
                    } catch {
                        return CurationVerbOutcome(message: nil)
                    }
                }
            ),
        ]
    }

    /// The full verb set: the deck four, then the QuickCaptureMenu tail
    /// (like, favorite, later, interesting, add-to-playlist, more-like-this,
    /// get-info, reject, delete). Every write is extracted from the menu's
    /// former inline implementations, unchanged.
    static func allVerbs() -> [CurationVerb] {
        deckVerbs() + tailVerbs()
    }

    /// Look up a verb by id — QuickCaptureMenu dispatches its buttons through this.
    static func verb(id: String) -> CurationVerb? {
        allVerbs().first { $0.id == id }
    }

    private static func tailVerbs() -> [CurationVerb] {
        [
            CurationVerb(
                id: "like", title: "Like", systemImage: "plus.circle",
                keyHint: nil, isPrimary: false,
                isAvailable: { $0.song != nil || $0.album != nil },
                perform: { context in
                    guard let serverId = context.appState.activeServerId else {
                        return CurationVerbOutcome(message: nil)
                    }
                    let songs = await resolvedSongs(context)
                    guard !songs.isEmpty else { return CurationVerbOutcome(message: nil) }
                    let database = context.appState.databaseManager
                    do {
                        var liked = false
                        for song in songs { liked = try toggleLike(song, serverId: serverId, database: database) }
                        context.appState.refreshLikedIds()
                        return CurationVerbOutcome(message: liked ? "Liked" : "Unliked")
                    } catch {
                        return CurationVerbOutcome(message: nil)
                    }
                }
            ),
            CurationVerb(
                id: "favorite", title: "Favorite", systemImage: "heart",
                keyHint: nil, isPrimary: false,
                isAvailable: { $0.song != nil || $0.album != nil },
                perform: { context in
                    guard let server = context.appState.activeServer else {
                        return CurationVerbOutcome(
                            message: "Connect to a server to update favorites",
                            style: .warning
                        )
                    }
                    let serverId = server.id.uuidString
                    let expectedServerID = server.id
                    let songs = await resolvedSongs(context)
                    guard context.appState.activeServer?.id == expectedServerID else {
                        return CurationVerbOutcome(message: nil, isStale: true)
                    }
                    guard !songs.isEmpty else { return CurationVerbOutcome(message: nil) }

                    var outcomes: [CurationVerbOutcome] = []
                    for song in songs {
                        let outcome = await toggleFavorite(
                            song,
                            context: context,
                            serverId: serverId,
                            expectedServerID: expectedServerID
                        )
                        if outcome.isStale { return outcome }
                        outcomes.append(outcome)
                    }

                    let locallySaved = outcomes.filter { $0.message != nil }
                    let localSaveFailures = outcomes.filter { $0.message == nil }
                    guard !locallySaved.isEmpty else {
                        return localSaveFailures.first ?? CurationVerbOutcome(message: nil)
                    }

                    let syncFailures = locallySaved.filter { $0.style == .warning }
                    let localOnly = locallySaved.filter { $0.style == .info }
                    if songs.count == 1, let outcome = outcomes.first {
                        return outcome
                    }

                    var status: [String] = []
                    if !localSaveFailures.isEmpty {
                        status.append("\(localSaveFailures.count) couldn't be saved")
                    }
                    if !syncFailures.isEmpty {
                        status.append("server sync failed for \(syncFailures.count) \(syncFailures.count == 1 ? "song" : "songs")")
                    }
                    if !localOnly.isEmpty, localOnly.count < songs.count {
                        status.append("\(localOnly.count) saved locally only")
                    }

                    if !status.isEmpty {
                        let syncDetail = syncFailures.compactMap(\.detail).first
                        let localDetail = localSaveFailures.compactMap(\.detail).first
                        let details = [localDetail, syncDetail].compactMap { $0 }
                        return CurationVerbOutcome(
                            message: "Saved \(locallySaved.count) of \(songs.count) favorites locally; " + status.joined(separator: "; "),
                            detail: details.isEmpty ? nil : details.joined(separator: "\n"),
                            style: syncFailures.isEmpty && localSaveFailures.isEmpty ? .info : .warning,
                            localChangeApplied: !locallySaved.isEmpty
                        )
                    }
                    if !localOnly.isEmpty {
                        return CurationVerbOutcome(
                            message: "Updated \(songs.count) favorites locally",
                            style: .info,
                            localChangeApplied: true
                        )
                    }
                    return CurationVerbOutcome(
                        message: "Updated \(songs.count) favorites",
                        localChangeApplied: true
                    )
                }
            ),
            CurationVerb(
                id: "later", title: "Later", systemImage: "clock",
                keyHint: nil, isPrimary: false,
                isAvailable: { $0.song != nil || $0.album != nil },
                perform: { context in
                    await markCaptureTail(context, source: "quick_capture_later", message: "Marked for later")
                }
            ),
            CurationVerb(
                id: "interesting", title: "Interesting", systemImage: "sparkle",
                keyHint: nil, isPrimary: false,
                isAvailable: { $0.song != nil || $0.album != nil },
                perform: { context in
                    await markCaptureTail(context, source: "quick_capture_interesting", message: "Marked interesting")
                }
            ),
            CurationVerb(
                id: "add-to-playlist", title: "Add to Playlist", systemImage: "text.badge.plus",
                keyHint: nil, isPrimary: false,
                isAvailable: { $0.song != nil || $0.album != nil },
                perform: { context in
                    // UI flow: opens the create-playlist sheet with the subject seeded.
                    let songs = await resolvedSongs(context)
                    guard !songs.isEmpty else { return CurationVerbOutcome(message: nil) }
                    context.appState.createPlaylistSongIds = songs.map(\.id)
                    context.appState.showCreatePlaylistSheet = true
                    return CurationVerbOutcome(message: nil)
                }
            ),
            CurationVerb(
                id: "more-like-this", title: "More Like This", systemImage: "dot.radiowaves.left.and.right",
                keyHint: nil, isPrimary: false,
                isAvailable: { $0.song != nil || $0.album != nil },
                perform: { context in
                    // UI flow: opens the similar-songs sheet seeded by the subject.
                    let songs = await resolvedSongs(context)
                    guard let seed = songs.first else { return CurationVerbOutcome(message: nil) }
                    context.appState.similarSongsSeedSong = seed
                    context.appState.showSimilarSongsSheet = true
                    return CurationVerbOutcome(message: nil)
                }
            ),
            CurationVerb(
                id: "get-info", title: "Get Info", systemImage: "info.circle",
                keyHint: nil, isPrimary: false,
                isAvailable: { $0.song != nil || $0.album != nil },
                perform: { context in
                    // UI flow: presents the Get Info sheet for the subject.
                    if let song = context.song {
                        context.appState.getInfoContent = .song(song)
                    } else if let album = context.album {
                        context.appState.getInfoContent = .album(album)
                    }
                    return CurationVerbOutcome(message: nil)
                }
            ),
            CurationVerb(
                id: "reject", title: "Reject", systemImage: "hand.thumbsdown",
                keyHint: nil, isPrimary: false, isDestructive: true,
                isAvailable: { $0.song != nil || $0.album != nil },
                perform: { context in
                    guard let serverId = context.appState.activeServerId else {
                        return CurationVerbOutcome(message: nil)
                    }
                    let songs = await resolvedSongs(context)
                    guard !songs.isEmpty else { return CurationVerbOutcome(message: nil) }
                    let database = context.appState.databaseManager
                    do {
                        for song in songs { try rejectSong(song, serverId: serverId, database: database) }
                        context.appState.refreshHiddenIds()
                        context.appState.refreshLibraryMembershipIds()
                        return CurationVerbOutcome(message: "Rejected")
                    } catch {
                        return CurationVerbOutcome(message: nil)
                    }
                }
            ),
            CurationVerb(
                id: "delete", title: "Delete from Library", systemImage: "trash",
                keyHint: nil, isPrimary: false, isDestructive: true,
                isAvailable: { $0.song != nil },
                perform: { context in
                    // UI flow: routes to the destructive delete confirmation.
                    guard let song = context.song else { return CurationVerbOutcome(message: nil) }
                    context.appState.deleteConfirmSong = song
                    return CurationVerbOutcome(message: nil)
                }
            ),
        ]
    }

    // MARK: - Subject resolution

    /// The verb's subject as a list of songs: the direct song, else the album's
    /// tracks (fanned out via the network actor, matching AlbumDetailView).
    static func resolvedSongs(_ context: CurationVerbContext) async -> [Song] {
        if let song = context.song {
            return [song]
        }
        guard let album = context.album else { return [] }
        return (try? await context.appState.networkActor.fetchAlbumSongs(albumId: album.id)) ?? []
    }

    // MARK: - Write helpers (single source of truth)

    /// Capture: stage the song as unheard in the Waiting Room without admitting,
    /// unhiding, or touching attention marks. `upsertWaitingRoomItem` caches the
    /// song itself (INSERT OR IGNORE), so we deliberately skip `saveSongs` — that
    /// would create library membership under the default auto-admit policy.
    static func captureSong(_ song: Song, serverId: String, database: DatabaseManager) throws {
        try database.upsertWaitingRoomItem(
            song: song,
            serverId: serverId,
            state: .unheard,
            source: "capture"
        )
    }

    /// Cycle the attention mark: none → loved → interesting → none.
    /// Returns the resulting mark (nil when cleared).
    @discardableResult
    static func cycleAttentionMark(
        _ song: Song,
        serverId: String,
        database: DatabaseManager,
        at date: Date = Date()
    ) throws -> AttentionMarkType? {
        let isLoved = try database.isAttentionMarked(id: song.id, type: .song, serverId: serverId, markType: .loved)
        let isInteresting = try database.isAttentionMarked(id: song.id, type: .song, serverId: serverId, markType: .interesting)

        if isLoved {
            try database.clearAttention(id: song.id, type: .song, serverId: serverId, markType: .loved)
            try database.markAttention(
                id: song.id, type: .song, serverId: serverId,
                markType: .interesting, markedAt: date, source: "deck_mark"
            )
            return .interesting
        } else if isInteresting {
            try database.clearAttention(id: song.id, type: .song, serverId: serverId, markType: .interesting)
            return nil
        } else {
            try database.markAttention(
                id: song.id, type: .song, serverId: serverId,
                markType: .loved, markedAt: date, source: "deck_mark"
            )
            return .loved
        }
    }

    /// Force the attention mark to an explicit value (used to bring an album's
    /// remaining tracks to the same mark as its representative song).
    static func setAttentionMark(
        _ song: Song,
        to mark: AttentionMarkType?,
        serverId: String,
        database: DatabaseManager,
        at date: Date = Date()
    ) throws {
        if mark != .loved {
            try database.clearAttention(id: song.id, type: .song, serverId: serverId, markType: .loved)
        }
        if mark != .interesting {
            try database.clearAttention(id: song.id, type: .song, serverId: serverId, markType: .interesting)
        }
        if let mark {
            try database.markAttention(
                id: song.id, type: .song, serverId: serverId,
                markType: mark, markedAt: date, source: "deck_mark"
            )
        }
    }

    /// Admit: full library admission + related album/artist, waiting-room
    /// `.admitted`, unhide, and clear the dismissed mark. Mirrors the former
    /// `QuickCaptureMenu.admit()` writes exactly.
    static func admitSong(_ song: Song, serverId: String, database: DatabaseManager) throws {
        try database.saveSongs([song], serverId: serverId)
        try database.admitSongAndRelated(
            song,
            serverId: serverId,
            admittedBy: .manual,
            sourceDetail: "quick_capture"
        )
        try database.upsertWaitingRoomItem(
            song: song,
            serverId: serverId,
            state: .admitted,
            source: "quick_capture_admit"
        )
        try database.setWaitingRoomState(songId: song.id, serverId: serverId, state: .admitted)
        try database.unhideSongAndRelated(song, serverId: serverId)
        try database.clearAttention(id: song.id, type: .song, serverId: serverId, markType: .dismissed)
    }

    /// Toggle the Resonance-local like (no Navidrome sync). Returns the new state.
    @discardableResult
    static func toggleLike(_ song: Song, serverId: String, database: DatabaseManager) throws -> Bool {
        try database.saveSongs([song], serverId: serverId)
        if try database.isLiked(id: song.id, type: "song", serverId: serverId) {
            try database.unlikeItem(id: song.id, type: "song", serverId: serverId)
            try database.clearAttention(id: song.id, type: .song, serverId: serverId, markType: .liked)
            return false
        } else {
            try database.likeItem(id: song.id, type: "song", serverId: serverId, source: "quick_capture_like")
            try database.markAttention(
                id: song.id, type: .song, serverId: serverId,
                markType: .liked, source: "quick_capture"
            )
            return true
        }
    }

    /// The local database writes for a favorite toggle (star + loved mark).
    static func setFavoriteDB(
        _ song: Song,
        shouldFavorite: Bool,
        serverId: String,
        database: DatabaseManager,
        at date: Date
    ) throws {
        try database.saveSongs([song], serverId: serverId)
        if shouldFavorite {
            try database.starItem(id: song.id, type: "song", serverId: serverId, starredAt: date)
            try database.markAttention(
                id: song.id, type: .song, serverId: serverId,
                markType: .loved, markedAt: date, source: "quick_capture"
            )
        } else {
            try database.unstarItem(id: song.id, type: "song", serverId: serverId)
            try database.clearAttention(id: song.id, type: .song, serverId: serverId, markType: .loved)
        }
    }

    /// Toggle Favorite: persist the local star first, then attempt the optional
    /// Navidrome sync. A local write failure is a failure (never an in-memory
    /// success); a sync failure preserves the valid local-first change.
    static func toggleFavorite(
        _ song: Song,
        context: CurationVerbContext,
        serverId: String,
        expectedServerID: UUID
    ) async -> CurationVerbOutcome {
        let appState = context.appState
        let date = Date()

        guard appState.activeServer?.id == expectedServerID else {
            return CurationVerbOutcome(message: nil, isStale: true)
        }

        let isStarred: Bool
        do {
            isStarred = try appState.databaseManager
                .loadStarredIds(type: "song", serverId: serverId)
                .contains { $0.itemId == song.id }
        } catch {
            return CurationVerbOutcome(message: nil, detail: error.localizedDescription, style: .error)
        }

        let shouldFavorite = !isStarred
        do {
            try setFavoriteDB(
                song,
                shouldFavorite: shouldFavorite,
                serverId: serverId,
                database: appState.databaseManager,
                at: date
            )
        } catch {
            return CurationVerbOutcome(message: nil, detail: error.localizedDescription, style: .error)
        }

        // The local save is durable before publishing the in-memory change.
        // This guard also prevents a result for a replaced server from being
        // applied if this operation later gains an async step before here.
        guard appState.activeServer?.id == expectedServerID else {
            return CurationVerbOutcome(message: nil, isStale: true)
        }
        appState.updateSongStarred(id: song.id, starred: shouldFavorite ? date : nil)

        let localMessage = shouldFavorite ? "Favorited locally" : "Unfavorited locally"
        guard appState.connectionStatus == .connected else {
            return CurationVerbOutcome(message: localMessage, style: .info, localChangeApplied: true)
        }

        guard appState.activeServer?.id == expectedServerID else {
            return CurationVerbOutcome(message: nil, isStale: true)
        }

        do {
            if shouldFavorite {
                try await appState.networkActor.star(
                    id: song.id,
                    type: .song,
                    expectedServerID: expectedServerID
                )
            } else {
                try await appState.networkActor.unstar(
                    id: song.id,
                    type: .song,
                    expectedServerID: expectedServerID
                )
            }
        } catch {
            guard appState.activeServer?.id == expectedServerID else {
                return CurationVerbOutcome(message: nil, isStale: true)
            }
            return CurationVerbOutcome(
                message: "\(shouldFavorite ? "Favorited" : "Unfavorited") locally; server sync failed",
                detail: error.localizedDescription,
                style: .warning,
                localChangeApplied: true
            )
        }

        guard appState.activeServer?.id == expectedServerID else {
            return CurationVerbOutcome(message: nil, isStale: true)
        }
        return CurationVerbOutcome(
            message: shouldFavorite ? "Favorited" : "Unfavorited",
            localChangeApplied: true
        )
    }

    /// Later / Interesting: attention mark + waiting-room staging.
    /// Mirrors the former `QuickCaptureMenu.markCaptureSource()`.
    static func markCaptureSource(
        _ song: Song,
        source: String,
        serverId: String,
        database: DatabaseManager
    ) throws {
        try database.saveSongs([song], serverId: serverId)
        let markType: AttentionMarkType = source.contains("interesting") ? .interesting : .later
        try database.markAttention(
            id: song.id, type: .song, serverId: serverId,
            markType: markType, source: "quick_capture"
        )
        try database.upsertWaitingRoomItem(
            song: song,
            serverId: serverId,
            state: markType == .interesting ? .interesting : .unheard,
            source: source
        )
    }

    private static func markCaptureTail(
        _ context: CurationVerbContext,
        source: String,
        message: String
    ) async -> CurationVerbOutcome {
        guard let serverId = context.appState.activeServerId else {
            return CurationVerbOutcome(message: nil)
        }
        let songs = await resolvedSongs(context)
        guard !songs.isEmpty else { return CurationVerbOutcome(message: nil) }
        do {
            for song in songs {
                try markCaptureSource(song, source: source, serverId: serverId, database: context.appState.databaseManager)
            }
            return CurationVerbOutcome(message: message)
        } catch {
            return CurationVerbOutcome(message: nil)
        }
    }

    /// Reject: waiting-room `.rejected`, remove from library, dismiss + hide.
    /// Mirrors the former `QuickCaptureMenu.reject()`.
    static func rejectSong(_ song: Song, serverId: String, database: DatabaseManager) throws {
        try database.saveSongs([song], serverId: serverId)
        try database.upsertWaitingRoomItem(
            song: song,
            serverId: serverId,
            state: .rejected,
            source: "quick_capture_reject"
        )
        try database.setWaitingRoomState(songId: song.id, serverId: serverId, state: .rejected)
        try database.removeFromLibrary(id: song.id, type: .song, serverId: serverId)
        try database.markAttention(
            id: song.id, type: .song, serverId: serverId,
            markType: .dismissed, source: "quick_capture"
        )
        try database.hideItem(id: song.id, type: "song", serverId: serverId, reason: "quick_capture_reject")
    }

    /// Add a song to a specific project (dedup, position, notify) — the shared
    /// write behind both the deck's Project verb and the menu's project picker.
    static func addSongToProject(
        _ song: Song,
        project: Project,
        serverId: String,
        database: DatabaseManager
    ) throws {
        try database.saveSongs([song], serverId: serverId)
        let existingItems = try database.loadProjectItems(projectId: project.id, serverId: serverId)
        if !existingItems.contains(where: { $0.itemType == .song && $0.itemId == song.id }) {
            let position = try database.nextProjectItemPosition(projectId: project.id, serverId: serverId)
            try database.addProjectItem(
                projectId: project.id,
                itemId: song.id,
                itemType: .song,
                serverId: serverId,
                position: position,
                addedBy: "quick_capture"
            )
        }
        postProjectChange(projectId: project.id, serverId: serverId)
    }

    /// Spawn a listening project seeded from a song and add the song to it.
    @discardableResult
    static func createListeningProject(
        from song: Song,
        serverId: String,
        database: DatabaseManager
    ) throws -> Project {
        let project = Project(
            serverId: serverId,
            name: song.album.isEmpty ? song.title : song.album,
            kind: "listening"
        )
        try database.saveProject(project)
        try addSongToProject(song, project: project, serverId: serverId, database: database)
        return project
    }

    static func postProjectChange(projectId: String, serverId: String) {
        NotificationCenter.default.post(
            name: .resonanceProjectItemsDidChange,
            object: nil,
            userInfo: [
                "serverId": serverId,
                "projectId": projectId
            ]
        )
    }
}
