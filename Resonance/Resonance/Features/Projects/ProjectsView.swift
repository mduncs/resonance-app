import SwiftUI

extension Notification.Name {
    static let resonanceProjectItemsDidChange = Notification.Name("ResonanceProjectItemsDidChange")
}

private enum ProjectKindOption: String, CaseIterable, Identifiable {
    case listening
    case label
    case folder
    case composer
    case batch
    case collection

    var id: String { rawValue }

    var label: String {
        switch self {
        case .listening: return "Listening"
        case .label: return "Label"
        case .folder: return "Folder"
        case .composer: return "Composer"
        case .batch: return "Batch"
        case .collection: return "Collection"
        }
    }
}

struct ProjectsView: View {
    @Environment(AppState.self) private var appState

    @State private var projects: [Project] = []
    @State private var selectedProjectId: String?
    @State private var newProjectName = ""
    @State private var newProjectKind: ProjectKindOption = .listening
    @State private var isLoading = true

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectId }
    }

    /// Category sections for the master list: named lineages A→Z, then
    /// uncategorized projects last. Categories are headers, never nodes —
    /// every project stays individually selectable.
    private var projectSections: [(category: String?, projects: [Project])] {
        let grouped = Dictionary(grouping: projects) { $0.category }
        let named = grouped.keys.compactMap { $0 }.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        var sections: [(category: String?, projects: [Project])] = named.map {
            (category: $0, projects: grouped[$0] ?? [])
        }
        if let uncategorized = grouped[nil], !uncategorized.isEmpty {
            sections.append((category: nil, projects: uncategorized))
        }
        return sections
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header
                projectCreator
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                if isLoading {
                    loadingState("Loading projects...")
                } else if projects.isEmpty {
                    CompactProjectStatusView(
                        title: "No Projects",
                        systemImage: "tray",
                        message: "Created projects will appear here."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List(selection: $selectedProjectId) {
                        ForEach(projectSections, id: \.category) { section in
                            Section {
                                ForEach(section.projects) { project in
                                    ProjectListRow(project: project)
                                        .tag(project.id)
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                archive(project)
                                            } label: {
                                                Label("Archive", systemImage: "archivebox")
                                            }
                                        }
                                }
                            } header: {
                                // A lone uncategorized section (no automade
                                // lineages yet) keeps the old flat look.
                                if !(section.category == nil && projectSections.count == 1) {
                                    Text(section.category ?? "Uncategorized")
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minHeight: 240, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 260, idealWidth: 320)

            if let selectedProject {
                ProjectDetailPane(project: selectedProject) {
                    loadProjects()
                }
                .frame(minWidth: 460)
            } else {
                CompactProjectStatusView(
                    title: "Select a Project",
                    systemImage: "tray.full",
                    message: "Choose a project from the list."
                )
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .task(id: appState.activeServerId) {
            loadProjects()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resonanceProjectItemsDidChange)) { notification in
            guard notification.userInfo?["serverId"] as? String == appState.activeServerId else { return }
            loadProjects()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Projects")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("\(projects.count) active")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var projectCreator: some View {
        VStack(spacing: 8) {
            TextField("New project", text: $newProjectName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createProject)

            HStack {
                Picker("Kind", selection: $newProjectKind) {
                    ForEach(ProjectKindOption.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()

                Button(action: createProject) {
                    Label("Add", systemImage: "plus")
                }
                .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadingState(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func loadProjects() {
        isLoading = true

        guard let serverId = appState.activeServerId else {
            projects = []
            selectedProjectId = nil
            isLoading = false
            return
        }

        do {
            projects = try appState.databaseManager.loadProjects(serverId: serverId)
            if selectedProjectId == nil || !projects.contains(where: { $0.id == selectedProjectId }) {
                selectedProjectId = projects.first?.id
            }
        } catch {
            projects = []
            selectedProjectId = nil
            print("Failed to load projects: \(error)")
        }
        isLoading = false
    }

    private func createProject() {
        guard let serverId = appState.activeServerId else { return }
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        do {
            let project = Project(serverId: serverId, name: name, kind: newProjectKind.rawValue)
            try appState.databaseManager.saveProject(project)
            newProjectName = ""
            loadProjects()
            selectedProjectId = project.id
            postProjectChange(projectId: project.id, serverId: serverId)
        } catch {
            print("Failed to create project: \(error)")
        }
    }

    private func archive(_ project: Project) {
        guard let serverId = appState.activeServerId else { return }

        do {
            try appState.databaseManager.archiveProject(id: project.id, serverId: serverId)
            loadProjects()
            postProjectChange(projectId: project.id, serverId: serverId)
        } catch {
            print("Failed to archive project: \(error)")
        }
    }

    private func postProjectChange(projectId: String, serverId: String) {
        NotificationCenter.default.post(
            name: .resonanceProjectItemsDidChange,
            object: nil,
            userInfo: [
                "serverId": serverId,
                "projectId": projectId
            ]
        )
    }
}

private struct ProjectListRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .lineLimit(1)
                Text(project.kind.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
    }

    private var iconName: String {
        switch project.kind {
        case "label": return "tag"
        case "folder": return "folder"
        case "composer": return "music.quarternote.3"
        case "batch": return "square.stack.3d.up"
        case "listening": return "headphones"
        default: return "tray"
        }
    }
}

private struct CompactProjectStatusView: View {
    let title: String
    let systemImage: String
    let message: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
    }
}

private struct ProjectDetailPane: View {
    @Environment(AppState.self) private var appState
    @AppStorage("enableOnePlane") private var enableOnePlane = false

    let project: Project
    let onProjectChanged: () -> Void

    @State private var projectItems: [ProjectItem] = []
    @State private var songs: [Song] = []
    @State private var progress = ProjectProgress(
        totalSongs: 0,
        heardCount: 0,
        markedCount: 0,
        remainingCount: 0
    )
    @State private var listenStates: [String: ProjectItemListenState] = [:]
    @State private var isLoading = true

    private var orphanItems: [ProjectItem] {
        let songIds = Set(songs.map(\.id))
        return projectItems.filter { item in
            item.itemType != .song || !songIds.contains(item.itemId)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(project.name)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text(project.kind.capitalized)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        // PR-B: view this project as a lens on the One Plane —
                        // the plane scopes to the project's items rather than
                        // this room being replaced. Only meaningful while the
                        // plane surface is enabled.
                        if enableOnePlane {
                            Button {
                                viewAsLensOnPlane()
                            } label: {
                                Label("Lens", systemImage: "scope")
                            }
                            .help("View as Lens on Plane")
                        }

                        Button {
                            addNowPlaying()
                        } label: {
                            Label("Add Current", systemImage: "plus")
                        }
                        .disabled(appState.nowPlaying == nil)

                        Button {
                            admitProject()
                        } label: {
                            Label("Admit", systemImage: "checkmark.circle")
                        }
                        .disabled(projectItems.isEmpty && songs.isEmpty)

                        Button(role: .destructive) {
                            archiveProject()
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                }

                HStack(alignment: .bottom, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 24) {
                            ProjectProgressMetric(value: progress.heardCount, label: "Heard")
                            ProjectProgressMetric(value: progress.markedCount, label: "Marked")
                            ProjectProgressMetric(value: progress.remainingCount, label: "Remaining")
                        }

                        ProgressView(value: heardProgress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .accessibilityLabel("Project listening progress")
                            .accessibilityValue("\(progress.heardCount) of \(progress.totalSongs) heard")
                    }

                    Spacer()

                    Button {
                        continueProject()
                    } label: {
                        Label("Continue", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(progress.remainingCount == 0)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            if isLoading {
                loadingState("Loading project items...")
            } else if songs.isEmpty && orphanItems.isEmpty {
                CompactProjectStatusView(
                    title: "No Items",
                    systemImage: "tray",
                    message: "Songs and references added to this project will appear here."
                )
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List {
                    if !songs.isEmpty {
                        Section("Songs") {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                HStack(spacing: 10) {
                                    ProjectListenStateDot(
                                        state: listenStates[song.id] ?? .unheard
                                    )
                                    SongRow(song: song, showTrackNumber: false)
                                }
                                    .contentShape(Rectangle())
                                    .accessibilityElement(children: .combine)
                                    .accessibilityHint("Double tap to play")
                                    .onTapGesture(count: 2) {
                                        Task {
                                            await appState.playbackManager.play(songs: songs, startingAt: index)
                                        }
                                    }
                                    .contextMenu {
                                        SongContextMenu(song: song)
                                        Divider()
                                        Button(role: .destructive) {
                                            removeSong(song)
                                        } label: {
                                            Label("Remove from Project", systemImage: "minus.circle")
                                        }
                                    }
                            }
                        }
                    }

                    if !orphanItems.isEmpty {
                        Section("References") {
                            ForEach(orphanItems) { item in
                                HStack {
                                    Image(systemName: item.itemType == .album ? "square.stack" : "music.mic")
                                    Text(item.itemId)
                                        .font(.callout)
                                    Spacer()
                                    Text(item.itemType.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        removeItem(item)
                                    } label: {
                                        Label("Remove from Project", systemImage: "minus.circle")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 240, maxHeight: .infinity)
            }
        }
        .task(id: project.id) {
            loadItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resonanceProjectItemsDidChange)) { notification in
            guard notification.userInfo?["serverId"] as? String == appState.activeServerId else { return }
            guard notification.userInfo?["projectId"] as? String == project.id else { return }
            loadItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resonanceCurationDidChange)) { _ in
            loadItems()
        }
    }

    private var heardProgress: Double {
        guard progress.totalSongs > 0 else { return 0 }
        return Double(progress.heardCount) / Double(progress.totalSongs)
    }

    private func loadingState(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func loadItems() {
        isLoading = true

        guard let serverId = appState.activeServerId else {
            projectItems = []
            songs = []
            progress = ProjectProgress(
                totalSongs: 0,
                heardCount: 0,
                markedCount: 0,
                remainingCount: 0
            )
            listenStates = [:]
            isLoading = false
            return
        }

        do {
            projectItems = try appState.databaseManager.loadProjectItems(
                projectId: project.id,
                serverId: serverId
            )
            progress = try appState.databaseManager.projectProgress(
                projectId: project.id,
                serverId: serverId
            )
            listenStates = try appState.databaseManager.projectItemListenStates(
                projectId: project.id,
                serverId: serverId
            )
            songs = try appState.databaseManager.projectNextUp(
                projectId: project.id,
                serverId: serverId,
                limit: projectItems.count
            )
        } catch {
            projectItems = []
            songs = []
            progress = ProjectProgress(
                totalSongs: 0,
                heardCount: 0,
                markedCount: 0,
                remainingCount: 0
            )
            listenStates = [:]
            print("Failed to load project items: \(error)")
        }
        isLoading = false
    }

    private func continueProject() {
        guard let serverId = appState.activeServerId else { return }

        do {
            let currentProgress = try appState.databaseManager.projectProgress(
                projectId: project.id,
                serverId: serverId
            )
            let batchSize = min(currentProgress.remainingCount, 25)
            guard batchSize > 0 else {
                progress = currentProgress
                return
            }

            let nextSongs = try appState.databaseManager.projectNextUp(
                projectId: project.id,
                serverId: serverId,
                limit: batchSize
            )
            guard !nextSongs.isEmpty else { return }

            Task {
                await appState.playbackManager.play(songs: nextSongs)
            }
        } catch {
            print("Failed to continue project: \(error)")
        }
    }

    /// PR-B: request this project as a lens and fly to the plane. The store is
    /// the hand-off — the plane consumes it on arrival (or next appearance).
    private func viewAsLensOnPlane() {
        PlaneLensStore.shared.request(projectId: project.id)
        appState.selectedSidebarItem = .plane
    }

    private func addNowPlaying() {
        guard let song = appState.nowPlaying, let serverId = appState.activeServerId else { return }

        do {
            try appState.databaseManager.saveSongs([song], serverId: serverId)
            let existingItems = try appState.databaseManager.loadProjectItems(projectId: project.id, serverId: serverId)
            guard !existingItems.contains(where: { $0.itemType == .song && $0.itemId == song.id }) else {
                loadItems()
                return
            }
            let position = try appState.databaseManager.nextProjectItemPosition(projectId: project.id, serverId: serverId)
            try appState.databaseManager.addProjectItem(
                projectId: project.id,
                itemId: song.id,
                itemType: .song,
                serverId: serverId,
                position: position,
                addedBy: "projects"
            )
            loadItems()
            postProjectChange(serverId: serverId)
        } catch {
            print("Failed to add current song to project: \(error)")
        }
    }

    private func admitProject() {
        guard let serverId = appState.activeServerId else { return }

        do {
            let songById = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
            var admittedSongIds: Set<String> = []

            for item in projectItems {
                guard !item.itemId.isEmpty else { continue }

                switch item.itemType {
                case .song:
                    if let song = songById[item.itemId] {
                        try admit(song, serverId: serverId)
                        admittedSongIds.insert(song.id)
                    } else {
                        try appState.databaseManager.admitToLibrary(
                            id: item.itemId,
                            type: .song,
                            serverId: serverId,
                            admittedBy: .project,
                            sourceDetail: project.id
                        )
                    }
                case .album, .artist:
                    try appState.databaseManager.admitToLibrary(
                        id: item.itemId,
                        type: item.itemType,
                        serverId: serverId,
                        admittedBy: .project,
                        sourceDetail: project.id
                    )
                }
            }

            for song in songs where !admittedSongIds.contains(song.id) {
                try admit(song, serverId: serverId)
            }

            appState.refreshLibraryMembershipIds()
            appState.refreshHiddenIds()
        } catch {
            print("Failed to admit project: \(error)")
        }
    }

    private func admit(_ song: Song, serverId: String) throws {
        guard !song.id.isEmpty else { return }

        try appState.databaseManager.admitSongAndRelated(
            song,
            serverId: serverId,
            admittedBy: .project,
            sourceDetail: project.id
        )

        try appState.databaseManager.upsertWaitingRoomItem(
            song: song,
            serverId: serverId,
            state: .admitted,
            source: "project_admit"
        )
        try appState.databaseManager.setWaitingRoomState(
            songId: song.id,
            serverId: serverId,
            state: .admitted
        )
        try appState.databaseManager.unhideSongAndRelated(song, serverId: serverId)
    }

    private func archiveProject() {
        guard let serverId = appState.activeServerId else { return }
        do {
            try appState.databaseManager.archiveProject(id: project.id, serverId: serverId)
            postProjectChange(serverId: serverId)
            onProjectChanged()
        } catch {
            print("Failed to archive project: \(error)")
        }
    }

    private func removeSong(_ song: Song) {
        guard let serverId = appState.activeServerId else { return }
        do {
            try appState.databaseManager.removeProjectItem(
                projectId: project.id,
                itemId: song.id,
                itemType: .song,
                serverId: serverId
            )
            loadItems()
            postProjectChange(serverId: serverId)
        } catch {
            print("Failed to remove project song: \(error)")
        }
    }

    private func removeItem(_ item: ProjectItem) {
        guard let serverId = appState.activeServerId else { return }
        do {
            try appState.databaseManager.removeProjectItem(
                projectId: project.id,
                itemId: item.itemId,
                itemType: item.itemType,
                serverId: serverId
            )
            loadItems()
            postProjectChange(serverId: serverId)
        } catch {
            print("Failed to remove project item: \(error)")
        }
    }

    private func postProjectChange(serverId: String) {
        NotificationCenter.default.post(
            name: .resonanceProjectItemsDidChange,
            object: nil,
            userInfo: [
                "serverId": serverId,
                "projectId": project.id
            ]
        )
    }
}

private struct ProjectProgressMetric: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.title2)
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProjectListenStateDot: View {
    let state: ProjectItemListenState

    var body: some View {
        Group {
            switch state {
            case .unheard:
                Circle()
                    .stroke(Color.secondary.opacity(0.45), lineWidth: 1)
            case .heard:
                Circle()
                    .fill(Color.secondary.opacity(0.6))
            case .marked:
                Circle()
                    .fill(Color.accentColor)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch state {
        case .unheard: return "Unheard"
        case .heard: return "Heard"
        case .marked: return "Marked"
        }
    }
}

#Preview {
    ProjectsView()
        .environment(AppState())
}
