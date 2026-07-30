import SwiftUI

struct SmartPlaylistEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var ruleGroup: SmartPlaylistRuleGroup
    @State private var sortBy: String
    @State private var sortOrder: SmartPlaylist.SortOrder
    @State private var itemLimit: String
    @State private var matchCount: Int?
    @State private var isSaving = false

    private let existingPlaylist: SmartPlaylist?

    init(playlist: SmartPlaylist? = nil) {
        self.existingPlaylist = playlist
        _name = State(initialValue: playlist?.name ?? "")
        _ruleGroup = State(initialValue: playlist?.ruleGroup ?? SmartPlaylistRuleGroup())
        _sortBy = State(initialValue: playlist?.sortBy ?? "title")
        _sortOrder = State(initialValue: playlist?.sortOrder ?? .asc)
        _itemLimit = State(initialValue: playlist?.itemLimit.map(String.init) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(existingPlaylist == nil ? "New Smart Playlist" : "Edit Smart Playlist")
                    .font(.headline)
                Spacer()
                if let count = matchCount {
                    Text("\(count) matching songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            // Content
            Form {
                Section("Name") {
                    TextField("Playlist Name", text: $name)
                }

                Section("Match \(ruleGroup.conjunction == .and ? "ALL" : "ANY") of the following rules") {
                    // Conjunction picker
                    Picker("Match", selection: $ruleGroup.conjunction) {
                        Text("All (AND)").tag(SmartPlaylistRuleGroup.Conjunction.and)
                        Text("Any (OR)").tag(SmartPlaylistRuleGroup.Conjunction.or)
                    }
                    .pickerStyle(.segmented)

                    // Rules list
                    ForEach($ruleGroup.rules) { $rule in
                        RuleRow(rule: $rule, onDelete: {
                            ruleGroup.rules.removeAll { $0.id == rule.id }
                            updateMatchCount()
                        })
                    }

                    // Add rule button
                    Button {
                        ruleGroup.rules.append(SmartPlaylistRule(
                            field: .genre,
                            op: .contains,
                            value: ""
                        ))
                    } label: {
                        Label("Add Rule", systemImage: "plus.circle")
                    }
                }

                Section("Sort & Limit") {
                    Picker("Sort by", selection: $sortBy) {
                        Text("Title").tag("title")
                        Text("Artist").tag("artist")
                        Text("Album").tag("album")
                        Text("Year").tag("year")
                        Text("Duration").tag("duration")
                        Text("Rating").tag("rating")
                        Text("Play Count").tag("playCount")
                        Text("Last Played").tag("lastPlayed")
                        Text("Liked Date").tag("likedAt")
                        Text("Loved Date").tag("starredAt")
                        Text("Random").tag("random")
                    }

                    Picker("Order", selection: $sortOrder) {
                        Text("Ascending").tag(SmartPlaylist.SortOrder.asc)
                        Text("Descending").tag(SmartPlaylist.SortOrder.desc)
                    }

                    HStack {
                        Text("Limit to")
                        TextField("", text: $itemLimit)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                        Text("songs")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Preview") {
                    updateMatchCount()
                }

                Button(existingPlaylist == nil ? "Create" : "Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || ruleGroup.rules.isEmpty || isSaving)
            }
            .padding()
        }
        .frame(width: 550, height: 520)
        .onAppear {
            updateMatchCount()
        }
    }

    private func updateMatchCount() {
        guard let serverId = appState.activeServerId else { return }
        let playlist = SmartPlaylist(
            id: existingPlaylist?.id ?? UUID().uuidString,
            name: name,
            serverId: serverId,
            ruleGroup: ruleGroup,
            sortBy: sortBy,
            sortOrder: sortOrder,
            itemLimit: Int(itemLimit)
        )
        matchCount = try? appState.databaseManager.smartPlaylistMatchCount(playlist)
    }

    private func save() {
        guard let serverId = appState.activeServerId else { return }
        isSaving = true

        var playlist = SmartPlaylist(
            id: existingPlaylist?.id ?? UUID().uuidString,
            name: name,
            serverId: serverId,
            ruleGroup: ruleGroup,
            sortBy: sortBy,
            sortOrder: sortOrder,
            itemLimit: Int(itemLimit)
        )
        if let existing = existingPlaylist {
            playlist.createdAt = existing.createdAt
        }

        do {
            try appState.databaseManager.saveSmartPlaylist(playlist)
            try appState.databaseManager.evaluateSmartPlaylist(playlist)
            appState.smartPlaylists = (try? appState.databaseManager.loadSmartPlaylists(serverId: serverId)) ?? []
            dismiss()
        } catch {
            print("Failed to save smart playlist: \(error)")
            isSaving = false
        }
    }
}

// MARK: - Rule Row

private struct RuleRow: View {
    @Binding var rule: SmartPlaylistRule
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Field picker
            Picker("", selection: $rule.field) {
                ForEach(SmartPlaylistRule.RuleField.allCases, id: \.self) { field in
                    Text(field.displayName).tag(field)
                }
            }
            .frame(width: 120)
            .onChange(of: rule.field) {
                // Reset operator to first compatible one when field changes
                if !rule.field.compatibleOperators.contains(rule.op) {
                    rule.op = rule.field.compatibleOperators.first ?? .contains
                }
            }

            // Operator picker
            Picker("", selection: $rule.op) {
                ForEach(rule.field.compatibleOperators, id: \.self) { op in
                    Text(op.displayName).tag(op)
                }
            }
            .frame(width: 130)

            // Value field (hidden for boolean operators)
            if rule.op != .isTrue && rule.op != .isFalse {
                TextField(valuePlaceholder, text: $rule.value)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 80)
            }

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    private var valuePlaceholder: String {
        switch rule.field {
        case .year: return "e.g. 2020"
        case .duration: return "seconds"
        case .playCount: return "e.g. 5"
        case .rating: return "1-5"
        case .lastPlayed, .likedAt, .starredAt: return "e.g. 30d"
        case .bitRate: return "e.g. 320"
        default: return "value"
        }
    }
}
