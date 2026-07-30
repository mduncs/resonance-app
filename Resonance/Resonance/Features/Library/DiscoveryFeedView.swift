import SwiftUI

struct DiscoveryFeedView: View {
    @Environment(AppState.self) private var appState

    /// Mirrors the scheduler's cadence so the room can say honestly whether
    /// anything is watching the server on its behalf.
    @AppStorage(LibraryRefreshScheduler.intervalDefaultsKey)
    private var libraryRefreshInterval = LibraryRefreshScheduler.defaultIntervalMinutes

    @State private var entries: [DiscoveryEntry] = []
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var actionError: ResonanceError?

    /// How many pre-history albums the one-time backfill seeds.
    private static let backfillLimit = 50

    /// Entering the room won't re-sync if the library synced within this window.
    private static let entryRefreshThrottle: TimeInterval = 5 * 60

    /// One ledger row. `isBackfill` marks an album that was already in the
    /// library when Resonance started watching — shown for context, never
    /// counted as an arrival.
    private struct DiscoveryEntry: Identifiable {
        let album: Album
        let discoveredAt: Date
        let isSeen: Bool
        let isBackfill: Bool

        var id: String { album.id }
    }

    private var arrivals: [DiscoveryEntry] {
        entries.filter { !$0.isBackfill }
    }

    private var backfilled: [DiscoveryEntry] {
        entries.filter(\.isBackfill)
    }

    private var grouped: [(title: String, items: [DiscoveryEntry])] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday)!
        let startOfMonth = calendar.date(byAdding: .month, value: -1, to: startOfToday)!

        var today: [DiscoveryEntry] = []
        var thisWeek: [DiscoveryEntry] = []
        var thisMonth: [DiscoveryEntry] = []
        var older: [DiscoveryEntry] = []

        for item in arrivals {
            if item.discoveredAt >= startOfToday {
                today.append(item)
            } else if item.discoveredAt >= startOfWeek {
                thisWeek.append(item)
            } else if item.discoveredAt >= startOfMonth {
                thisMonth.append(item)
            } else {
                older.append(item)
            }
        }

        var result: [(String, [DiscoveryEntry])] = []
        if !today.isEmpty { result.append(("Today", today)) }
        if !thisWeek.isEmpty { result.append(("This Week", thisWeek)) }
        if !thisMonth.isEmpty { result.append(("This Month", thisMonth)) }
        if !older.isEmpty { result.append(("Older", older)) }
        // The seed sits last and keeps its own name — these were never arrivals,
        // they're what the library already held when the ledger opened.
        if !backfilled.isEmpty { result.append(("Already in Your Library", backfilled)) }
        return result
    }

    private var unseenCount: Int {
        arrivals.filter { !$0.isSeen }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Music")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    if !entries.isEmpty || isRefreshing {
                        HStack(spacing: 6) {
                            Text(summaryText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            if isRefreshing {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            }
                        }
                    }
                }

                Spacer()

                if unseenCount > 0 {
                    Button {
                        markAllSeen()
                    } label: {
                        Label("Mark All Seen", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    Task { await refreshFromServer() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing)
                .help("Check the server for new albums now")

                Button {
                    openRandom()
                } label: {
                    Label("Open Random", systemImage: "shuffle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(entries.isEmpty)
                .help("Open one of these albums at random")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if let actionError {
                ErrorBanner(error: actionError) {
                    self.actionError = nil
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                CompactStatusView(
                    title: "No New Arrivals",
                    systemImage: "sparkles",
                    message: emptyStateMessage,
                    actionTitle: isRefreshing ? nil : "Check Now",
                    actionSystemImage: "arrow.clockwise"
                ) {
                    Task { await refreshFromServer() }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(grouped, id: \.title) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(section.title)
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 24)

                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 16)], spacing: 16) {
                                    ForEach(section.items) { item in
                                        DiscoveryAlbumCard(
                                            album: item.album,
                                            discoveredAt: item.discoveredAt,
                                            isSeen: item.isSeen,
                                            onStage: { stageAlbum(item.album) },
                                            onAdmit: { admitAlbum(item.album) },
                                            onMarkSeen: { markSeen(item.album) }
                                        )
                                    }
                                }
                                .padding(.horizontal, 24)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .task {
            await loadDiscoveries()
            clearUnseenBadge()
            // The room has no writer of its own, so entering it cranks the same
            // machinery the scheduler runs on a timer, then seeds history if the
            // ledger is still empty afterwards. Entry is throttled — the crank
            // is a full library sync, not something to run on every visit.
            await refreshFromServer(force: false)
            await backfillIfNeeded()
        }
    }

    private var summaryText: String {
        var parts: [String] = []

        let arrivalCount = arrivals.count
        if arrivalCount > 0 {
            let albumLabel = arrivalCount == 1 ? "1 new album" : "\(arrivalCount) new albums"
            parts.append(unseenCount > 0 ? "\(albumLabel) · \(unseenCount) unseen" : albumLabel)
        }

        let seededCount = backfilled.count
        if seededCount > 0 {
            parts.append("\(seededCount) already in your library")
        }

        if libraryRefreshInterval <= 0 {
            parts.append("auto-refresh off")
        }

        return parts.isEmpty ? "Watching for new albums" : parts.joined(separator: " · ")
    }

    private var emptyStateMessage: String {
        let base = "Nothing has arrived since the last library sync. New albums are recorded by the background library refresh — this room doesn't watch the server on its own."
        if libraryRefreshInterval > 0 {
            return "\(base) Resonance is checking every \(intervalLabel)."
        }
        return "\(base) Automatic refresh is off (Settings › Cache › Library Refresh), so only the button below records arrivals."
    }

    private var intervalLabel: String {
        let minutes = libraryRefreshInterval
        if minutes % 1440 == 0 {
            let days = minutes / 1440
            return days == 1 ? "day" : "\(days) days"
        }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "hour" : "\(hours) hours"
        }
        return "\(minutes) minutes"
    }

    private func loadDiscoveries() async {
        guard let serverId = appState.activeServerId else {
            entries = []
            isLoading = false
            return
        }
        let ledger = (try? appState.databaseManager.loadDiscoveryLedger(serverId: serverId)) ?? []
        entries = ledger
            .filter { !appState.hiddenAlbumIds.contains($0.album.id) }
            .map {
                DiscoveryEntry(
                    album: $0.album,
                    discoveredAt: $0.discoveredAt,
                    isSeen: $0.isSeen,
                    isBackfill: $0.source == DatabaseManager.discoveryBackfillSource
                )
            }
        isLoading = false
    }

    /// Manual crank on the scheduler's diff — the only thing that records
    /// arrivals. Arrivals found here stay unseen on purpose: the badge was
    /// already cleared on entry, and anything that lands while you're looking
    /// at the room deserves to glow.
    /// - Parameter force: `true` for the explicit buttons, `false` for the
    ///   on-entry crank, which skips when the library synced very recently.
    private func refreshFromServer(force: Bool = true) async {
        guard !isRefreshing else { return }
        guard let scheduler = appState.libraryRefreshScheduler else { return }
        if !force && syncedRecently { return }
        isRefreshing = true
        await scheduler.refreshNow()
        await loadDiscoveries()
        isRefreshing = false
    }

    /// A full sync landed inside the entry-throttle window, so entering the room
    /// again shouldn't re-run one.
    private var syncedRecently: Bool {
        guard let serverId = appState.activeServerId else { return true }
        let raw = (try? appState.databaseManager.getSyncMetadata(key: "lastSync.\(serverId)")) ?? nil
        guard let raw, let last = ISO8601DateFormatter().date(from: raw) else { return false }
        return Date().timeIntervalSince(last) < Self.entryRefreshThrottle
    }

    /// One-time seed so a library Resonance only just started watching reads as
    /// a ledger with history instead of a barren empty room. Bounded to 50,
    /// tagged `backfill`, and written already-seen so nothing glows
    /// retroactively. Prefers the server's own "newest" ordering; falls back to
    /// the cache's release-year proxy when the server isn't reachable.
    private func backfillIfNeeded() async {
        guard let serverId = appState.activeServerId else { return }
        let hasHistory = (try? appState.databaseManager.hasDiscoveryHistory(serverId: serverId)) ?? true
        guard !hasHistory else { return }

        var seedIds: [String] = []
        if let newest = try? await appState.networkActor.fetchAlbums(type: .newest, size: Self.backfillLimit) {
            seedIds = newest.map(\.id)
        }
        if seedIds.isEmpty {
            seedIds = (try? appState.databaseManager.recentCachedAlbumIds(serverId: serverId, limit: Self.backfillLimit)) ?? []
        }
        guard !seedIds.isEmpty else { return }

        _ = try? appState.databaseManager.backfillDiscoveredAlbums(
            seedIds,
            serverId: serverId,
            limit: Self.backfillLimit
        )
        await loadDiscoveries()
    }

    /// Clears the sidebar badge on visit (the seen-on-appear semantic moved here
    /// from RecentlyAddedView) while leaving the in-memory unseen dots intact so
    /// this session still shows what was new on arrival.
    private func clearUnseenBadge() {
        guard let serverId = appState.activeServerId else { return }
        try? appState.databaseManager.markAllDiscoveriesSeen(serverId: serverId)
        appState.unseenDiscoveryCount = 0
        // Visiting the ledger settles the growing edge — let the plane fade in step.
        NotificationCenter.default.post(name: .resonanceCurationDidChange, object: nil)
    }

    private func markAllSeen() {
        guard let serverId = appState.activeServerId else { return }
        try? appState.databaseManager.markAllDiscoveriesSeen(serverId: serverId)
        appState.unseenDiscoveryCount = 0
        entries = entries.map {
            DiscoveryEntry(album: $0.album, discoveredAt: $0.discoveredAt, isSeen: true, isBackfill: $0.isBackfill)
        }
        NotificationCenter.default.post(name: .resonanceCurationDidChange, object: nil)
    }

    private func markSeen(_ album: Album) {
        guard let serverId = appState.activeServerId else { return }
        // Persist per-album now (was in-memory only), then let the growing edge fade.
        try? appState.databaseManager.markDiscoverySeen(albumId: album.id, serverId: serverId)
        setSeenInMemory(album.id)
        // Keep the sidebar badge honest — it otherwise only recomputes on the
        // next library-refresh pass.
        appState.unseenDiscoveryCount = (try? appState.databaseManager.unseenDiscoveryCount(serverId: serverId)) ?? 0
        NotificationCenter.default.post(name: .resonanceCurationDidChange, object: nil)
    }

    private func setSeenInMemory(_ albumId: String) {
        guard let index = entries.firstIndex(where: { $0.album.id == albumId }) else { return }
        let existing = entries[index]
        entries[index] = DiscoveryEntry(
            album: existing.album,
            discoveredAt: existing.discoveredAt,
            isSeen: true,
            isBackfill: existing.isBackfill
        )
    }

    /// Opens one of the listed albums at random. Deliberately not "Shuffle All"
    /// — nothing is queued or shuffled here.
    private func openRandom() {
        guard let random = entries.randomElement() else { return }
        appState.navigationTargetAlbumId = random.album.id
        appState.selectedSidebarItem = .albums
    }

    // MARK: - Triage verbs (release-level, mirrors UnclassifiedView)

    private func stageAlbum(_ album: Album) {
        guard let serverId = appState.activeServerId else { return }
        Task {
            do {
                let songs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
                for song in songs {
                    try appState.databaseManager.upsertWaitingRoomItem(
                        song: song,
                        serverId: serverId,
                        state: .unheard,
                        source: "new_music"
                    )
                }
                setSeenInMemory(album.id)
                actionError = nil
            } catch {
                actionError = resonanceError(from: error)
            }
        }
    }

    private func admitAlbum(_ album: Album) {
        guard let serverId = appState.activeServerId else { return }
        Task {
            do {
                let songs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
                for song in songs {
                    try appState.databaseManager.admitSongAndRelated(
                        song,
                        serverId: serverId,
                        admittedBy: .manual,
                        sourceDetail: "new_music"
                    )
                    try appState.databaseManager.upsertWaitingRoomItem(
                        song: song,
                        serverId: serverId,
                        state: .admitted,
                        source: "new_music_admit"
                    )
                    try appState.databaseManager.setWaitingRoomState(songId: song.id, serverId: serverId, state: .admitted)
                }
                appState.refreshLibraryMembershipIds()
                setSeenInMemory(album.id)
                actionError = nil
            } catch {
                actionError = resonanceError(from: error)
            }
        }
    }

    private func resonanceError(from error: Error) -> ResonanceError {
        if let resonanceError = error as? ResonanceError {
            return resonanceError
        }
        return .unknown(error)
    }
}

// MARK: - Album Card

private struct DiscoveryAlbumCard: View {
    @Environment(AppState.self) private var appState
    let album: Album
    let discoveredAt: Date
    let isSeen: Bool
    let onStage: () -> Void
    let onAdmit: () -> Void
    let onMarkSeen: () -> Void

    @State private var isHovered = false
    @State private var voices: [SourceAttributionRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                appState.navigationTargetAlbumId = album.id
                appState.selectedSidebarItem = .albums
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        // Flexible art: the grid cell decides the width, the
                        // aspect ratio makes it square, and the single clip
                        // below owns the corner radius.
                        EnvironmentAlbumArtView(coverArtId: album.coverArt, size: .large, flexible: true)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: .black.opacity(isHovered ? 0.3 : 0.15), radius: isHovered ? 8 : 4)

                        if !isSeen {
                            Circle()
                                .fill(.blue)
                                .frame(width: 10, height: 10)
                                .padding(8)
                        }
                    }

                    Text(album.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .foregroundStyle(.primary)

                    Text(album.artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let voiceLine {
                        Text(voiceLine)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    onStage()
                } label: {
                    Label("Send to Waiting Room", systemImage: "tray")
                }
                Button {
                    onAdmit()
                } label: {
                    Label("Admit", systemImage: "checkmark.circle")
                }
                if !isSeen {
                    Divider()
                    Button {
                        onMarkSeen()
                    } label: {
                        Label("Mark Seen", systemImage: "eye")
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    onStage()
                } label: {
                    Image(systemName: "tray")
                }
                .help("Send to Waiting Room")
                .accessibilityLabel("Send to Waiting Room")

                Button {
                    onAdmit()
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help("Admit")
                .accessibilityLabel("Admit")

                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .onHover { isHovered = $0 }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .task(id: album.id) {
            voices = (try? appState.databaseManager.sourceVoices(forAlbumId: album.id)) ?? []
        }
    }

    /// One quiet provenance line: "via {source}" (+ short acquired date, + "+N"
    /// when the album's songs carry more than one distinct source voice).
    /// Renders nothing until the attribution data lane lands (stub returns []).
    private var voiceLine: String? {
        guard let first = voices.first else { return nil }
        let name = first.sourceDisplayName
            ?? first.downloadSource
            ?? first.sourceKind
        guard let name, !name.isEmpty else { return nil }

        var line = "via \(name)"
        if let acquired = Self.shortDate(from: first.acquiredAt) {
            line += " · \(acquired)"
        }
        let extra = voices.count - 1
        if extra > 0 {
            line += " +\(extra)"
        }
        return line
    }

    private static let isoFormatter = ISO8601DateFormatter()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func shortDate(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let date = isoFormatter.date(from: raw)
            ?? dayFormatter.date(from: String(raw.prefix(10)))
        guard let date else {
            // Unparseable but present: fall back to the leading date portion.
            let prefix = String(raw.prefix(10))
            return prefix.isEmpty ? nil : prefix
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
