import SwiftUI

struct QuickCaptureMenu<LabelContent: View>: View {
    @Environment(AppState.self) private var appState

    let song: Song
    @ViewBuilder let label: () -> LabelContent

    @State private var isHidden = false
    @State private var isLiked = false
    @State private var isFavorite: Bool
    @State private var projects: [Project] = []

    init(song: Song, @ViewBuilder label: @escaping () -> LabelContent) {
        self.song = song
        self.label = label
        self._isFavorite = State(initialValue: song.starred != nil)
    }

    var body: some View {
        Menu {
            Button {
                isHidden = false
                perform("admit")
            } label: {
                Label("Admit", systemImage: "checkmark.circle")
            }

            Button {
                isLiked.toggle()
                perform("like")
            } label: {
                Label(isLiked ? "Unlike" : "Like", systemImage: isLiked ? "plus.circle.fill" : "plus.circle")
            }

            Button {
                isFavorite.toggle()
                perform("favorite")
            } label: {
                Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.fill" : "heart")
            }

            Button {
                perform("later")
            } label: {
                Label("Later", systemImage: "clock")
            }

            Button {
                perform("interesting")
            } label: {
                Label("Interesting", systemImage: "sparkle")
            }

            Divider()

            Button {
                perform("add-to-playlist")
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }

            Menu {
                if projects.isEmpty {
                    Button {
                        createProjectFromSong()
                    } label: {
                        Label("New Project from Song", systemImage: "plus")
                    }
                } else {
                    ForEach(projects) { project in
                        Button {
                            addToProject(project)
                        } label: {
                            Label(project.name, systemImage: "tray.and.arrow.down")
                        }
                    }

                    Divider()

                    Button {
                        createProjectFromSong()
                    } label: {
                        Label("New Project from Song", systemImage: "plus")
                    }
                }
            } label: {
                Label("Add to Project", systemImage: "tray.and.arrow.down")
            }

            Button {
                perform("more-like-this")
            } label: {
                Label("More Like This", systemImage: "dot.radiowaves.left.and.right")
            }

            Divider()

            Button {
                perform("get-info")
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }

            Button(role: .destructive) {
                isHidden = true
                perform("reject")
            } label: {
                Label(isHidden ? "Rejected" : "Reject", systemImage: "hand.thumbsdown")
            }
            .disabled(isHidden)

            Button(role: .destructive) {
                perform("delete")
            } label: {
                Label("Delete from Library", systemImage: "trash")
            }
        } label: {
            label()
        }
        .task(id: "\(appState.activeServerId ?? "none"):\(song.id)") {
            loadLocalState()
            loadProjects()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resonanceProjectItemsDidChange)) { notification in
            guard notification.userInfo?["serverId"] as? String == appState.activeServerId else { return }
            loadProjects()
        }
    }

    /// Dispatch a verb through the registry — the writes live there, so the menu
    /// only owns its optimistic display state (the label/disabled toggles above).
    private func perform(_ id: String) {
        guard let verb = CurationVerbRegistry.verb(id: id) else { return }
        let context = CurationVerbContext(appState: appState, song: song, album: nil)
        Task {
            _ = await verb.perform(context)
        }
    }

    private func loadProjects() {
        guard let serverId = appState.activeServerId else {
            projects = []
            return
        }

        projects = (try? appState.databaseManager.loadProjects(serverId: serverId)) ?? []
    }

    // The project picker keeps its per-project UI here, but its writes route
    // through the same `CurationVerbRegistry` helpers the deck's Project verb uses.
    private func addToProject(_ project: Project) {
        guard let serverId = appState.activeServerId else { return }

        do {
            try CurationVerbRegistry.addSongToProject(
                song,
                project: project,
                serverId: serverId,
                database: appState.databaseManager
            )
        } catch {
            print("Failed to add song to project: \(error)")
        }
    }

    private func createProjectFromSong() {
        guard let serverId = appState.activeServerId else { return }

        do {
            let project = try CurationVerbRegistry.createListeningProject(
                from: song,
                serverId: serverId,
                database: appState.databaseManager
            )
            projects.removeAll { $0.id == project.id }
            projects.insert(project, at: 0)
        } catch {
            print("Failed to create project from song: \(error)")
        }
    }

    private func loadLocalState() {
        isFavorite = song.starred != nil

        guard let serverId = appState.activeServerId else {
            isHidden = false
            isLiked = false
            return
        }

        isHidden = (try? appState.databaseManager.isHidden(id: song.id, type: "song", serverId: serverId)) ?? false
        isLiked = (try? appState.databaseManager.isLiked(id: song.id, type: "song", serverId: serverId)) ?? false
    }
}

extension QuickCaptureMenu where LabelContent == Label<Text, Image> {
    init(song: Song) {
        self.init(song: song) {
            Label("Quick Capture", systemImage: "bolt.circle")
        }
    }
}

#Preview {
    QuickCaptureMenu(song: .placeholder)
        .environment(AppState())
}
