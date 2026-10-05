import SwiftUI

struct WaitingRoomView: View {
    @Environment(AppState.self) private var appState

    @State private var filter: WaitingRoomFilter = .pending
    @State private var items: [WaitingRoomItem] = []
    @State private var sourceAttributions: [String: SourceAttributionRecord] = [:]
    @State private var dossiers: [String: DossierStory] = [:]
    @State private var projects: [Project] = []
    @State private var selection = Set<String>()
    @State private var keyboardCursor: String?
    @State private var bloomedItemId: String?
    @State private var projectRequest: WaitingRoomProjectRequest?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var isListFocused: Bool
    @FocusState private var isBloomFocused: Bool

    private var filteredItems: [WaitingRoomItem] {
        switch filter {
        case .all:
            return items
        case .pending:
            return items.filter { !$0.state.isDecided }
        case .interesting:
            return items.filter { $0.state == .interesting }
        case .admitted:
            return items.filter { $0.state == .admitted }
        case .rejected:
            return items.filter { $0.state == .rejected }
        }
    }

    private var selectedVisibleItems: [WaitingRoomItem] {
        filteredItems.filter { selection.contains($0.id) }
    }

    private var focusedItem: WaitingRoomItem? {
        guard let keyboardCursor else { return nil }
        return filteredItems.first { $0.id == keyboardCursor }
    }

    private var bloomedItem: WaitingRoomItem? {
        guard let bloomedItemId else { return nil }
        return items.first { $0.id == bloomedItemId }
    }

    private var pendingCount: Int {
        items.filter { !$0.state.isDecided }.count
    }

    private var interestingCount: Int {
        items.filter { $0.state == .interesting }.count
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                header

                Divider()

                if !selection.isEmpty {
                    bulkActionBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let bloomedItem {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        collapseBloom()
                    }

                WaitingRoomBloomCard(
                    item: bloomedItem,
                    dossier: dossiers[bloomedItem.id],
                    sourceName: sourceName(for: bloomedItem),
                    onPlay: { audition(bloomedItem) },
                    onAdmit: { decideFromBloom(bloomedItem, state: .admitted) },
                    onReject: { decideFromBloom(bloomedItem, state: .rejected) },
                    onProject: { presentProjects(for: [bloomedItem], fromBloom: true) },
                    onLater: { markLater(bloomedItem, advanceAfter: true) },
                    onInteresting: { markInteresting(bloomedItem, advanceAfter: true) },
                    onClose: collapseBloom
                )
                .focusable()
                .focused($isBloomFocused)
                .onKeyPress(keys: [.escape], phases: .down) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    collapseBloom()
                    return .handled
                }
                .onKeyPress(keys: [KeyEquivalent("a")], phases: .down) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    decideFromBloom(bloomedItem, state: .admitted)
                    return .handled
                }
                .onKeyPress(keys: [KeyEquivalent("r")], phases: .down) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    decideFromBloom(bloomedItem, state: .rejected)
                    return .handled
                }
                .onKeyPress(keys: [KeyEquivalent("p")], phases: .down) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    presentProjects(for: [bloomedItem], fromBloom: true)
                    return .handled
                }
                .onKeyPress(keys: [KeyEquivalent("l")], phases: .down) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    markLater(bloomedItem, advanceAfter: true)
                    return .handled
                }
                .onKeyPress(keys: [KeyEquivalent("i")], phases: .down) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    markInteresting(bloomedItem, advanceAfter: true)
                    return .handled
                }
                .onKeyPress(keys: [.space], phases: .down) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    audition(bloomedItem)
                    return .handled
                }
                .transition(.scale(scale: 0.97).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .task {
            await loadWaitingRoom()
        }
        .onChange(of: filter) { _, _ in
            reconcileInteractionState(preferredCursor: nil)
        }
        .popover(item: $projectRequest) { request in
            WaitingRoomProjectPicker(
                projects: projects,
                onChoose: { project in
                    addToProject(project, request: request)
                },
                onCancel: {
                    projectRequest = nil
                    if request.bloomItemId != nil {
                        isBloomFocused = true
                    } else {
                        isListFocused = true
                    }
                }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waiting Room")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    HStack(spacing: 8) {
                        Text("\(pendingCount) pending")
                        Text("\(interestingCount) interesting")
                        Text("\(items.count) total")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Text("J/K navigate · A/R decide · P project · L later · I interesting · Space audition · Return open")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Button {
                    Task { await loadWaitingRoom() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .help("Refresh")
            }

            Picker("Filter", selection: $filter) {
                ForEach(WaitingRoomFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            loadingState("Loading waiting room...")
        } else if let errorMessage {
            CompactCurationStatusView(
                title: "Unable to Load Waiting Room",
                systemImage: "exclamationmark.triangle",
                message: errorMessage
            )
            .padding(.horizontal, 24)
            .padding(.top, 18)
        } else if filteredItems.isEmpty {
            CompactCurationStatusView(
                title: emptyTitle,
                systemImage: "tray",
                message: emptyMessage
            )
            .padding(.horizontal, 24)
            .padding(.top, 18)
        } else {
            HSplitView {
                triageList
                    .frame(minWidth: 600, idealWidth: 760)

                WaitingRoomInspector(
                    item: focusedItem,
                    dossier: focusedItem.flatMap { dossiers[$0.id] },
                    sourceName: focusedItem.map(sourceName(for:)) ?? "—"
                )
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 480)
            }
        }
    }

    private var triageList: some View {
        List(selection: $selection) {
            WaitingRoomColumnHeader()
                .selectionDisabled()

            ForEach(filteredItems) { item in
                WaitingRoomRow(
                    item: item,
                    sourceName: sourceName(for: item),
                    evidenceSummary: evidenceSummary(for: item),
                    isFocused: keyboardCursor == item.id,
                    isPlaying: appState.nowPlaying?.id == item.song.id,
                    onFocus: {
                        keyboardCursor = item.id
                        isListFocused = true
                    },
                    onPlay: { audition(item) },
                    onProject: { presentProjects(for: [item], fromBloom: false) },
                    onLater: { markLater(item, advanceAfter: false) },
                    onInteresting: { markInteresting(item, advanceAfter: false) },
                    onAdmit: { decide(item, state: .admitted, advance: false) },
                    onReject: { decide(item, state: .rejected, advance: false) },
                    onOpen: { bloom(item) }
                )
                .tag(item.id)
            }
        }
        .listStyle(.inset)
        .focused($isListFocused)
        .onAppear {
            if keyboardCursor == nil {
                keyboardCursor = filteredItems.first?.id
            }
            isListFocused = true
        }
        .onChange(of: selection) { _, newSelection in
            if newSelection.count == 1, let selected = newSelection.first {
                keyboardCursor = selected
            }
        }
        .onKeyPress(keys: [KeyEquivalent("j")], phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            moveFocus(by: 1)
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("k")], phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            moveFocus(by: -1)
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("a")], phases: .down) { press in
            guard press.modifiers.isEmpty, let focusedItem else { return .ignored }
            decide(focusedItem, state: .admitted, advance: true)
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("r")], phases: .down) { press in
            guard press.modifiers.isEmpty, let focusedItem else { return .ignored }
            decide(focusedItem, state: .rejected, advance: true)
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("p")], phases: .down) { press in
            guard press.modifiers.isEmpty, let focusedItem else { return .ignored }
            presentProjects(for: [focusedItem], fromBloom: false)
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("l")], phases: .down) { press in
            guard press.modifiers.isEmpty, let focusedItem else { return .ignored }
            markLater(focusedItem, advanceAfter: false)
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("i")], phases: .down) { press in
            guard press.modifiers.isEmpty, let focusedItem else { return .ignored }
            markInteresting(focusedItem, advanceAfter: false)
            return .handled
        }
        .onKeyPress(keys: [.space], phases: .down) { press in
            guard press.modifiers.isEmpty, let focusedItem else { return .ignored }
            audition(focusedItem)
            return .handled
        }
        .onKeyPress(keys: [.return, KeyEquivalent("o")], phases: .down) { press in
            guard press.modifiers.isEmpty, let focusedItem else { return .ignored }
            bloom(focusedItem)
            return .handled
        }
        .frame(minHeight: 240, maxHeight: .infinity)
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

    private var bulkActionBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedVisibleItems.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                updateState(for: selection, state: .admitted)
            } label: {
                Label("Admit", systemImage: "checkmark.circle")
            }

            Button(role: .destructive) {
                updateState(for: selection, state: .rejected)
            } label: {
                Label("Reject", systemImage: "xmark.circle")
            }

            Button {
                markLater(selectedVisibleItems)
            } label: {
                Label("Later", systemImage: "clock")
            }

            Button {
                markInteresting(selectedVisibleItems)
            } label: {
                Label("Interesting", systemImage: "sparkle")
            }

            Button {
                presentProjects(for: selectedVisibleItems, fromBloom: false)
            } label: {
                Label("Project", systemImage: "folder.badge.plus")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(selectedVisibleItems.isEmpty)
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var emptyTitle: String {
        switch filter {
        case .all: "No Waiting Room Songs"
        case .pending: "No Pending Songs"
        case .interesting: "No Interesting Songs"
        case .admitted: "No Admitted Songs"
        case .rejected: "No Rejected Songs"
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .all: "Songs staged for curation will appear here."
        case .pending: "Undecided songs will appear here."
        case .interesting: "Songs marked interesting will appear here."
        case .admitted: "Admitted songs will appear here."
        case .rejected: "Rejected songs will appear here."
        }
    }

    private func loadWaitingRoom() async {
        guard let serverId = appState.activeServerId else {
            items = []
            sourceAttributions = [:]
            dossiers = [:]
            projects = []
            errorMessage = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let loadedItems = try appState.databaseManager
                .loadWaitingRoomItems(serverId: serverId, includeDecided: true)
                .filter { !appState.hiddenSongIds.contains($0.song.id) || $0.state == .rejected }
            let loadedAttributions = try appState.databaseManager
                .sourceAttributionsBySongId(songs: loadedItems.map(\.song), serverId: serverId)
            var loadedDossiers: [String: DossierStory] = [:]
            for item in loadedItems {
                loadedDossiers[item.id] = try appState.databaseManager.dossierStory(
                    songId: item.song.id,
                    songPath: item.song.path,
                    albumId: item.song.albumId,
                    serverId: serverId
                )
            }

            items = loadedItems
            sourceAttributions = loadedAttributions
            dossiers = loadedDossiers
            projects = try appState.databaseManager.loadProjects(serverId: serverId)
            selection = []
            errorMessage = nil
            reconcileInteractionState(preferredCursor: keyboardCursor)
        } catch {
            items = []
            sourceAttributions = [:]
            dossiers = [:]
            projects = []
            selection = []
            keyboardCursor = nil
            errorMessage = error.localizedDescription
        }
    }

    private func sourceName(for item: WaitingRoomItem) -> String {
        guard let name = sourceAttributions[item.song.id]?.sourceDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return "—" }
        return name
    }

    private func evidenceSummary(for item: WaitingRoomItem) -> String {
        if let dossier = dossiers[item.id],
           let line = WaitingRoomProse.storyLines(for: dossier).first {
            return line
        }
        if let notes = item.notes, !notes.isEmpty {
            return notes
        }
        return "Arrived via \(WaitingRoomProse.friendly(item.source)); no further testimony yet."
    }

    private func moveFocus(by offset: Int) {
        let ids = filteredItems.map(\.id)
        guard !ids.isEmpty else { return }

        let current = keyboardCursor.flatMap { ids.firstIndex(of: $0) }
        let nextIndex: Int
        if let current {
            nextIndex = min(max(current + offset, 0), ids.count - 1)
        } else {
            nextIndex = offset < 0 ? ids.count - 1 : 0
        }

        keyboardCursor = ids[nextIndex]
        selection = [ids[nextIndex]]
    }

    private func audition(_ item: WaitingRoomItem) {
        Task { await appState.playbackManager.playNow(item.song) }
    }

    private func bloom(_ item: WaitingRoomItem) {
        keyboardCursor = item.id
        bloomedItemId = item.id
        isBloomFocused = true
    }

    private func collapseBloom() {
        bloomedItemId = nil
        isBloomFocused = false
        isListFocused = true
    }

    private func decideFromBloom(_ item: WaitingRoomItem, state: WaitingRoomState) {
        bloomedItemId = nil
        decide(item, state: state, advance: true)
    }

    private func decide(_ item: WaitingRoomItem, state: WaitingRoomState, advance: Bool) {
        let nextId = advance ? nextItemId(after: item.id) : keyboardCursor
        updateState(for: [item.id], state: state)
        reconcileInteractionState(preferredCursor: nextId)
        isListFocused = true
    }

    private func nextItemId(after id: String) -> String? {
        let ids = filteredItems.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return ids.first }
        if index + 1 < ids.count {
            return ids[index + 1]
        }
        return index > 0 ? ids[index - 1] : nil
    }

    private func markLater(_ item: WaitingRoomItem, advanceAfter: Bool) {
        markLater([item])
        if advanceAfter {
            let nextId = nextItemId(after: item.id)
            bloomedItemId = nil
            reconcileInteractionState(preferredCursor: nextId)
            isListFocused = true
        }
    }

    private func markLater(_ targets: [WaitingRoomItem]) {
        guard let serverId = appState.activeServerId else { return }
        do {
            for item in targets {
                try appState.databaseManager.markAttention(
                    id: item.song.id,
                    type: .song,
                    serverId: serverId,
                    markType: .later,
                    source: "waiting_room"
                )
                reloadDossier(for: item)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func markInteresting(_ item: WaitingRoomItem, advanceAfter: Bool) {
        let nextId = advanceAfter ? nextItemId(after: item.id) : keyboardCursor
        toggleInteresting(item.id)
        if advanceAfter {
            bloomedItemId = nil
            reconcileInteractionState(preferredCursor: nextId)
            isListFocused = true
        }
    }

    private func markInteresting(_ targets: [WaitingRoomItem]) {
        for item in targets where item.state != .interesting {
            toggleInteresting(item.id)
        }
    }

    private func toggleInteresting(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = items[index].state == .interesting ? .unheard : .interesting
        items[index].updatedAt = Date()

        guard let serverId = appState.activeServerId else { return }
        do {
            try appState.databaseManager.setWaitingRoomState(
                songId: items[index].song.id,
                serverId: serverId,
                state: items[index].state
            )
            if items[index].state == .interesting {
                try appState.databaseManager.markAttention(
                    id: items[index].song.id,
                    type: .song,
                    serverId: serverId,
                    markType: .interesting,
                    source: "waiting_room"
                )
            } else {
                try appState.databaseManager.clearAttention(
                    id: items[index].song.id,
                    type: .song,
                    serverId: serverId,
                    markType: .interesting
                )
            }
            reloadDossier(for: items[index])
            reconcileInteractionState(preferredCursor: keyboardCursor)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func presentProjects(for targets: [WaitingRoomItem], fromBloom: Bool) {
        let ids = targets.map(\.id)
        guard !ids.isEmpty else { return }
        projectRequest = WaitingRoomProjectRequest(
            itemIds: ids,
            bloomItemId: fromBloom ? ids.first : nil
        )
    }

    private func addToProject(_ project: Project, request: WaitingRoomProjectRequest) {
        guard let serverId = appState.activeServerId else { return }
        let targetItems = items.filter { request.itemIds.contains($0.id) }
        do {
            _ = try appState.databaseManager.addProjectSongReferences(
                projectId: project.id,
                songIds: targetItems.map(\.song.id),
                serverId: serverId,
                addedBy: "waiting_room"
            )
            for item in targetItems {
                reloadDossier(for: item)
            }
            NotificationCenter.default.post(
                name: .resonanceProjectItemsDidChange,
                object: nil,
                userInfo: ["serverId": serverId, "projectId": project.id]
            )
            appState.showFeedback(
                message: "Added to \(project.name)",
                systemImage: "folder.badge.plus"
            )
            projectRequest = nil
            errorMessage = nil
            restoreFocus(after: request)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreFocus(after request: WaitingRoomProjectRequest) {
        if let bloomItemId = request.bloomItemId,
           let bloomItem = items.first(where: { $0.id == bloomItemId }) {
            let nextId = nextItemId(after: bloomItem.id)
            bloomedItemId = nil
            reconcileInteractionState(preferredCursor: nextId)
        }
        isListFocused = true
    }

    private func reloadDossier(for item: WaitingRoomItem) {
        guard let serverId = appState.activeServerId else { return }
        do {
            dossiers[item.id] = try appState.databaseManager.dossierStory(
                songId: item.song.id,
                songPath: item.song.path,
                albumId: item.song.albumId,
                serverId: serverId
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reconcileInteractionState(preferredCursor: String?) {
        let visibleIds = filteredItems.map(\.id)
        let visibleSet = Set(visibleIds)
        selection.formIntersection(visibleSet)

        if let preferredCursor, visibleSet.contains(preferredCursor) {
            keyboardCursor = preferredCursor
        } else if let keyboardCursor, visibleSet.contains(keyboardCursor) {
            self.keyboardCursor = keyboardCursor
        } else {
            keyboardCursor = visibleIds.first
        }

        if let bloomedItemId, !items.contains(where: { $0.id == bloomedItemId }) {
            self.bloomedItemId = nil
        }
    }

    private func updateState<S: Sequence>(for ids: S, state: WaitingRoomState) where S.Element == String {
        let idSet = Set(ids)
        guard !idSet.isEmpty else { return }
        guard let serverId = appState.activeServerId else { return }

        var didChangeHiddenItems = false
        var didChangeLibraryMembership = false
        for index in items.indices where idSet.contains(items[index].id) {
            let item = items[index]
            let now = Date()

            do {
                try appState.databaseManager.setWaitingRoomState(
                    songId: item.song.id,
                    serverId: serverId,
                    state: state
                )

                switch state {
                case .admitted:
                    try appState.databaseManager.admitSongAndRelated(
                        item.song,
                        serverId: serverId,
                        admittedBy: .manual,
                        sourceDetail: "waiting_room"
                    )
                    try appState.databaseManager.unhideSongAndRelated(item.song, serverId: serverId)
                    try appState.databaseManager.clearAttention(
                        id: item.song.id,
                        type: .song,
                        serverId: serverId,
                        markType: .dismissed
                    )
                    didChangeHiddenItems = true
                    didChangeLibraryMembership = true
                case .rejected:
                    try appState.databaseManager.removeFromLibrary(
                        id: item.song.id,
                        type: .song,
                        serverId: serverId
                    )
                    try appState.databaseManager.markAttention(
                        id: item.song.id,
                        type: .song,
                        serverId: serverId,
                        markType: .dismissed,
                        source: "waiting_room"
                    )
                    try appState.databaseManager.clearAttention(
                        id: item.song.id,
                        type: .song,
                        serverId: serverId,
                        markType: .interesting
                    )
                    try appState.databaseManager.hideItem(
                        id: item.song.id,
                        type: "song",
                        serverId: serverId,
                        reason: "waiting_room_reject"
                    )
                    didChangeHiddenItems = true
                    didChangeLibraryMembership = true
                default:
                    break
                }

                items[index].state = state
                items[index].updatedAt = now
                items[index].admittedAt = state == .admitted ? now : nil
                items[index].rejectedAt = state == .rejected ? now : nil
                reloadDossier(for: items[index])
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        selection.subtract(idSet)
        reconcileInteractionState(preferredCursor: keyboardCursor)

        if didChangeHiddenItems {
            appState.refreshHiddenIds()
        }
        if didChangeLibraryMembership {
            appState.refreshLibraryMembershipIds()
        }
    }
}

private struct WaitingRoomColumnHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 34)
            Text("Song")
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            Text("Source")
                .frame(width: 130, alignment: .leading)
            Text("Evidence")
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            Text("Arrived")
                .frame(width: 92, alignment: .trailing)
            Color.clear.frame(width: 142)
        }
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.vertical, 2)
    }
}

private struct WaitingRoomRow: View {
    let item: WaitingRoomItem
    let sourceName: String
    let evidenceSummary: String
    let isFocused: Bool
    let isPlaying: Bool
    let onFocus: () -> Void
    let onPlay: () -> Void
    let onProject: () -> Void
    let onLater: () -> Void
    let onInteresting: () -> Void
    let onAdmit: () -> Void
    let onReject: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            EnvironmentAlbumArtView(coverArtId: item.song.coverArt, size: .small)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(item.song.title)
                        .fontWeight(isPlaying || isFocused ? .semibold : .regular)
                        .lineLimit(1)
                }
                Text(item.song.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)

            Text(sourceName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)

            Text(evidenceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

            Text(WaitingRoomProse.relative(item.addedAt))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 92, alignment: .trailing)

            HStack(spacing: 3) {
                rowButton("checkmark", help: "Admit", action: onAdmit)
                    .disabled(item.state == .admitted)
                rowButton("xmark", help: "Reject", role: .destructive, action: onReject)
                    .disabled(item.state == .rejected)
                rowButton("folder.badge.plus", help: "Add to Project", action: onProject)
                rowButton("clock", help: "Mark Later", action: onLater)
                rowButton("sparkle", help: "Mark Interesting", action: onInteresting)
                    .foregroundStyle(item.state == .interesting ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: 142, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(isFocused ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay(alignment: .leading) {
            if isFocused {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
        }
        .simultaneousGesture(TapGesture().onEnded(onFocus))
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu {
            Button(action: onPlay) {
                Label("Audition", systemImage: "play")
            }
            Button(action: onOpen) {
                Label("Open Card", systemImage: "rectangle.expand.vertical")
            }
            Divider()
            Button(action: onAdmit) {
                Label("Admit", systemImage: "checkmark.circle")
            }
            Button(role: .destructive, action: onReject) {
                Label("Reject", systemImage: "xmark.circle")
            }
            Button(action: onProject) {
                Label("Add to Project", systemImage: "folder.badge.plus")
            }
            Button(action: onLater) {
                Label("Later", systemImage: "clock")
            }
            Button(action: onInteresting) {
                Label("Interesting", systemImage: "sparkle")
            }
        }
    }

    private func rowButton(
        _ systemImage: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.caption)
                .frame(width: 20, height: 20)
        }
        .help(help)
    }
}

private struct WaitingRoomInspector: View {
    let item: WaitingRoomItem?
    let dossier: DossierStory?
    let sourceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Evidence")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            Divider()

            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.song.title)
                                .font(.title3)
                                .fontWeight(.semibold)
                            Text(item.song.artist)
                                .foregroundStyle(.secondary)
                            Text(sourceName)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        WaitingRoomProseView(dossier: dossier)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: "text.quote")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Focus a song to read its story.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct WaitingRoomBloomCard: View {
    let item: WaitingRoomItem
    let dossier: DossierStory?
    let sourceName: String
    let onPlay: () -> Void
    let onAdmit: () -> Void
    let onReject: () -> Void
    let onProject: () -> Void
    let onLater: () -> Void
    let onInteresting: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Closer Look")
                    .font(.headline)
                Spacer()
                Text("Esc to return")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 24) {
                        EnvironmentAlbumArtView(
                            coverArtId: item.song.coverArt,
                            size: .extraLarge,
                            flexible: true
                        )
                        .frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.song.title)
                                .font(.largeTitle)
                                .fontWeight(.bold)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(item.song.artist)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Text(item.song.album)
                                .foregroundStyle(.secondary)
                            Label(sourceName, systemImage: "arrow.down.to.line")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button(action: onPlay) {
                                Label("Audition", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Why this is here")
                            .font(.headline)
                        Text(WaitingRoomProse.paragraph(for: dossier))
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Chapter timeline")
                            .font(.headline)
                        ForEach(Array(WaitingRoomProse.timeline(for: item, dossier: dossier).enumerated()), id: \.offset) { _, chapter in
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.65))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 6)
                                Text(chapter)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(28)
            }

            Divider()

            HStack(spacing: 10) {
                Button(action: onAdmit) {
                    Label("Admit", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive, action: onReject) {
                    Label("Reject", systemImage: "xmark.circle")
                }

                Button(action: onProject) {
                    Label("Project", systemImage: "folder.badge.plus")
                }

                Spacer()

                Button(action: onLater) {
                    Label("Later", systemImage: "clock")
                }

                Button(action: onInteresting) {
                    Label("Interesting", systemImage: "sparkle")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(18)
        }
        .frame(maxWidth: 820, maxHeight: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
        .padding(32)
    }
}

private struct WaitingRoomProseView: View {
    let dossier: DossierStory?

    var body: some View {
        if let dossier, dossier.hasTestimony {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(WaitingRoomProse.storyLines(for: dossier).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
        } else {
            Text("The library has no story for this item yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WaitingRoomProjectRequest: Identifiable {
    let id = UUID()
    let itemIds: [String]
    let bloomItemId: String?
}

private struct WaitingRoomProjectPicker: View {
    let projects: [Project]
    let onChoose: (Project) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add to Project")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
            }
            .padding(14)

            Divider()

            if projects.isEmpty {
                Text("No active projects.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(18)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(projects) { project in
                            Button {
                                onChoose(project)
                            } label: {
                                Label(project.name, systemImage: "folder")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 300)
    }
}

private enum WaitingRoomProse {
    static func storyLines(for dossier: DossierStory) -> [String] {
        var lines: [String] = []

        if let waitingRoom = dossier.waitingRoom {
            var sentence = "Arrived in the Waiting Room \(datePhrase(waitingRoom.addedAt)) via \(friendly(waitingRoom.source))"
            if waitingRoom.auditionCount > 0 {
                let times = waitingRoom.auditionCount == 1 ? "once" : "\(waitingRoom.auditionCount) times"
                sentence += ", auditioned \(times)"
                if let last = waitingRoom.lastAuditionedAt {
                    sentence += " (last \(datePhrase(last)))"
                }
            }
            sentence += " — currently \(friendly(waitingRoom.state))."
            lines.append(sentence)
            if let notes = waitingRoom.notes, !notes.isEmpty {
                lines.append("Waiting Room note: “\(notes)”")
            }
        }

        if let admission = dossier.admission {
            var sentence = "Admitted to the Library \(datePhrase(admission.admittedAt)) via \(friendly(admission.admittedBy))"
            if let detail = admission.sourceDetail, !detail.isEmpty {
                sentence += " (\(friendly(detail)))"
            }
            lines.append(sentence + ".")
        }

        for mark in dossier.attentionMarks {
            var sentence = "Marked \(friendly(mark.type)) \(datePhrase(mark.markedAt))"
            if let note = mark.note, !note.isEmpty {
                sentence += ": “\(note)”"
            }
            lines.append(sentence + ".")
        }

        if let likedAt = dossier.likedAt {
            lines.append("Liked \(datePhrase(likedAt)).")
        }
        if let starredAt = dossier.starredAt {
            lines.append("Starred \(datePhrase(starredAt)).")
        }

        if dossier.plays.playCount > 0 {
            let times = dossier.plays.playCount == 1 ? "once" : "\(dossier.plays.playCount) times"
            var sentence = "Played \(times)"
            if let first = dossier.plays.firstPlayedAt {
                sentence += ", first \(datePhrase(first))"
            }
            if let last = dossier.plays.lastPlayedAt {
                sentence += ", most recently \(datePhrase(last))"
            }
            lines.append(sentence + ".")
        }

        if !dossier.projects.isEmpty {
            let names = dossier.projects.map(\.name).joined(separator: ", ")
            lines.append(dossier.projects.count == 1
                ? "Part of the project \(names)."
                : "Part of projects: \(names).")
        }

        for voice in dossier.attributionVoices {
            var sentence = "Sourced from \(voice.sourceDisplayName ?? voice.downloadSource ?? "an unknown source")"
            if let download = voice.downloadSource, voice.sourceDisplayName != nil {
                sentence += " via \(friendly(download))"
            }
            if let context = voice.queryContext, !context.isEmpty {
                sentence += ", in the context “\(context)”"
            }
            lines.append(sentence + ".")
        }

        return lines
    }

    static func paragraph(for dossier: DossierStory?) -> String {
        guard let dossier else {
            return "The library has no recorded provenance or listening evidence for this item yet."
        }
        let lines = storyLines(for: dossier)
        return lines.isEmpty
            ? "The library has no recorded provenance or listening evidence for this item yet."
            : lines.joined(separator: " ")
    }

    static func timeline(for item: WaitingRoomItem, dossier: DossierStory?) -> [String] {
        var chapters = ["Arrived \(datePhrase(item.addedAt)) via \(friendly(item.source))."]
        if let first = item.firstAuditionedAt {
            chapters.append("First auditioned \(datePhrase(first)).")
        }
        if let last = item.lastAuditionedAt, last != item.firstAuditionedAt {
            chapters.append("Last auditioned \(datePhrase(last)); \(item.auditionCount) auditions recorded.")
        } else if item.auditionCount > 0 {
            chapters.append("\(item.auditionCount) audition\(item.auditionCount == 1 ? "" : "s") recorded.")
        }
        for mark in dossier?.attentionMarks ?? [] {
            chapters.append("Marked \(friendly(mark.type)) \(datePhrase(mark.markedAt)).")
        }
        if let admittedAt = item.admittedAt {
            chapters.append("Admitted \(datePhrase(admittedAt)).")
        }
        if let rejectedAt = item.rejectedAt {
            chapters.append("Rejected \(datePhrase(rejectedAt)).")
        }
        return chapters
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func datePhrase(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 30 * 24 * 3600 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return "on \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    static func friendly(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

private enum WaitingRoomFilter: String, CaseIterable, Identifiable {
    case pending = "Pending"
    case interesting = "Interesting"
    case admitted = "Admitted"
    case rejected = "Rejected"
    case all = "All"

    var id: String { rawValue }
}

private struct CompactCurationStatusView: View {
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

#Preview {
    WaitingRoomView()
        .environment(AppState())
}
