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
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Toggle("Public", isOn: $isPublic)
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
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createPlaylist()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                }
            }
        }
        .frame(width: 400, height: 300)
    }

    private func createPlaylist() {
        isCreating = true
        errorMessage = nil

        Task {
            do {
                try await appState.networkActor.createPlaylist(name: name, songIds: initialSongIds)

                // Refresh playlists list
                let playlists = try await appState.networkActor.fetchPlaylists()
                await MainActor.run {
                    appState.playlists = playlists
                    dismiss()
                }
            } catch let error as ResonanceError {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isCreating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to create playlist: \(error.localizedDescription)"
                    isCreating = false
                }
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
        isSaving = true
        errorMessage = nil

        Task {
            do {
                try await appState.networkActor.updatePlaylist(id: playlist.id, name: name, comment: comment.isEmpty ? nil : comment)

                // Refresh playlists list
                let playlists = try await appState.networkActor.fetchPlaylists()
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
