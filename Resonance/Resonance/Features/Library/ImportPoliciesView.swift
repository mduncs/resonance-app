import SwiftUI

struct ImportPoliciesView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(ImportPolicyDefaults.autoAdmitNavidromeLibrary) private var autoAdmitNavidromeLibrary = true
    @AppStorage(ImportPolicyDefaults.stageServerImports) private var stageServerImports = false
    @AppStorage(ImportPolicyDefaults.keepUnclassifiedOutOfLibrary) private var keepUnclassifiedOutOfLibrary = true
    @AppStorage(ImportPolicyDefaults.autoMarkPartialAuditions) private var autoMarkPartialAuditions = true
    @AppStorage(ImportPolicyDefaults.autoMarkHeardAuditions) private var autoMarkHeardAuditions = true

    @State private var status: String?

    private var shouldAdmitCachedUnclassified: Bool {
        autoAdmitNavidromeLibrary || !keepUnclassifiedOutOfLibrary
    }

    var body: some View {
        Form {
            Section {
                Toggle("Admit Navidrome library automatically", isOn: $autoAdmitNavidromeLibrary)
                Toggle("Stage server imports in Waiting Room", isOn: $stageServerImports)
                    .disabled(shouldAdmitCachedUnclassified)
                Toggle("Keep unclassified media out of Library", isOn: $keepUnclassifiedOutOfLibrary)
            } header: {
                Text("Admission")
            } footer: {
                Text("With automatic admission on, new server imports go straight to the Library — the Unclassified pool stays empty and its sidebar entry stays hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Auditions") {
                Toggle("Mark partial auditions", isOn: $autoMarkPartialAuditions)
                Toggle("Mark heard auditions", isOn: $autoMarkHeardAuditions)
            }

            Section {
                HStack {
                    Button("Apply to Cache") { applyPolicies() }
                    Button("Reset to Defaults") { resetDefaults() }
                }
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Apply to Cache runs the current policy over already-cached songs that have no Library or Waiting Room decision yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: shouldAdmitCachedUnclassified) { _, shouldAdmit in
            if shouldAdmit {
                stageServerImports = false
            }
        }
    }

    private func applyPolicies() {
        guard let serverId = appState.activeServerId else {
            status = "No active server"
            return
        }

        do {
            // Songs that already have a Waiting Room decision — including ones the user
            // explicitly REJECTED — still come back from loadUnclassifiedSongs, so acting
            // on the raw set would silently re-admit or re-stage them. Filter them out
            // client-side, matching UnclassifiedView.loadSongs().
            let waitingRoomSongIds = Set(
                try appState.databaseManager
                    .loadWaitingRoomItems(serverId: serverId, includeDecided: true)
                    .map { $0.song.id }
            )
            let songs = try appState.databaseManager.loadUnclassifiedSongs(
                serverId: serverId,
                includeHidden: false
            )
            .filter { !waitingRoomSongIds.contains($0.id) }

            if shouldAdmitCachedUnclassified {
                for song in songs {
                    try appState.databaseManager.admitSongAndRelated(
                        song,
                        serverId: serverId,
                        admittedBy: .navidromeLibrary,
                        sourceDetail: "policy_apply"
                    )
                }
                appState.refreshLibraryMembershipIds()
                status = "Admitted \(songs.count) undecided cached songs"
            } else if stageServerImports {
                for song in songs {
                    try appState.databaseManager.upsertWaitingRoomItem(
                        song: song,
                        serverId: serverId,
                        state: .unheard,
                        source: "policy_apply"
                    )
                }
                status = "Staged \(songs.count) undecided cached songs"
            } else {
                status = "Left \(songs.count) undecided cached songs unclassified"
            }
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func resetDefaults() {
        autoAdmitNavidromeLibrary = true
        stageServerImports = false
        keepUnclassifiedOutOfLibrary = true
        autoMarkPartialAuditions = true
        autoMarkHeardAuditions = true
        status = "Defaults restored"
    }
}

#Preview {
    ImportPoliciesView()
        .environment(AppState())
}
