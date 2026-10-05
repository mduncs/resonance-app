import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Transferable wrapper for playlist song drag & drop
struct PlaylistSongTransfer: Codable, Transferable {
    let entryID: UUID  // Identifies an occurrence, not a potentially repeated song.

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .playlistSong)
    }
}

extension UTType {
    static var playlistSong: UTType {
        UTType(exportedAs: "com.resonance.playlist-song")
    }
}

/// A playlist occurrence has its own identity because the same song may appear
/// more than once. Server order and duplicate entries must survive filtering.
struct PlaylistSongEntry: Identifiable, Sendable {
    let id: UUID
    let song: Song

    init(id: UUID = UUID(), song: Song) {
        self.id = id
        self.song = song
    }
}

enum PlaylistVisibilityProjection {
    static func visibleEntries(
        from entries: [PlaylistSongEntry],
        hiddenSongIDs: Set<String>,
        hiddenAlbumIDs: Set<String>,
        hiddenArtistIDs: Set<String>
    ) -> [PlaylistSongEntry] {
        entries.filter { entry in
            !hiddenSongIDs.contains(entry.song.id)
                && !hiddenAlbumIDs.contains(entry.song.albumId)
                && !hiddenArtistIDs.contains(entry.song.artistId)
        }
    }
}

/// Cached find projection. `matchingEntries` is deliberately complete while
/// `displayedEntries` is bounded so a 50k-entry playlist never becomes 50k
/// SwiftUI row values just because the user opened it.
struct PlaylistFindProjection {
    let matchingEntries: [PlaylistSongEntry]
    let displayedEntries: [PlaylistSongEntry]
    let sourceIndexByID: [UUID: Int]
    let matchingIndexByID: [UUID: Int]

    static func make(entries: [PlaylistSongEntry], hiddenSongIDs: Set<String>, hiddenAlbumIDs: Set<String>, hiddenArtistIDs: Set<String>, query: String, limit: Int) -> PlaylistFindProjection {
        let visible = PlaylistVisibilityProjection.visibleEntries(from: entries, hiddenSongIDs: hiddenSongIDs, hiddenAlbumIDs: hiddenAlbumIDs, hiddenArtistIDs: hiddenArtistIDs)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = needle.isEmpty ? visible : visible.filter {
            $0.song.title.localizedCaseInsensitiveContains(needle)
                || $0.song.artist.localizedCaseInsensitiveContains(needle)
                || $0.song.album.localizedCaseInsensitiveContains(needle)
        }
        return PlaylistFindProjection(
            matchingEntries: matching,
            displayedEntries: Array(matching.prefix(limit)),
            sourceIndexByID: Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) }),
            matchingIndexByID: Dictionary(uniqueKeysWithValues: matching.enumerated().map { ($0.element.id, $0.offset) })
        )
    }
}

struct PlaylistDetailView: View {
    @Environment(AppState.self) private var appState
    let playlist: Playlist

    // Keep server positions intact even when local visibility hides entries.
    @State private var entries: [PlaylistSongEntry] = []
    // Project once when source entries or cached hidden-ID sets change. Computing
    // this from body used to perform three synchronous DB reads and several
    // whole-array copies every time SwiftUI reevaluated a large playlist.
    @State private var visibleEntries: [PlaylistSongEntry] = []
    @State private var displayedEntries: [PlaylistSongEntry] = []
    @State private var sourceIndexByID: [UUID: Int] = [:]
    @State private var matchingIndexByID: [UUID: Int] = [:]
    @State private var matchingEntryIDs: [UUID] = []
    @State private var searchText = ""
    @State private var displayLimit = 500
    @State private var trackSelection = OrderedItemSelection<UUID>()
    @State private var selectedOccurrenceEntries: [PlaylistSongEntry] = []
    @State private var songs: [Song] = []
    @State private var visibleDuration = 0
    @State private var loadedServerID: UUID?
    @State private var loadGeneration = UUID()
    @State private var isEditing = false
    @State private var isLoading = true
    @State private var loadError: ResonanceError?
    @State private var isSavingOrder = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                PlaylistHeaderView(
                    playlist: playlist,
                    songs: songs,
                    loadedDuration: visibleDuration,
                    onPlay: { playSongs(shuffled: false) },
                    onShuffle: { playSongs(shuffled: true) }
                )

                Divider()
                    .padding(.horizontal)

                // Track list
                if isLoading {
                    InlineLoadingStatusView(title: "Loading songs...")
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .frame(minHeight: 260)
                } else if let error = loadError {
                    CompactStatusView(
                        title: error.errorTitle,
                        systemImage: error.systemImage,
                        message: error.errorDescription ?? "Playlist songs could not be loaded.",
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise",
                        action: {
                            Task { await loadSongs() }
                        }
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                } else if visibleEntries.isEmpty {
                    CompactStatusView(
                        title: "No Songs",
                        systemImage: "music.note.list",
                        message: "This playlist does not contain any visible songs."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(displayedEntries) { entry in
                            let song = entry.song
                            Button {
                                select(entry.id, modifiers: NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
                            } label: {
                            HStack(spacing: 12) {
                                if isEditing {
                                    Image(systemName: "line.3.horizontal")
                                        .foregroundStyle(.secondary)
                                }

                                SongRow(song: song, showTrackNumber: false)
                            }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .background(trackSelection.selectedIDs.contains(entry.id) ? Color.accentColor.opacity(0.1) : .clear)
                            .focusable()
                            .onTapGesture(count: 2) {
                                guard !isEditing else { return }
                                guard let index = matchingIndexByID[entry.id] else {
                                    return
                                }
                                Task {
                                    await appState.playbackManager.play(songs: songs, startingAt: index)
                                }
                            }
                            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                                moveSelection(by: press.key == .upArrow ? -1 : 1,
                                              extending: press.modifiers.contains(.shift))
                                return .handled
                            }
                            .onKeyPress("a", phases: .down) { press in
                                guard press.modifiers == .command else { return .ignored }
                                selectAllMatchingEntries()
                                return .handled
                            }
                            .onKeyPress(.return) {
                                playFocusedEntry()
                                return .handled
                            }
                            .accessibilityAddTraits(trackSelection.selectedIDs.contains(entry.id) ? .isSelected : [])
                            .contextMenu {
                                if trackSelection.selectedIDs.contains(entry.id), selectedOccurrenceEntries.count > 1 {
                                    BulkSongContextMenu(songs: selectedOccurrenceEntries.map(\.song))
                                } else {
                                    SongContextMenu(song: song)
                                }

                                Divider()

                                Button(role: .destructive) {
                                    Task {
                                        if trackSelection.selectedIDs.contains(entry.id), selectedOccurrenceEntries.count > 1 {
                                            await removeSelectedEntries()
                                        } else {
                                            await removeSongFromPlaylist(entryID: entry.id)
                                        }
                                    }
                                } label: {
                                    Label(trackSelection.selectedIDs.contains(entry.id) && selectedOccurrenceEntries.count > 1
                                          ? "Remove \(selectedOccurrenceEntries.count) from Playlist" : "Remove from Playlist",
                                          systemImage: "minus.circle")
                                }
                            }
                            .draggable(PlaylistSongTransfer(entryID: entry.id)) {
                                // Drag preview
                                SongRow(song: song, showTrackNumber: false)
                                    .frame(width: 280)
                                    .background(.regularMaterial)
                                    .cornerRadius(8)
                            }
                            .dropDestination(for: PlaylistSongTransfer.self) { items, _ in
                                guard !isSavingOrder, !isLoading,
                                      loadedServerID == appState.activeServer?.id else { return false }
                                guard let transfer = items.first,
                                      let currentSourceIndex = sourceIndexByID[transfer.entryID],
                                      let destIndex = sourceIndexByID[entry.id] else {
                                    return false
                                }

                                if currentSourceIndex != destIndex {
                                    // Move using IndexSet API (adjusts for "insert before" semantics)
                                    let adjustedDest = destIndex > currentSourceIndex ? destIndex + 1 : destIndex
                                    entries.move(fromOffsets: IndexSet(integer: currentSourceIndex), toOffset: adjustedDest)
                                    refreshVisibleEntries()
                                    savePlaylistOrder()
                                }
                                return true
                            } isTargeted: { isTargeted in
                                // Could add visual feedback here
                            }

                            if entry.id != displayedEntries.last?.id {
                                Divider()
                                    .padding(.leading, isEditing ? 62 : 50)
                            }
                        }
                    }
                    .padding(.horizontal)
                    if displayedEntries.count < visibleEntries.count {
                        Button("Load More") {
                            displayLimit += 500
                            refreshVisibleEntries()
                        }
                            .padding()
                    }
                }
            }
        }
        .task(id: appState.activeServerId) {
            await loadSongs()
        }
#if DEBUG
        .onAppear {
            if DeterministicCaptureFixture.isAtlasEnabled {
                ParityControlBridge.shared.detailSelectionSnapshot = { [self] in
                    let ordered = displayedEntries
                    return ["kind": "playlist", "orderedSongIDs": ordered.map(\.song.id),
                            "selectedIndices": ordered.indices.filter { trackSelection.selectedIDs.contains(ordered[$0].id) },
                            "focusedIndex": trackSelection.focusedID.flatMap { focus in
                                ordered.firstIndex(where: { $0.id == focus })
                            } ?? NSNull() as Any]
                }
            }
        }
#endif
        .onChange(of: appState.hiddenSongIds) { _, _ in refreshVisibleEntries() }
        .onChange(of: appState.hiddenAlbumIds) { _, _ in refreshVisibleEntries() }
        .onChange(of: appState.hiddenArtistIds) { _, _ in refreshVisibleEntries() }
        .onDisappear {
            loadGeneration = UUID()
#if DEBUG
            if DeterministicCaptureFixture.isAtlasEnabled {
                ParityControlBridge.shared.detailSelectionSnapshot = nil
            }
#endif
        }
        .navigationTitle(playlist.name)
        .searchable(text: $searchText, prompt: "Find in Playlist")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isEditing.toggle()
                } label: {
                    Text(isEditing ? "Done" : "Edit")
                }
            }
        }
        .onChange(of: searchText) { _, _ in
            displayLimit = 500
            refreshVisibleEntries()
        }
    }

    // MARK: - Actions

    private func loadSongs() async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        loadGeneration = generation
        let serverID = appState.activeServer?.id
        if loadedServerID != serverID {
            entries = []
            refreshVisibleEntries()
        }
        loadedServerID = serverID
        isLoading = true
        loadError = nil
        defer {
            if loadGeneration == generation { isLoading = false }
        }
        guard let serverID else {
            entries = []
            return
        }
        do {
            let fetchedSongs = try await appState.networkActor.fetchPlaylistSongs(
                playlistId: playlist.id, expectedServerID: serverID
            )
            guard !Task.isCancelled, loadGeneration == generation,
                  appState.activeServer?.id == serverID else { return }
            entries = fetchedSongs.map { PlaylistSongEntry(song: $0) }
            refreshVisibleEntries()
        } catch {
            guard !Task.isCancelled, loadGeneration == generation,
                  appState.activeServer?.id == serverID else { return }
            loadError = (error as? ResonanceError) ?? .unknown(error)
        }
    }

    private func playSongs(shuffled: Bool) {
        guard !songs.isEmpty else { return }
        Task {
            if shuffled {
                await appState.playbackManager.play(songs: songs.shuffled())
            } else {
                await appState.playbackManager.play(songs: songs)
            }
        }
    }

    private func select(_ entryID: UUID, modifiers: NSEvent.ModifierFlags) {
        trackSelection.click(entryID, in: matchingEntryIDs,
                             extending: modifiers.contains(.shift),
                             toggling: modifiers.contains(.command))
        refreshSelectedEntries()
    }

    private func moveSelection(by offset: Int, extending: Bool) {
        _ = trackSelection.moveFocus(by: offset, in: matchingEntryIDs, extending: extending)
        refreshSelectedEntries()
    }

    private func selectAllMatchingEntries() {
        trackSelection.selectAll(in: matchingEntryIDs)
        refreshSelectedEntries()
    }

    private func playFocusedEntry() {
        guard let id = trackSelection.focusedID, let index = matchingIndexByID[id] else { return }
        Task { await appState.playbackManager.play(songs: songs, startingAt: index) }
    }

    private func savePlaylistOrder() {
        guard !isSavingOrder, !isLoading,
              let serverID = loadedServerID,
              serverID == appState.activeServer?.id else { return }
        isSavingOrder = true
        let orderSnapshot = entries.map(\.song)
        Task {
            defer { isSavingOrder = false }
            do {
                // One full-order request, including hidden entries and duplicates.
                // Do not clear the playlist in a separate request first.
                try await appState.networkActor.replacePlaylistSongs(
                    id: playlist.id,
                    songIds: orderSnapshot.map(\.id),
                    expectedServerID: serverID
                )
            } catch {
                guard appState.activeServer?.id == serverID else { return }
                appState.showFeedback(
                    message: "Couldn't save playlist order",
                    detail: "Reloading the playlist from the server.",
                    style: .error,
                    systemImage: "exclamationmark.triangle"
                )
                await loadSongs()
            }
        }
    }

    private func removeSongFromPlaylist(entryID: UUID) async {
        guard !isSavingOrder, !isLoading,
              let serverID = loadedServerID,
              serverID == appState.activeServer?.id,
              let serverIndex = sourceIndexByID[entryID] else { return }
        let removedSong = entries[serverIndex].song
        isSavingOrder = true
        defer { isSavingOrder = false }

        do {
            try await appState.networkActor.updatePlaylist(
                id: playlist.id,
                songIndexesToRemove: [serverIndex],
                expectedServerID: serverID
            )
            guard !Task.isCancelled, appState.activeServer?.id == serverID else { return }
            entries.removeAll { $0.id == entryID }
            refreshVisibleEntries()
        } catch is CancellationError {
            return
        } catch {
            guard appState.activeServer?.id == serverID else { return }
            appState.showFeedback(
                message: "Couldn't remove \"\(removedSong.title)\"",
                detail: "Reloading the playlist from the server.",
                style: .error,
                systemImage: "exclamationmark.triangle"
            )
            await loadSongs()
        }
    }

    private func removeSelectedEntries() async {
        guard !isSavingOrder, !isLoading,
              let serverID = loadedServerID,
              serverID == appState.activeServer?.id else { return }
        let selected = selectedOccurrenceEntries
        let indexes = selected.compactMap { sourceIndexByID[$0.id] }.sorted(by: >)
        guard !indexes.isEmpty else { return }
        isSavingOrder = true
        defer { isSavingOrder = false }
        do {
            try await appState.networkActor.updatePlaylist(
                id: playlist.id, songIndexesToRemove: indexes, expectedServerID: serverID
            )
            guard !Task.isCancelled, appState.activeServer?.id == serverID else { return }
            let removedIDs = Set(selected.map(\.id))
            entries.removeAll { removedIDs.contains($0.id) }
            refreshVisibleEntries()
        } catch is CancellationError {
            return
        } catch {
            guard appState.activeServer?.id == serverID else { return }
            appState.showFeedback(message: "Couldn't remove selected songs",
                                  detail: "Reloading the playlist from the server.",
                                  style: .error, systemImage: "exclamationmark.triangle")
            await loadSongs()
        }
    }

    private func refreshVisibleEntries() {
        let projection = PlaylistFindProjection.make(
            entries: entries,
            hiddenSongIDs: appState.hiddenSongIds,
            hiddenAlbumIDs: appState.hiddenAlbumIds,
            hiddenArtistIDs: appState.hiddenArtistIds,
            query: searchText,
            limit: displayLimit
        )
        visibleEntries = projection.matchingEntries
        displayedEntries = projection.displayedEntries
        sourceIndexByID = projection.sourceIndexByID
        matchingIndexByID = projection.matchingIndexByID
        matchingEntryIDs = projection.matchingEntries.map(\.id)
        trackSelection.prune(to: matchingEntryIDs)
        refreshSelectedEntries()
        songs = visibleEntries.map(\.song)
        visibleDuration = songs.reduce(into: 0) { $0 += $1.duration }
    }

    private func refreshSelectedEntries() {
        let byID = Dictionary(uniqueKeysWithValues: visibleEntries.map { ($0.id, $0) })
        selectedOccurrenceEntries = trackSelection.idsInDisplayOrder(matchingEntryIDs).compactMap { byID[$0] }
    }

}

struct PlaylistHeaderView: View {
    let playlist: Playlist
    let songs: [Song]
    let loadedDuration: Int
    var onPlay: () -> Void = {}
    var onShuffle: () -> Void = {}

    /// Prefer the freshly loaded song list over stale collection metadata.
    private var headerDurationText: String {
        guard !songs.isEmpty else { return playlist.formattedDuration }
        let hours = loadedDuration / 3600
        let minutes = (loadedDuration % 3600) / 60
        return hours > 0 ? "\(hours) hr \(minutes) min" : "\(minutes) min"
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            // Playlist art
            EnvironmentAlbumArtView(coverArtId: playlist.coverArt, size: .large)
                .frame(width: 200, height: 200)
                .cornerRadius(8)
                .shadow(radius: 10)

            VStack(alignment: .leading, spacing: 8) {
                Text("Playlist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(playlist.name)
                    .font(.largeTitle)
                    .fontWeight(.bold)

                if let comment = playlist.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(songs.isEmpty ? "\(playlist.songCount) songs" : "\(songs.count) songs")
                    Text("•")
                    Text(headerDurationText)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if !playlist.owner.isEmpty {
                    Text("By \(playlist.owner)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        onPlay()
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(songs.isEmpty)

                    Button {
                        onShuffle()
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(songs.isEmpty)
                }
            }

            Spacer()
        }
        .padding(24)
    }
}

#Preview {
    NavigationStack {
        PlaylistDetailView(playlist: .placeholder)
            .environment(AppState())
    }
}
