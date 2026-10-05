import SwiftUI

/// Keep native menus bounded. A searchable destination picker handles the full
/// collection; opening a context menu never expands every playlist into NSMenu.
struct PlaylistDestinationMenu: View {
    @Environment(AppState.self) private var appState
    let onSelect: (Playlist) -> Void
    let onBrowse: () -> Void
    let onCreate: () -> Void

    var body: some View {
        Menu {
            ForEach(appState.playlists.prefix(12)) { playlist in
                Button(playlist.name) { onSelect(playlist) }
            }
            if !appState.playlists.isEmpty { Divider() }
            Button("Choose Playlist…", action: onBrowse)
            Button("New Playlist…", action: onCreate)
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
    }
}

@MainActor
struct PlaylistDestinationRequest: Identifiable {
    let id = UUID()
    let serverID: UUID
    let itemCount: Int?
    let resolveSongIDs: @MainActor () async throws -> [String]
}

struct PlaylistDestinationPicker: View {
    @Environment(AppState.self) private var appState
    let request: PlaylistDestinationRequest
    @State private var query = ""
    @State private var source: [Playlist] = []
    @State private var matches: [Playlist] = []
    @State private var limit = 200
    @State private var selection: String?
    @State private var isLoading = true
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var actionTask: Task<Void, Never>?

    private var isCurrent: Bool {
        appState.activeServer?.id == request.serverID
            && appState.playlistDestinationRequest?.id == request.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Playlist").font(.title2.bold())
            if let count = request.itemCount {
                Text("\(count) \(count == 1 ? "song" : "songs")").foregroundStyle(.secondary)
            }
            TextField("Find a playlist", text: $query)
                .textFieldStyle(.roundedBorder)
                .disabled(isAdding)
            if isLoading {
                ProgressView("Loading playlists…").frame(maxWidth: .infinity, minHeight: 250)
            } else if matches.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No Playlists" : "No Matching Playlists",
                    systemImage: "music.note.list")
                    .frame(minHeight: 250)
            } else {
                List(selection: $selection) {
                    ForEach(matches.prefix(limit)) { playlist in
                        HStack {
                            Image(systemName: "music.note.list").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(playlist.name).lineLimit(2)
                                Text("\(playlist.songCount) songs").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(playlist.id)
                    }
                }
                .frame(minHeight: 250)
                .disabled(isAdding)
                if limit < matches.count {
                    Button("Show More (\(min(limit, matches.count)) of \(matches.count))") { limit += 200 }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") {
                    actionTask?.cancel()
                    appState.playlistDestinationRequest = nil
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if isAdding { ProgressView().controlSize(.small) }
                Button("Add") { addSelection() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || isLoading || isAdding || !isCurrent)
            }
        }
        .padding(24)
        .frame(width: 480, height: 480)
        .task {
            source = appState.playlists
            refreshMatches()
            isLoading = source.isEmpty
            do {
                let fetched = try await appState.networkActor.fetchPlaylists(expectedServerID: request.serverID)
                guard !Task.isCancelled, isCurrent else { return }
                source = fetched
                appState.playlists = fetched
                refreshMatches()
            } catch {
                guard !Task.isCancelled, isCurrent else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
        .onChange(of: query) { _, _ in refreshMatches() }
        .onChange(of: appState.activeServer?.id) { _, _ in
            guard appState.activeServer?.id != request.serverID else { return }
            actionTask?.cancel()
            appState.playlistDestinationRequest = nil
        }
        .onDisappear { actionTask?.cancel() }
    }

    private func refreshMatches() {
        matches = PlaylistBrowserProjection.matching(source, query: query, sort: .name)
        limit = 200
        if let selection, !matches.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    private func addSelection() {
        guard !isAdding, isCurrent, let playlistID = selection,
              let playlist = source.first(where: { $0.id == playlistID }) else { return }
        isAdding = true
        errorMessage = nil
        actionTask = Task { @MainActor in
            defer { isAdding = false }
            do {
                let songIDs = try await request.resolveSongIDs()
                try Task.checkCancellation()
                guard isCurrent else { return }
                guard !songIDs.isEmpty else {
                    errorMessage = "No songs remain in this selection."
                    return
                }
                try await appState.networkActor.updatePlaylist(id: playlistID, songIdsToAdd: songIDs,
                    expectedServerID: request.serverID)
                guard !Task.isCancelled, isCurrent else { return }
                appState.playlistDestinationRequest = nil
                appState.showFeedback(message: "Added to \(playlist.name)", systemImage: "checkmark")
            } catch {
                guard !Task.isCancelled, isCurrent else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

enum PlaylistBrowserSort: String, CaseIterable, Sendable {
    case name = "Name"
    case changed = "Recently Changed"
    case songCount = "Song Count"
}

enum PlaylistBrowserProjection {
    static func matching(_ playlists: [Playlist], query: String, sort: PlaylistBrowserSort) -> [Playlist] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return playlists.filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.owner.localizedStandardContains(query)
        }.sorted { lhs, rhs in
            switch sort {
            case .changed:
                if lhs.changed != rhs.changed { return lhs.changed > rhs.changed }
            case .songCount:
                if lhs.songCount != rhs.songCount { return lhs.songCount > rhs.songCount }
            case .name: break
            }
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }
}
