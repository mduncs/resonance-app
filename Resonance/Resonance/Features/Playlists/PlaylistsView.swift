import SwiftUI
import AppKit

struct PlaylistsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewState: ViewState = .loading
    @State private var showingCreateSheet = false
    @State private var loadGeneration = UUID()
    @State private var query = ""
    @State private var sort: PlaylistBrowserSort = .name
    @State private var matches: [Playlist] = []
    @State private var matchingPlaylistIDs: [String] = []
    @State private var displayLimit = 200
    @State private var selection = OrderedItemSelection<String>()
    @State private var usesList = false
    @State private var queueTask: Task<Void, Never>?
    @State private var isPreparingQueue = false

    enum ViewState {
        case loading
        case empty
        case error(ResonanceError)
        case populated
    }

    private var presentationState: ViewState {
        switch viewState {
        case .empty, .populated:
            // Create/edit sheets and delete actions update the shared array.
            // Derive settled presentation instead of retaining an old count.
            return appState.playlists.isEmpty ? .empty : .populated
        case .loading, .error:
            return viewState
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Apple Music-style page header
            HStack(alignment: .center) {
                Text("Playlists")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Spacer()

                Button {
                    showingCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Create Playlist")
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            HStack(spacing: 12) {
                Picker("Sort", selection: $sort) {
                    ForEach(PlaylistBrowserSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 180)
                Spacer()
                Picker("View", selection: $usesList) {
                    Image(systemName: "square.grid.2x2").tag(false)
                    Image(systemName: "list.bullet").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 72)
            }
            .padding(.horizontal, 29)

            // Content
            Group {
                switch presentationState {
                case .loading:
                    InlineLoadingStatusView(title: "Loading playlists...")
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                case .empty:
                    CompactStatusView(
                        title: "No Playlists",
                        systemImage: "music.note.list",
                        message: "Create a playlist to organize your music.",
                        actionTitle: "Create Playlist",
                        actionSystemImage: "plus",
                        action: {
                            showingCreateSheet = true
                        }
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .error(let error):
                    CompactStatusView(
                        title: error.errorTitle,
                        systemImage: error.systemImage,
                        message: error.errorDescription ?? "Playlists could not be loaded.",
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise",
                        action: {
                            Task { await loadPlaylists() }
                        }
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .populated:
                    if matches.isEmpty {
                        ContentUnavailableView("No Matching Playlists", systemImage: "magnifyingglass",
                            description: Text("Try another search."))
                    } else if usesList {
                        VStack(spacing: 0) {
                            List(selection: nativeSelection) {
                                ForEach(displayedMatches) { playlist in
                                    PlaylistRow(playlist: playlist).tag(playlist.id)
                                        .onTapGesture(count: 2) { open(playlist) }
                                        .contextMenu { playlistMenu(for: playlist) }
                                }
                            }
                            if displayLimit < matches.count { loadMoreButton }
                        }
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 247, maximum: 247), spacing: 10)], spacing: 0) {
                                ForEach(displayedMatches) { playlist in
                                    Button { select(playlist.id, modifiers: NSApp.currentEvent?.modifierFlags ?? []) } label: {
                                        PlaylistCollectionCard(playlist: playlist)
                                            .background(selection.selectedIDs.contains(playlist.id) ? Color.accentColor.opacity(0.12) : .clear)
                                    }
                                    .buttonStyle(.plain)
                                    .onTapGesture(count: 2) { open(playlist) }
                                    .accessibilityAddTraits(selection.selectedIDs.contains(playlist.id) ? .isSelected : [])
                                    .contextMenu { playlistMenu(for: playlist) }
                                }
                            }
                            .padding(.horizontal, 29)
                            if displayLimit < matches.count { loadMoreButton }
                        }
                        .frame(minHeight: 300)
                    }
                }
            }
        }
        .navigationTitle("")
        .searchable(text: $query, prompt: "Find a playlist")
        .sheet(isPresented: $showingCreateSheet) {
            CreatePlaylistSheet()
        }
        .confirmationDialog(
            "Delete Playlist?",
            isPresented: Binding(
                get: { appState.deletePlaylistTarget != nil },
                set: { if !$0 { appState.deletePlaylistTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let playlist = appState.deletePlaylistTarget {
                    Task {
                        await deletePlaylist(playlist)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                appState.deletePlaylistTarget = nil
            }
        } message: {
            if let playlist = appState.deletePlaylistTarget {
                Text("Are you sure you want to delete \"\(playlist.name)\"? This cannot be undone.")
            }
        }
        .task(id: appState.activeServerId) {
            await loadPlaylists()
        }
        .onChange(of: query) { _, _ in refreshProjection() }
        .onChange(of: sort) { _, _ in refreshProjection() }
        .onChange(of: appState.playlists) { _, _ in refreshProjection() }
        .onKeyPress("a", phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            selection.selectAll(in: matchingPlaylistIDs)
            return .handled
        }
        .onKeyPress(.return) { openFocusedPlaylist(); return .handled }
        .onDisappear {
            loadGeneration = UUID()
            queueTask?.cancel()
        }
    }

    private func deletePlaylist(_ playlist: Playlist) async {
        do {
            try await appState.networkActor.deletePlaylist(id: playlist.id)
            await MainActor.run {
                appState.playlists.removeAll { $0.id == playlist.id }
                refreshProjection()
                appState.deletePlaylistTarget = nil
            }
        } catch {
            await MainActor.run {
                appState.deletePlaylistTarget = nil
                appState.showFeedback(
                    message: "Couldn't delete \"\(playlist.name)\"",
                    detail: error.localizedDescription,
                    style: .error,
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    private func loadPlaylists() async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        loadGeneration = generation
        viewState = .loading
        selection = OrderedItemSelection<String>()
        queueTask?.cancel()
        guard let serverID = appState.activeServer?.id else {
            appState.playlists = []
            viewState = .empty
            return
        }
        do {
            let playlists = try await appState.networkActor.fetchPlaylists(expectedServerID: serverID)
            guard !Task.isCancelled, generation == loadGeneration,
                  appState.activeServer?.id == serverID else { return }
            appState.playlists = playlists
            refreshProjection()
            viewState = playlists.isEmpty ? .empty : .populated
        } catch {
            guard !Task.isCancelled, generation == loadGeneration,
                  appState.activeServer?.id == serverID else { return }
            viewState = .error((error as? ResonanceError) ?? .networkUnavailable)
        }
    }

    private var nativeSelection: Binding<Set<String>> {
        Binding(get: { selection.selectedIDs.intersection(Set(displayedMatches.map(\.id))) }, set: { ids in
            selection.acceptNativeSelection(ids, in: matchingPlaylistIDs,
                loadedIDs: Set(displayedMatches.map(\.id)),
                additive: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        })
    }

    private var loadMoreButton: some View {
        Button("Load More (\(min(displayLimit, matches.count)) of \(matches.count))") { displayLimit += 200 }
            .padding().frame(maxWidth: .infinity)
    }

    private func addSelectedToQueue() {
        guard !isPreparingQueue, let serverID = appState.activeServer?.id else { return }
        let targets = selection.idsInDisplayOrder(matchingPlaylistIDs)
        let generation = loadGeneration
        isPreparingQueue = true
        appState.showFeedback(message: "Preparing \(targets.count) playlists…", systemImage: "music.note.list",
            actionTitle: "Cancel", action: { queueTask?.cancel() }, autoDismissAfter: nil)
        queueTask = Task { @MainActor in
            defer { isPreparingQueue = false }
            do {
                var songs: [Song] = []
                for id in targets {
                    try Task.checkCancellation()
                    guard appState.activeServer?.id == serverID, generation == loadGeneration else { throw CancellationError() }
                    songs.append(contentsOf: try await appState.networkActor.fetchPlaylistSongs(playlistId: id))
                }
                try Task.checkCancellation()
                guard appState.activeServer?.id == serverID, generation == loadGeneration else { throw CancellationError() }
                appState.playbackManager.addToQueue(appState.visibleSongsForPlayback(songs))
                appState.showFeedback(message: "Added selected playlists to queue", systemImage: "checkmark")
            } catch is CancellationError {
                appState.dismissFeedback()
            } catch {
                guard appState.activeServer?.id == serverID, generation == loadGeneration else { return }
                appState.showFeedback(message: "Couldn't add playlists to queue", detail: error.localizedDescription,
                    style: .error, systemImage: "exclamationmark.triangle")
            }
        }
    }

    private var displayedMatches: [Playlist] { Array(matches.prefix(displayLimit)) }

    private func refreshProjection() {
        matches = PlaylistBrowserProjection.matching(appState.playlists, query: query, sort: sort)
        matchingPlaylistIDs = matches.map(\.id)
        displayLimit = 200
        selection.prune(to: matchingPlaylistIDs)
    }

    private func select(_ id: String, modifiers: NSEvent.ModifierFlags) {
        selection.click(id, in: matchingPlaylistIDs, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
    }

    private func open(_ playlist: Playlist) { appState.detailNavigationPath.append(playlist) }

    private func openFocusedPlaylist() {
        guard let id = selection.focusedID, let playlist = matches.first(where: { $0.id == id }) else { return }
        open(playlist)
    }

    @ViewBuilder
    private func playlistMenu(for playlist: Playlist) -> some View {
        if selection.selectedIDs.contains(playlist.id), selection.selectedIDs.count > 1 {
            Button("Add Selected to Queue") { addSelectedToQueue() }.disabled(isPreparingQueue)
        } else {
            PlaylistContextMenu(playlist: playlist)
        }
    }

}

/// Aug22 native All Playlists:247×303 cell,237pt artwork inset5,
/// label allocation begins at y247. Typography/corners remain unverified.
private struct PlaylistCollectionCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EnvironmentAlbumArtView(coverArtId: playlist.coverArt, size: .large, flexible: true)
                .frame(width: 237, height: 237)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(width: 247, height: 247)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(playlist.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    if playlist.isPublic {
                        Image(systemName: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Public playlist")
                            .accessibilityLabel("Public playlist")
                    }
                }
                Text("\(playlist.songCount) songs • \(playlist.formattedDuration)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 237, height: 46, alignment: .topLeading)
            .padding(.horizontal, 5)
        }
        .frame(width: 247, height: 303, alignment: .topLeading)
        .contentShape(Rectangle())
        .help(playlist.name)
        .accessibilityElement(children: .combine)
    }

}

struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            // Playlist art (mosaic of album arts or placeholder)
            EnvironmentAlbumArtView(coverArtId: playlist.coverArt, size: .small)
                .frame(width: 50, height: 50)
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body)
                    .fontWeight(.medium)

                Text("\(playlist.songCount) songs • \(playlist.formattedDuration)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if playlist.isPublic {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        PlaylistsView()
            .environment(AppState())
    }
}
