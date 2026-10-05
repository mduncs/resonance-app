import SwiftUI

/// The One Plane surface: Listen and Library as distances on one continuous
/// zoomable plane, driven by a single interruptible `PlaneCamera`.
struct PlaneView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var camera = PlaneCamera()
    @State private var lanes: [PlaneLane] = []
    @State private var voiceNames: [String: String] = [:]
    /// Raw source voices kept so lanes can be rebuilt synchronously (e.g. after an
    /// optimistic admit) without another database read.
    @State private var voicesByAlbum: [String: [SourceAttributionRecord]] = [:]
    @State private var decorations: [String: PlaneAlbumDecoration] = [:]
    @State private var wearByAlbum: [String: Int] = [:]
    @State private var selectedAlbumId: String?
    /// Active project lens (PR-B): non-nil narrows the plane to the project's
    /// items. See `PlaneLens.swift`.
    @State private var lens: PlaneLens?
    @State private var showLensPalette = false
    /// Non-archived projects for the lens palette popover (loaded on open).
    @State private var lensPaletteProjects: [Project] = []
    @State private var objectSongs: [Song] = []
    @State private var loadingObject = false
    @State private var admitting = false
    @State private var lastMagnify: CGFloat = 1
    @State private var toastMessage: String?
    @State private var albumCatalogError: String?
    /// Bumped on every toast so a stale dismissal can't clear a newer message.
    @State private var toastToken = 0
    @FocusState private var isFocused: Bool

    private static let distanceNames = ["Constellation", "Shelf", "Object", "Player"]

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            // The camera settles and then stops ticking; any retarget flips
            // `isSettled` false, re-creates the schedule, and resumes the spring.
            // The spring step runs in `.onChange` (not in the body) so we never
            // mutate observed state during a view update.
            TimelineView(.animation(paused: camera.isSettled)) { context in
                strata
                    .onChange(of: context.date) { _, now in
                        camera.tick(now: now.timeIntervalSinceReferenceDate)
                    }
            }

            chrome
            hints
            toast
            if let albumCatalogError {
                CompactStatusView(
                    title: "Albums Unavailable",
                    systemImage: "square.stack",
                    message: albumCatalogError,
                    actionTitle: "Retry",
                    actionSystemImage: "arrow.clockwise"
                ) {
                    Task { await loadData() }
                }
                .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .gesture(pinch)
        .onKeyPress(action: handleKey)
        .onAppear {
            isFocused = true
            if reduceMotion { camera.snap(to: 1) }
        }
        .task(id: albumsFingerprint) { await loadData() }
        .onChange(of: selectedAlbumId) { _, _ in
            Task { await loadObjectSongs() }
        }
        // ⌘K HUD verbs write curation state from outside the plane's own
        // perform→refresh path; refresh so marks/admissions surface immediately.
        .onReceive(NotificationCenter.default.publisher(for: .resonanceCurationDidChange)) { _ in
            Task { await loadData() }
        }
        // Lens hand-off from the Projects room: apply a requested lens when the
        // plane is visible (onChange) or next appears (onAppear consume below is
        // covered by the same change firing once the store publishes).
        .onChange(of: PlaneLensStore.shared.requestedProjectId, initial: true) { _, requested in
            guard requested != nil, let projectId = PlaneLensStore.shared.consumeRequest() else { return }
            Task { await activateLens(projectId: projectId) }
        }
        // GI-B: publish near/far so ⌘I in `ResonanceApp` toggles the docked
        // evidence rail only at the Object/Player strata and falls back to the
        // Dossier Sheet at Constellation/Shelf.
        .onChange(of: roundedDistance) { _, distance in
            PlaneEvidenceRailController.shared.nearOnPlane = (distance >= 2)
        }
        .onAppear {
            PlaneEvidenceRailController.shared.nearOnPlane = (roundedDistance >= 2)
        }
    }

    // MARK: - Strata

    private var strata: some View {
        let z = camera.z
        return ZStack {
            stratumLayer(.plane, z: z) {
                PlaneStratumView(
                    lanes: lanes,
                    z: z,
                    nowPlayingAlbumId: appState.nowPlaying?.albumId,
                    selectedAlbumId: selectedAlbumId,
                    decorations: decorations,
                    wearByAlbum: wearByAlbum,
                    onSelect: select,
                    onPlay: play
                )
            }
            stratumLayer(.object, z: z) {
                PlaneObjectView(
                    album: selectedAlbum,
                    songs: objectSongs,
                    isLoading: loadingObject,
                    voiceName: selectedAlbumId.flatMap { voiceNames[$0] },
                    nowPlaying: appState.nowPlaying,
                    isOnAudition: selectedAlbumIsOnAudition,
                    onPlay: playSelected,
                    onAdmit: admitSelected
                )
            }
            stratumLayer(.player, z: z) {
                PlanePlayerView(onVerb: performDeckVerb)
            }
        }
    }

    private func stratumLayer<Content: View>(
        _ stratum: PlaneStratum,
        z: Double,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let presence = PlanePresence.presence(of: stratum, at: z)
        let interactive = PlanePresence.interactiveStratum(at: z) == stratum
        return content()
            .scaleEffect(presence.scale)
            .opacity(presence.opacity)
            .allowsHitTesting(interactive && presence.opacity > 0.01)
    }

    // MARK: - Chrome (now-playing pill + distance HUD)

    private var roundedDistance: Int {
        min(3, max(0, Int(camera.z.rounded())))
    }

    @ViewBuilder
    private var chrome: some View {
        VStack {
            HStack {
                lensControl
                Spacer()
                if roundedDistance < 3, let song = appState.nowPlaying {
                    nowPlayingPill(song)
                }
            }
            Spacer()
            HStack {
                Spacer()
                distanceHUD
            }
        }
        .padding(16)
    }

    // MARK: - Lens chrome (chip + palette)

    /// Top-left lens chrome: with a lens active, a chip naming the project
    /// (+N unresolved when references have no tile) with an ✕ to drop it; without
    /// one, a quiet scope button. Either opens the project palette.
    @ViewBuilder
    private var lensControl: some View {
        HStack(spacing: 6) {
            Button {
                openLensPalette()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "scope")
                        .font(.system(size: 10))
                        .foregroundStyle(lens == nil ? .secondary : Color.accentColor)
                    if let lens {
                        Text(lensChipTitle(lens))
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, lens == nil ? 8 : 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(
                    lens == nil ? AnyShapeStyle(.separator) : AnyShapeStyle(Color.accentColor.opacity(0.5)),
                    lineWidth: 1
                ))
            }
            .buttonStyle(.plain)
            .help(lens.map { "Lens: \($0.project.name) — switch project" } ?? "Scope the plane to a project")
            .accessibilityLabel(lens.map { "Lens active: \(lensChipTitle($0)). Switch project." }
                ?? "Project lens. Scope the plane to a project.")
            .popover(isPresented: $showLensPalette, arrowEdge: .bottom) {
                lensPalette
            }

            if lens != nil {
                Button {
                    clearLens()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Drop the lens (esc at Constellation)")
                .accessibilityLabel("Drop the project lens")
            }
        }
    }

    private func lensChipTitle(_ lens: PlaneLens) -> String {
        lens.unresolvedCount > 0
            ? "\(lens.project.name) +\(lens.unresolvedCount) unresolved"
            : lens.project.name
    }

    /// Palette rows grouped by lineage category: named lineages A→Z, then
    /// uncategorized projects last (mirrors ProjectsView's sectioning).
    private var lensPaletteSections: [(category: String?, projects: [Project])] {
        let grouped = Dictionary(grouping: lensPaletteProjects) { $0.category }
        let named = grouped.keys.compactMap { $0 }.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        var sections: [(category: String?, projects: [Project])] = named.map {
            (category: $0, projects: grouped[$0] ?? [])
        }
        if let uncategorized = grouped[nil], !uncategorized.isEmpty {
            sections.append((category: nil, projects: uncategorized))
        }
        return sections
    }

    private var lensPalette: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("PROJECT LENS")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)
            if lensPaletteProjects.isEmpty {
                Text("No projects yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else {
                ForEach(lensPaletteSections, id: \.category) { section in
                    // Category headers mirror the Projects master list —
                    // labels only, every project stays lens-selectable. A lone
                    // uncategorized section renders flat, as before.
                    if !(section.category == nil && lensPaletteSections.count == 1) {
                        Text((section.category ?? "Uncategorized").uppercased())
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            .tracking(1.0)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                    }
                    ForEach(section.projects) { project in
                        Button {
                            Task { await activateLens(projectId: project.id) }
                        } label: {
                            HStack {
                                Text(project.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                                if lens?.project.id == project.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if lens != nil {
                    Divider().padding(.vertical, 2)
                    Button {
                        clearLens()
                        showLensPalette = false
                    } label: {
                        Text("Drop lens")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(minWidth: 200)
        .padding(.bottom, lens == nil ? 6 : 0)
    }

    private func nowPlayingPill(_ song: Song) -> some View {
        Button {
            jump(to: 3)
        } label: {
            HStack(spacing: 8) {
                EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .miniBar, flexible: true)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                Text(song.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 200)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Now playing — fly to the Player")
        .accessibilityLabel("Now playing: \(song.title). Fly to the player.")
    }

    private var distanceHUD: some View {
        HStack(spacing: 9) {
            Text(Self.distanceNames[roundedDistance].uppercased())
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            ForEach(0..<4, id: \.self) { index in
                Button {
                    jump(to: Double(index))
                } label: {
                    Circle()
                        .fill(index == roundedDistance ? Color.accentColor : .clear)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(index == roundedDistance ? Color.accentColor : Color.secondary, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(Self.distanceNames[index])
                .accessibilityLabel(Self.distanceNames[index])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
    }

    private var hints: some View {
        VStack {
            Spacer()
            HStack {
                Text("pinch to glide · click to fly in · esc out · n = now playing · 1–4 jump")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(16)
        .allowsHitTesting(false)
    }

    // MARK: - Toast (deck verb confirmations)

    @ViewBuilder
    private var toast: some View {
        if let message = toastMessage {
            VStack {
                Spacer()
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
                    .padding(.bottom, 56)
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .transition(reduceMotion
                ? .opacity
                : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func showToast(_ message: String) {
        toastToken += 1
        let token = toastToken
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) {
            toastMessage = message
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard token == toastToken else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                toastMessage = nil
            }
        }
    }

    // MARK: - Decision deck

    /// The subject the deck acts on: the current now-playing song and its album.
    /// Built here so the deck buttons and the k/m/p/a key grammar share it.
    private var deckContext: CurationVerbContext {
        let song = appState.nowPlaying
        let album = song.flatMap { s in appState.albums.first(where: { $0.id == s.albumId }) }
        return CurationVerbContext(appState: appState, song: song, album: album)
    }

    /// Perform a deck verb, toast any confirmation, then refresh the plane so
    /// wu-wei effects (mark → tile glyph, admit → tile leaves the strip) appear.
    /// Stubs return a nil message today, so no toast fires until the real
    /// performs land — the refresh is harmless in the meantime.
    private func performDeckVerb(_ verb: CurationVerb) {
        let context = deckContext
        guard verb.isAvailable(context) else { return }
        reassertFocus()
        Task {
            let outcome = await verb.perform(context)
            if let message = outcome.message {
                showToast(message)
            }
            await loadData()
        }
    }

    // MARK: - Lens (PR-B)

    /// The albums the plane currently shows: everything, or the lens's subset.
    /// Filtering happens here — lane building, selection fallbacks, and the
    /// audition strip all read through this, so scoping is one code path.
    private var visibleAlbums: [Album] {
        guard let lens else { return appState.albums }
        return appState.albums.filter { lens.albumIds.contains($0.id) }
    }

    /// Resolve and apply a project lens, then settle at the Shelf so the scoped
    /// set is readable (labels + marks) without leaving the overview feel.
    private func activateLens(projectId: String) async {
        guard let serverId = appState.activeServerId else { return }
        let database = appState.databaseManager
        let albums = appState.albums

        let resolved = await Task.detached(priority: .userInitiated) { () -> PlaneLens? in
            guard let project = (try? database.loadProjects(serverId: serverId, includeArchived: true))?
                .first(where: { $0.id == projectId })
            else { return nil }
            let items = (try? database.loadProjectItems(projectId: projectId, serverId: serverId)) ?? []
            let songs = (try? database.loadProjectSongs(projectId: projectId, serverId: serverId)) ?? []
            return PlaneLensResolver.resolve(project: project, items: items, resolvedSongs: songs, albums: albums)
        }.value

        guard let resolved else { return }
        lens = resolved
        rebuildLanes()
        // Keep the Object subject inside the lens so flying in never shows an
        // album the lens excludes.
        if let id = selectedAlbumId, !resolved.albumIds.contains(id) {
            selectedAlbumId = visibleAlbums.first?.id
        }
        showLensPalette = false
        reassertFocus()
        jump(to: 1)
    }

    /// Re-resolve the active lens against current items/albums (curation writes
    /// can add or admit project items while the lens is up).
    private func refreshLens() async {
        guard let current = lens else { return }
        await activateLensQuietly(projectId: current.project.id)
    }

    /// `activateLens` minus the camera/selection side effects — used by refresh
    /// so a background reconcile never yanks the camera.
    private func activateLensQuietly(projectId: String) async {
        guard let serverId = appState.activeServerId else { return }
        let database = appState.databaseManager
        let albums = appState.albums

        let resolved = await Task.detached(priority: .userInitiated) { () -> PlaneLens? in
            guard let project = (try? database.loadProjects(serverId: serverId, includeArchived: true))?
                .first(where: { $0.id == projectId })
            else { return nil }
            let items = (try? database.loadProjectItems(projectId: projectId, serverId: serverId)) ?? []
            let songs = (try? database.loadProjectSongs(projectId: projectId, serverId: serverId)) ?? []
            return PlaneLensResolver.resolve(project: project, items: items, resolvedSongs: songs, albums: albums)
        }.value

        if let resolved { lens = resolved }
    }

    private func clearLens() {
        guard lens != nil else { return }
        lens = nil
        rebuildLanes()
        if selectedAlbumId == nil || appState.albums.first(where: { $0.id == selectedAlbumId }) == nil {
            selectedAlbumId = appState.nowPlaying?.albumId ?? appState.albums.first?.id
        }
        reassertFocus()
    }

    private func openLensPalette() {
        guard let serverId = appState.activeServerId else { return }
        lensPaletteProjects = (try? appState.databaseManager.loadProjects(serverId: serverId)) ?? []
        showLensPalette = true
    }

    // MARK: - Selection & playback

    private var selectedAlbum: Album? {
        if let id = selectedAlbumId, let match = appState.albums.first(where: { $0.id == id }) {
            return match
        }
        return visibleAlbums.first
    }

    private var selectedAlbumIsOnAudition: Bool {
        guard let id = selectedAlbumId else { return false }
        return decorations[id]?.onAudition == true
    }

    private func select(_ album: Album) {
        selectedAlbumId = album.id
        reassertFocus()
        markDiscoverySeen(album)
        jump(to: 2)
    }

    private func play(_ album: Album) {
        selectedAlbumId = album.id
        reassertFocus()
        markDiscoverySeen(album)
        Task {
            let songs = (try? await appState.playableAlbumSongs(for: album)) ?? []
            await appState.playbackManager.play(songs: songs)
        }
        jump(to: 3)
    }

    private func playSelected(fromTrack index: Int) {
        let songs = objectSongs
        guard !songs.isEmpty else { return }
        let start = min(max(0, index), songs.count - 1)
        Task { await appState.playbackManager.play(songs: songs, startingAt: start) }
        jump(to: 3)
    }

    /// Wu-wei seen-marking (NM-2): flying into a freshly-discovered album clears
    /// its Growing Edge glow. Updates the local decoration optimistically so the
    /// glow fades without a reload thrash, and persists the seen flag. No
    /// `resonanceCurationDidChange` post here — the local update already reflects
    /// it, and posting would race the async write and briefly resurrect the glow.
    private func markDiscoverySeen(_ album: Album) {
        guard let serverId = appState.activeServerId,
              let decoration = decorations[album.id],
              decoration.discoveredAt != nil,
              !decoration.isSeenDiscovery
        else { return }

        var updated = decoration
        updated.isSeenDiscovery = true
        decorations[album.id] = updated
        try? appState.databaseManager.markDiscoverySeen(albumId: album.id, serverId: serverId)
        // Keep the sidebar badge honest — it otherwise only recomputes on the
        // next library-refresh pass.
        appState.unseenDiscoveryCount = (try? appState.databaseManager.unseenDiscoveryCount(serverId: serverId)) ?? 0
    }

    // OP-1 gap: a tile/track click steals key focus from the plane, so esc and the
    // 1–4/n grammar stopped working without a re-click. Re-assert focus after the
    // click resolves (async so we win the focus back after the gesture settles).
    private func reassertFocus() {
        isFocused = true
        DispatchQueue.main.async { isFocused = true }
    }

    // MARK: - Admit (Salon projection → library)

    /// Admit the selected audition album's songs, mirroring the release-level verb
    /// in `DiscoveryFeedView`. The tile leaves the dashed strip and rejoins its
    /// source lane; the camera stays at the Object (admitting is not travel).
    private func admitSelected() {
        guard !admitting,
              let album = selectedAlbum,
              let serverId = appState.activeServerId,
              decorations[album.id]?.onAudition == true
        else { return }

        admitting = true

        // Optimistic: drop the album out of audition and re-lane immediately so
        // the strip empties without waiting on the round-trip.
        if var decoration = decorations[album.id] {
            decoration.onAudition = false
            decorations[album.id] = decoration
        }
        rebuildLanes()
        reassertFocus()

        Task {
            defer { admitting = false }
            do {
                let songs = try await appState.networkActor.fetchAlbumSongs(albumId: album.id)
                for song in songs {
                    try appState.databaseManager.admitSongAndRelated(
                        song,
                        serverId: serverId,
                        admittedBy: .manual,
                        sourceDetail: "one_plane_audition"
                    )
                    try appState.databaseManager.upsertWaitingRoomItem(
                        song: song,
                        serverId: serverId,
                        state: .admitted,
                        source: "one_plane_admit"
                    )
                    try appState.databaseManager.setWaitingRoomState(songId: song.id, serverId: serverId, state: .admitted)
                }
                appState.refreshLibraryMembershipIds()
                await loadData()
            } catch {
                // Reconcile against the source of truth on failure (restores the
                // strip if the admit did not take).
                await loadData()
            }
        }
    }

    // MARK: - Camera input

    private func jump(to distance: Double) {
        if reduceMotion {
            camera.snap(to: distance)
        } else {
            camera.setTarget(distance)
        }
    }

    private func stepIn() { jump(to: camera.target.rounded() + 1) }
    private func stepOut() { jump(to: camera.target.rounded() - 1) }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let delta = Double(value.magnification - lastMagnify)
                lastMagnify = value.magnification
                camera.nudgeTarget(by: delta * 3.5)
                if reduceMotion { camera.snap(to: camera.target) }
            }
            .onEnded { _ in
                lastMagnify = 1
                camera.settleToNearest()
                if reduceMotion { camera.snap(to: camera.target) }
            }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape {
            // Esc keeps its pull-back meaning at every nearer distance; only at
            // Constellation — where there is nothing further to pull back from —
            // does it drop the active lens (PR-B).
            if lens != nil && roundedDistance == 0 {
                clearLens()
            } else {
                stepOut()
            }
            return .handled
        }
        // At the Player distance only, bare k/m/p/a trigger the matching deck
        // verb (matched to its keyHint). Kept off the other distances so it never
        // collides with the esc/=/-/n/1–4 travel grammar (none of which use those
        // letters, and `n`/`N` still flies home from here since it isn't a deck key).
        if PlanePresence.interactiveStratum(at: camera.z) == .player {
            let pressed = press.characters.uppercased()
            if !pressed.isEmpty,
               let verb = CurationVerbRegistry.deckVerbs().first(where: {
                   $0.keyHint?.uppercased() == pressed
               }) {
                performDeckVerb(verb)
                return .handled
            }
        }
        switch press.characters {
        case "=", "+": stepIn()
        case "-", "_": stepOut()
        case "n", "N": jump(to: 3)
        case "1": jump(to: 0)
        case "2": jump(to: 1)
        case "3": jump(to: 2)
        case "4": jump(to: 3)
        default: return .ignored
        }
        return .handled
    }

    // MARK: - Data

    /// Changes when the album set changes, re-triggering the lane rebuild.
    private var albumsFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(appState.activeServer?.id)
        hasher.combine(appState.fullAlbumCatalogServerID)
        hasher.combine(appState.albums.count)
        hasher.combine(appState.albums.first?.id)
        hasher.combine(appState.albums.last?.id)
        return hasher.finalize()
    }

    /// Bulk-resolve source voices and curation decorations off the main actor,
    /// then publish them together and build the lanes. The two reads share one
    /// detached hop so the plane never shows voices without their decorations.
    private func loadData() async {
        guard let expectedServerID = appState.activeServer?.id else {
            lanes = []
            return
        }
        do {
            try await appState.ensureFullAlbumCatalog(expectedServerID: expectedServerID)
            albumCatalogError = nil
        } catch is CancellationError {
            return
        } catch {
            guard appState.activeServer?.id == expectedServerID else { return }
            albumCatalogError = error.localizedDescription
            return
        }
        guard !Task.isCancelled, appState.activeServer?.id == expectedServerID else { return }
        let albums = appState.albums
        let database = appState.databaseManager
        let ids = albums.map(\.id)

        let resolved = await Task.detached(priority: .userInitiated) {
            () -> (voices: [String: [SourceAttributionRecord]], decorations: [String: PlaneAlbumDecoration]) in
            let voices = (try? database.sourceVoicesByAlbum(forAlbumIds: ids)) ?? [:]
            let decorations = (try? database.planeDecorations(forAlbumIds: ids)) ?? [:]
            return (voices, decorations)
        }.value

        guard !Task.isCancelled, appState.activeServer?.id == expectedServerID else { return }

        voicesByAlbum = resolved.voices
        decorations = resolved.decorations
        wearByAlbum = PlaneWear.tiers(decorations: resolved.decorations)
        // Lens membership can drift under curation writes (items added, admits);
        // reconcile it in the same pass so the rebuilt lanes never show a stale
        // scope. Quiet: never moves the camera or selection.
        await refreshLens()
        rebuildLanes()

        if selectedAlbumId == nil || appState.albums.first(where: { $0.id == selectedAlbumId }) == nil {
            selectedAlbumId = appState.nowPlaying?.albumId ?? visibleAlbums.first?.id ?? albums.first?.id
        }
    }

    /// Rebuild the lanes from already-published state — pure and synchronous so an
    /// optimistic admit can re-lane instantly without another database read. Reads
    /// through `visibleAlbums`, so an active lens (PR-B) scopes both the source
    /// lanes and the audition strip in this one place.
    private func rebuildLanes() {
        let result = PlaneLaneBuilder.build(
            albums: visibleAlbums,
            voicesByAlbum: voicesByAlbum,
            decorations: decorations
        )
        lanes = result.lanes
        voiceNames = result.voiceNames
    }

    private func loadObjectSongs() async {
        guard let album = selectedAlbum else {
            objectSongs = []
            return
        }
        loadingObject = true
        defer { loadingObject = false }
        objectSongs = (try? await appState.playableAlbumSongs(for: album)) ?? []
    }
}

#Preview {
    PlaneView()
        .environment(AppState())
        .frame(width: 1100, height: 720)
}
