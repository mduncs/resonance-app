import SwiftUI

struct PlaylistsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewState: ViewState = .loading
    @State private var showingCreateSheet = false

    enum ViewState {
        case loading
        case empty
        case error(ResonanceError)
        case populated
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

            // Content
            Group {
                switch viewState {
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
                    List(appState.playlists) { playlist in
                        NavigationLink(value: playlist) {
                            PlaylistRow(playlist: playlist)
                        }
                        .contextMenu {
                            PlaylistContextMenu(playlist: playlist)
                        }
                    }
                    .frame(minHeight: 300)
                }
            }
        }
        .navigationTitle("")
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
        .task {
            await loadPlaylists()
        }
    }

    private func deletePlaylist(_ playlist: Playlist) async {
        do {
            try await appState.networkActor.deletePlaylist(id: playlist.id)
            await MainActor.run {
                appState.playlists.removeAll { $0.id == playlist.id }
                appState.deletePlaylistTarget = nil
            }
        } catch {
            // Handle error - for now just clear the target
            await MainActor.run {
                appState.deletePlaylistTarget = nil
            }
        }
    }

    private func loadPlaylists() async {
        viewState = .loading
        do {
            let playlists = try await appState.networkActor.fetchPlaylists()
            await MainActor.run {
                appState.playlists = playlists
                viewState = playlists.isEmpty ? .empty : .populated
            }
        } catch let error as ResonanceError {
            viewState = .error(error)
        } catch {
            viewState = .error(.networkUnavailable)
        }
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
