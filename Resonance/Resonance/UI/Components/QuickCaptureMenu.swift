import SwiftUI

struct QuickCaptureMenu<LabelContent: View>: View {
    @Environment(AppState.self) private var appState

    let song: Song
    @ViewBuilder let label: () -> LabelContent

    @State private var isHidden = false
    @State private var isLiked = false
    @State private var isFavorite: Bool
    @State private var projects: [Project] = []
    @State private var isPerformingAction = false

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
            .disabled(appState.activeServerId == nil)

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
        .disabled(isPerformingAction)
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
        guard !isPerformingAction else { return }
        guard let verb = CurationVerbRegistry.verb(id: id) else { return }
        let context = CurationVerbContext(appState: appState, song: song, album: nil)
        isPerformingAction = true
        Task { @MainActor in
            defer { isPerformingAction = false }
            let outcome = await verb.perform(context)
            guard !outcome.isStale else { return }
            if id == "favorite", !outcome.localChangeApplied {
                loadLocalState()
            }
            if let message = outcome.message {
                appState.showFeedback(
                    message: message,
                    detail: outcome.detail,
                    style: outcome.style.appFeedbackStyle,
                    systemImage: verb.systemImage
                )
                if id != "favorite" || outcome.localChangeApplied {
                    NotificationCenter.default.post(name: .resonanceCurationDidChange, object: nil)
                }
            } else if Self.expectsFeedback(for: id) {
                // The registry reserves nil outcomes for failures and actions
                // that deliberately open a sheet. Restore optimistic labels
                // when a write did not complete.
                if ["admit", "reject", "like"].contains(id) {
                    loadLocalState()
                }
                appState.showFeedback(
                    message: "Couldn't complete \(verb.title.lowercased())",
                    detail: outcome.detail ?? "Please try again.",
                    style: .error,
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    private static func expectsFeedback(for verbID: String) -> Bool {
        !["add-to-playlist", "more-like-this", "get-info", "delete"].contains(verbID)
    }

    private func loadProjects() {
        guard let serverId = appState.activeServerId else {
            projects = []
            return
        }

        do {
            projects = try appState.databaseManager.loadProjects(serverId: serverId)
        } catch {
            projects = []
            appState.showFeedback(
                message: "Couldn't load projects",
                detail: error.localizedDescription,
                style: .error,
                systemImage: "tray.full"
            )
        }
    }

    // The project picker keeps its per-project UI here, but its writes route
    // through the same `CurationVerbRegistry` helpers the deck's Project verb uses.
    private func addToProject(_ project: Project) {
        guard let serverId = appState.activeServerId else {
            appState.showFeedback(
                message: "Connect to a server to manage projects",
                style: .warning,
                systemImage: "tray.full"
            )
            return
        }

        do {
            try CurationVerbRegistry.addSongToProject(
                song,
                project: project,
                serverId: serverId,
                database: appState.databaseManager
            )
            appState.showFeedback(message: "Added to \(project.name)", style: .success, systemImage: "tray.full")
            NotificationCenter.default.post(name: .resonanceCurationDidChange, object: nil)
        } catch {
            appState.showFeedback(
                message: "Couldn't add to \(project.name)",
                detail: error.localizedDescription,
                style: .error,
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private func createProjectFromSong() {
        guard let serverId = appState.activeServerId else {
            appState.showFeedback(
                message: "Connect to a server to manage projects",
                style: .warning,
                systemImage: "tray.full"
            )
            return
        }

        do {
            let project = try CurationVerbRegistry.createListeningProject(
                from: song,
                serverId: serverId,
                database: appState.databaseManager
            )
            projects.removeAll { $0.id == project.id }
            projects.insert(project, at: 0)
            appState.showFeedback(message: "Created project \(project.name)", style: .success, systemImage: "tray.full")
            NotificationCenter.default.post(name: .resonanceCurationDidChange, object: nil)
        } catch {
            appState.showFeedback(
                message: "Couldn't create project",
                detail: error.localizedDescription,
                style: .error,
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private func loadLocalState() {
        isFavorite = song.starred != nil
        isHidden = false
        isLiked = false

        guard let serverId = appState.activeServerId else {
            return
        }

        do {
            let hidden = try appState.databaseManager.isHidden(id: song.id, type: "song", serverId: serverId)
            let liked = try appState.databaseManager.isLiked(id: song.id, type: "song", serverId: serverId)
            isHidden = hidden
            isLiked = liked
        } catch {
            appState.showFeedback(
                message: "Couldn't load song status",
                detail: error.localizedDescription,
                style: .error,
                systemImage: "exclamationmark.triangle"
            )
        }
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
