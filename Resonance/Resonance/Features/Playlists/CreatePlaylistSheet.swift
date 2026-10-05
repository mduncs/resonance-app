import SwiftUI

struct CreatePlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    /// Song IDs to add to the playlist on creation
    var initialSongIds: [String] = []

    @State private var name = ""
    @State private var description = ""
    @State private var isPublic = false
    @State private var isCreating = false
    @State private var createdPlaylistID: String?
    @State private var creationServerID: UUID?
    @State private var hasSavedDetails = false

    private var hasCreatedPlaylist: Bool { createdPlaylistID != nil }
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }
                .disabled(isCreating || hasCreatedPlaylist)

                Section {
                    Toggle("Public", isOn: $isPublic)
                        .disabled(isCreating || hasCreatedPlaylist)
                } footer: {
                    Text("Public playlists can be seen by other users on your server.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasCreatedPlaylist ? "Close" : "Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(hasCreatedPlaylist ? (hasSavedDetails ? "Retry Refresh" : "Retry Save") : "Create") {
                        createPlaylist()
                    }
                    .disabled(isCreating || (!hasCreatedPlaylist && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
        .frame(width: 400, height: 300)
    }

    private func createPlaylist() {
        let submittedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isCreating, hasCreatedPlaylist || !submittedName.isEmpty else { return }
        guard let serverID = hasCreatedPlaylist ? creationServerID : appState.activeServer?.id,
              serverID == appState.activeServer?.id else {
            errorMessage = "Return to the server where this playlist was started before retrying."
            return
        }
        creationServerID = serverID
        let submittedSongIds = initialSongIds
        let submittedDescription = description
        let submittedPublic = isPublic
        isCreating = true
        errorMessage = nil

        Task {
            defer { isCreating = false }
            do {
                if !hasCreatedPlaylist {
                    createdPlaylistID = try await appState.networkActor.createPlaylist(
                        name: submittedName, songIds: submittedSongIds, expectedServerID: serverID
                    )
                }
                if !hasSavedDetails, let createdPlaylistID {
                    try await appState.networkActor.updatePlaylist(
                        id: createdPlaylistID, comment: submittedDescription, isPublic: submittedPublic,
                        expectedServerID: serverID
                    )
                    hasSavedDetails = true
                }
                let playlists = try await appState.networkActor.fetchPlaylists(forceRefresh: true, expectedServerID: serverID)
                guard appState.activeServer?.id == serverID else { throw ResonanceError.notConfigured }
                appState.playlists = playlists
                dismiss()
            } catch {
                errorMessage = hasCreatedPlaylist
                    ? (hasSavedDetails
                        ? "The playlist was created, but the list couldn't be refreshed: \(error.localizedDescription)"
                        : "The playlist was created, but its description and visibility couldn't be saved: \(error.localizedDescription)")
                    : "Failed to create playlist: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Edit Playlist Sheet

struct EditPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let playlist: Playlist

    @State private var name: String
    @State private var comment: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(playlist: Playlist) {
        self.playlist = playlist
        self._name = State(initialValue: playlist.name)
        self._comment = State(initialValue: playlist.comment ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $comment, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePlaylist()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (name == playlist.name && comment == (playlist.comment ?? "")) || isSaving)
                }
            }
        }
        .frame(width: 400, height: 250)
    }

    private func savePlaylist() {
        let submittedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedName.isEmpty, !isSaving else { return }
        let submittedComment = comment
        isSaving = true
        errorMessage = nil

        Task {
            do {
                try await appState.networkActor.updatePlaylist(id: playlist.id, name: submittedName, comment: submittedComment)

                // Refresh playlists list
                let playlists = try await appState.networkActor.fetchPlaylists(forceRefresh: true)
                await MainActor.run {
                    appState.playlists = playlists
                    dismiss()
                }
            } catch let error as ResonanceError {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to update playlist: \(error.localizedDescription)"
                    isSaving = false
                }
            }
        }
    }
}

#Preview("Create Playlist") {
    CreatePlaylistSheet()
        .environment(AppState())
}

#Preview("Edit Playlist") {
    EditPlaylistSheet(playlist: .placeholder)
        .environment(AppState())
}
