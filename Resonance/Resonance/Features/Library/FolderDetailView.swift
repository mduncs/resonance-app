import SwiftUI

struct FolderDetailView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("folderDetailLayoutStyle") private var layoutStyle: FolderLayoutStyle = .list
    let folder: MusicFolder

    @State private var viewState: ViewState = .loading
    @State private var rootDirectory: MusicDirectory?
    @State private var navigationPath: [MusicDirectory] = []
    @State private var projection = FolderBrowserProjection.empty
    @State private var browserStore = FolderBrowserStore()
    @State private var filterText = ""
    @State private var displayLimit = 300
    @State private var displayWindow = FolderBrowserDisplayWindow.empty
    @State private var selectedItemIDs = Set<FolderBrowserSelection>()
    @State private var selectedSongItems: [Song] = []
    @State private var inlineError: ResonanceError?
    @State private var navigationTask: Task<Void, Never>?
    @State private var navigationGeneration = 0
    @State private var actionTask: Task<Void, Never>?
    @State private var actionLifecycle = FolderBrowserActionLifecycle()

    enum ViewState { case loading, empty, error(ResonanceError), populated }
    private enum FolderBrowserSelection: Hashable { case folder(String), song(String) }
    fileprivate struct BreadcrumbItem: Identifiable {
        let position: Int; let name: String; let directory: MusicDirectory?
        var id: Int { position }
    }
    private struct ActionOrigin: Equatable { let serverID: String?; let directoryID: String }
    private enum FolderAction { case play, shuffle, queue, download }

    private var currentDirectory: MusicDirectory? { navigationPath.last ?? rootDirectory }
    private var hasMore: Bool { projection.count > displayLimit }
    private var hasDirectoryContent: Bool { !(currentDirectory?.children.isEmpty ?? true) }
    private var breadcrumbs: [BreadcrumbItem] {
        [BreadcrumbItem(position: 0, name: folder.name, directory: nil)]
            + navigationPath.enumerated().map { BreadcrumbItem(position: $0.offset + 1, name: $0.element.name, directory: $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbHeader
            if let inlineError {
                ErrorBanner(error: inlineError) { self.inlineError = nil }
                    .padding(.horizontal).padding(.top, navigationPath.isEmpty ? 12 : 0).padding(.bottom, 12)
            }
            searchField
            actionStatus
            Group {
                switch viewState {
                case .loading:
                    InlineLoadingStatusView(title: "Loading folder...").padding(.horizontal, 24).padding(.top, 18)
                case .empty: emptyFolderStatus
                case .error(let error): errorStatus(error)
                case .populated: folderContent
                }
            }
        }
        .navigationTitle(currentDirectory?.name ?? folder.name)
        .toolbar { toolbarContent }
        .task { startRootNavigation() }
        .onChange(of: filterText) { _, _ in resetWindowAndProjection() }
        .onChange(of: appState.hiddenSongIds) { _, _ in resetWindowAndProjection() }
        .onChange(of: selectedItemIDs) { _, _ in updateSelectedSongs() }
        .onChange(of: appState.activeServerId) { _, _ in
            browserStore.clear(); rootDirectory = nil; navigationPath.removeAll(); displayLimit = 300; clearSelection(); startRootNavigation()
        }
        .onDisappear { cancelOutstandingWork() }
    }

    @ViewBuilder private var breadcrumbHeader: some View {
        if navigationPath.isEmpty {
            HStack { Label("Server Browser", systemImage: "externaldrive").font(.subheadline).foregroundStyle(.secondary); Spacer() }
                .padding(.horizontal).padding(.vertical, 8).background(.bar)
        } else {
            BreadcrumbBar(items: breadcrumbs) { item in navigateTo(item.position) }
        }
    }

    private var searchField: some View {
        TextField("Filter this folder", text: $filterText).textFieldStyle(.roundedBorder)
            .padding(.horizontal, 20).padding(.top, 12).accessibilityIdentifier("folder-browser-search")
    }

    @ViewBuilder private var actionStatus: some View {
        if actionLifecycle.isBusy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small); Text("Preparing folder…").foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { cancelFolderAction() }; Spacer()
            }.font(.subheadline).padding(.horizontal, 20).padding(.top, 10)
        }
    }

    private var emptyFolderStatus: some View {
        CompactStatusView(title: "Empty Folder", systemImage: "folder", message: "This folder contains no music files.")
            .padding(.horizontal, 24).padding(.top, 18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func errorStatus(_ error: ResonanceError) -> some View {
        CompactStatusView(title: error.errorTitle, systemImage: error.systemImage, message: error.errorDescription,
                          actionTitle: "Retry", actionSystemImage: "arrow.clockwise") { refreshCurrentDirectory() }
            .padding(.horizontal, 24).padding(.top, 18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Layout", selection: $layoutStyle) {
                    ForEach(FolderLayoutStyle.allCases, id: \.self) { style in Label(style.rawValue, systemImage: style.icon).tag(style) }
                }
            } label: { Image(systemName: layoutStyle.icon) }.help("Change layout style")
            Button { beginCurrentFolderAction(.play) } label: { Image(systemName: "play.fill") }
                .disabled(!hasDirectoryContent || actionLifecycle.isBusy)
            Button { beginCurrentFolderAction(.shuffle) } label: { Image(systemName: "shuffle") }
                .disabled(!hasDirectoryContent || actionLifecycle.isBusy)
            Menu {
                if !selectedSongItems.isEmpty {
                    Button { playSelectedSongs() } label: { Label("Play Selected", systemImage: "play.fill") }
                    Button { appState.playbackManager.addToQueue(selectedSongItems) } label: { Label("Add Selected to Queue", systemImage: "text.badge.plus") }
                    Divider()
                }
                Button { beginCurrentFolderAction(.queue) } label: { Label("Add All to Queue", systemImage: "text.badge.plus") }
                Button { beginCurrentFolderAction(.download) } label: { Label("Download", systemImage: "arrow.down.circle") }
                Divider()
                Button { refreshCurrentDirectory() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                if actionLifecycle.isBusy { Button(role: .cancel) { cancelFolderAction() } label: { Label("Cancel Folder Action", systemImage: "xmark") } }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    @ViewBuilder private var folderContent: some View {
        if projection.count == 0 {
            let queryIsEmpty = filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            CompactStatusView(title: queryIsEmpty ? "No Visible Music" : "No Matching Items",
                              systemImage: queryIsEmpty ? "eye.slash" : "magnifyingglass",
                              message: queryIsEmpty ? "Only hidden or unsupported items are in this server folder." : "Try another search in this folder.")
                .padding(.horizontal, 24).padding(.top, 18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            switch layoutStyle { case .list: listContent; case .grid: gridContent }
        }
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            List(selection: $selectedItemIDs) {
                if !displayWindow.folders.isEmpty {
                    Section("Server Folders") {
                        ForEach(displayWindow.folders) { subfolder in
                            FolderListRow(folder: subfolder).tag(FolderBrowserSelection.folder(subfolder.id)).contentShape(Rectangle())
                                .onTapGesture(count: 2) { navigateIntoFolder(subfolder) }.contextMenu { folderContextMenu(for: subfolder) }
                        }
                    }
                }
                if !displayWindow.songs.isEmpty {
                    Section("Server Songs (\(projection.songs.count))") {
                        ForEach(displayWindow.songs.indices, id: \.self) { index in
                            let song = displayWindow.songs[index]
                            folderSongRow(song, index: index).tag(FolderBrowserSelection.song(song.id))
                        }
                    }
                }
            }.listStyle(.inset).onKeyPress(.return) { activateSelection(); return .handled }
            if hasMore { loadMoreButton }
        }
    }

    private var gridContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !displayWindow.folders.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Server Folders").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)], spacing: 16) {
                            ForEach(displayWindow.folders) { subfolder in
                                Button { navigateIntoFolder(subfolder) } label: { FolderGridCard(folder: subfolder) }
                                    .buttonStyle(.plain).contextMenu { folderContextMenu(for: subfolder) }
                            }
                        }
                    }
                }
                if !displayWindow.songs.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Server Songs (\(projection.songs.count))").font(.headline).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
                        ForEach(displayWindow.songs.indices, id: \.self) { index in
                            let song = displayWindow.songs[index]
                            folderSongRow(song, index: index).padding(.horizontal, 16).padding(.vertical, 4)
                            if index < displayWindow.songs.count - 1 { Divider().padding(.leading, 16) }
                        }
                    }.background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1) }
                }
                if hasMore { loadMoreButton.frame(maxWidth: .infinity) }
            }.padding(20)
        }
    }

    private var loadMoreButton: some View {
        Button("Load More") { loadMore() }.padding().accessibilityIdentifier("folder-browser-load-more")
    }

    private func resetWindowAndProjection() {
        displayLimit = 300; clearSelection(); updateProjection()
    }

    private func updateProjection() {
        projection = FolderBrowserProjection(directory: currentDirectory, query: filterText, hiddenSongIDs: appState.hiddenSongIds)
        rebuildDisplayWindow()
    }

    private func rebuildDisplayWindow() {
        displayWindow = projection.displayed(limit: displayLimit)
    }

    private func loadMore() {
        displayLimit += 300
        rebuildDisplayWindow()
    }

    private func clearSelection() {
        selectedItemIDs.removeAll()
        selectedSongItems.removeAll()
    }

    private func updateSelectedSongs() {
        let selectedSongIDs = selectedItemIDs.reduce(into: Set<String>()) { ids, selection in
            if case .song(let id) = selection { ids.insert(id) }
        }
        guard !selectedSongIDs.isEmpty else {
            selectedSongItems.removeAll()
            return
        }
        selectedSongItems = projection.songs.filter { selectedSongIDs.contains($0.id) }
    }

    private func startRootNavigation(bypassCache: Bool = false) { beginNavigation(to: folder.id, isRoot: true, bypassCache: bypassCache) }
    private func navigateIntoFolder(_ subfolder: MusicFolder) { beginNavigation(to: subfolder.id, isRoot: false, bypassCache: false) }

    private func refreshCurrentDirectory() {
        guard let currentDirectory else { startRootNavigation(bypassCache: true); return }
        beginNavigation(to: navigationPath.isEmpty ? folder.id : currentDirectory.id, isRoot: navigationPath.isEmpty, bypassCache: true)
    }

    private func beginNavigation(to directoryID: String, isRoot: Bool, bypassCache: Bool) {
        navigationTask?.cancel(); navigationGeneration &+= 1; cancelFolderAction()
        displayLimit = 300
        clearSelection()
        let generation = navigationGeneration; let serverID = appState.activeServerId; let fallback = currentDirectory
        if !bypassCache, let cached = browserStore.cachedDirectory(serverID: serverID, id: directoryID) {
            applyNavigation(cached, isRoot: isRoot, directoryID: directoryID); return
        }
        viewState = .loading
        navigationTask = Task {
            do {
                let loaded: MusicDirectory
                if isRoot {
                    loaded = try await appState.networkActor.fetchIndexes(musicFolderId: folder.id, folderName: folder.name)
                } else {
                    loaded = try await appState.networkActor.fetchMusicDirectory(id: directoryID)
                }
                guard navigationIsCurrent(generation: generation, serverID: serverID) else { return }
                browserStore.cache(loaded, serverID: serverID, under: directoryID)
                applyNavigation(loaded, isRoot: isRoot, directoryID: directoryID)
            } catch is CancellationError { return
            } catch {
                guard navigationIsCurrent(generation: generation, serverID: serverID) else { return }
                handleLoadFailure(error, fallbackDirectory: fallback)
            }
        }
    }

    private func navigationIsCurrent(generation: Int, serverID: String?) -> Bool {
        !Task.isCancelled && generation == navigationGeneration && appState.activeServerId == serverID
    }

    private func applyNavigation(_ directory: MusicDirectory, isRoot: Bool, directoryID: String) {
        if isRoot { rootDirectory = directory; navigationPath.removeAll()
        } else if navigationPath.last?.id == directoryID { navigationPath[navigationPath.count - 1] = directory
        } else { navigationPath.append(directory) }
        inlineError = nil; viewState = directory.children.isEmpty ? .empty : .populated; resetWindowAndProjection()
    }

    private func navigateTo(_ position: Int) {
        navigationTask?.cancel(); navigationGeneration &+= 1; cancelFolderAction()
        navigationPath = position == 0 ? [] : Array(navigationPath.prefix(position))
        inlineError = nil; viewState = currentDirectory?.children.isEmpty == true ? .empty : .populated; resetWindowAndProjection()
    }

    private func beginCurrentFolderAction(_ action: FolderAction) {
        guard let directory = currentDirectory else { return }
        let origin = ActionOrigin(serverID: appState.activeServerId, directoryID: directory.id)
        beginFolderAction(origin: origin) {
            let songs = try await FolderTraversalService.fetchVisibleSongs(in: directory, using: appState.networkActor, hiddenSongIds: appState.hiddenSongIds)
            guard self.actionIsCurrent(origin: origin) else { return }
            switch action {
            case .play: await appState.playbackManager.play(songs: songs)
            case .shuffle: await appState.playbackManager.play(songs: songs.shuffled())
            case .queue: appState.playbackManager.addToQueue(songs)
            case .download:
                guard let server = await appState.networkActor.activeServer, server.id.uuidString == origin.serverID else { return }
                await appState.cacheActor.queueDownloads(songs: songs, serverId: server.id)
            }
        }
    }

    private func beginSubfolderAction(_ subfolder: MusicFolder, action: FolderAction) {
        let origin = ActionOrigin(serverID: appState.activeServerId, directoryID: currentDirectory?.id ?? folder.id)
        beginFolderAction(origin: origin) {
            let subdirectory = try await appState.networkActor.fetchMusicDirectory(id: subfolder.id)
            let songs = try await FolderTraversalService.fetchVisibleSongs(in: subdirectory, using: appState.networkActor,
                hiddenSongIds: appState.hiddenSongIds, initiallyVisitedDirectoryIDs: [subfolder.id])
            guard self.actionIsCurrent(origin: origin) else { return }
            switch action {
            case .play: await appState.playbackManager.play(songs: songs)
            case .shuffle: await appState.playbackManager.play(songs: songs.shuffled())
            case .queue: appState.playbackManager.addToQueue(songs)
            case .download:
                guard let server = await appState.networkActor.activeServer, server.id.uuidString == origin.serverID else { return }
                await appState.cacheActor.queueDownloads(songs: songs, serverId: server.id)
            }
        }
    }

    private func beginFolderAction(origin: ActionOrigin, work: @escaping @MainActor () async throws -> Void) {
        actionTask?.cancel()
        let generation = actionLifecycle.begin()
        inlineError = nil
        actionTask = Task {
            do {
                try await work()
                guard actionIsCurrent(origin: origin, generation: generation) else { return }
                actionLifecycle.finish(generation)
            } catch is CancellationError {
                guard actionIsCurrent(origin: origin, generation: generation) else { return }
                actionLifecycle.finish(generation)
            } catch {
                guard actionIsCurrent(origin: origin, generation: generation) else { return }
                actionLifecycle.finish(generation)
                inlineError = resonanceError(from: error)
            }
        }
    }

    private func actionIsCurrent(origin: ActionOrigin, generation: Int? = nil) -> Bool {
        guard !Task.isCancelled,
              appState.activeServerId == origin.serverID,
              currentDirectory?.id == origin.directoryID else { return false }
        if let generation { return actionLifecycle.isCurrent(generation) }
        return true
    }

    private func cancelFolderAction() { actionTask?.cancel(); actionTask = nil; actionLifecycle.cancel() }

    private func playSelectedSongs() {
        guard !selectedSongItems.isEmpty else { return }
        Task { await appState.playbackManager.play(songs: selectedSongItems) }
    }

    private func activateSelection() {
        if let folder = displayWindow.folders.first(where: { selectedItemIDs.contains(.folder($0.id)) }) { navigateIntoFolder(folder) }
        else { playSelectedSongs() }
    }

    private func handleLoadFailure(_ error: Error, fallbackDirectory: MusicDirectory?) {
        let resolved = resonanceError(from: error)
        if let fallbackDirectory { inlineError = resolved; viewState = fallbackDirectory.children.isEmpty ? .empty : .populated }
        else { viewState = .error(resolved) }
    }
    private func resonanceError(from error: Error) -> ResonanceError { (error as? ResonanceError) ?? .networkError(error) }
    private func cancelOutstandingWork() { navigationGeneration &+= 1; navigationTask?.cancel(); cancelFolderAction() }

    @ViewBuilder private func folderSongRow(_ song: Song, index: Int) -> some View {
        FolderSongRow(song: song, index: index + 1).contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard let index = projection.songs.firstIndex(where: { $0.id == song.id }) else { return }
                Task { await appState.playbackManager.play(songs: projection.songs, startingAt: index) }
            }
            .contextMenu {
                let targets = selectedItemIDs.contains(.song(song.id)) && !selectedSongItems.isEmpty ? selectedSongItems : [song]
                if targets.count > 1 { BulkSongContextMenu(songs: targets) } else { SongContextMenu(song: song) }
            }
    }

    @ViewBuilder private func folderContextMenu(for subfolder: MusicFolder) -> some View {
        Button { beginSubfolderAction(subfolder, action: .play) } label: { Label("Play", systemImage: "play.fill") }
        Button { beginSubfolderAction(subfolder, action: .shuffle) } label: { Label("Shuffle", systemImage: "shuffle") }
        Divider()
        Button { beginSubfolderAction(subfolder, action: .queue) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
        Button { beginSubfolderAction(subfolder, action: .download) } label: { Label("Download", systemImage: "arrow.down.circle") }
    }
}

private struct BreadcrumbBar: View {
    let items: [FolderDetailView.BreadcrumbItem]
    let onNavigate: (FolderDetailView.BreadcrumbItem) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Label("Server Browser", systemImage: "externaldrive").font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                ForEach(items) { item in
                    if item.position > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                    Button { onNavigate(item) } label: {
                        HStack(spacing: 4) { if item.position == 0 { Image(systemName: "folder.fill").font(.caption) }; Text(item.name).lineLimit(1) }
                            .font(.subheadline).foregroundStyle(item.position == items.count - 1 ? .primary : .secondary)
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal).padding(.vertical, 8)
        }.background(.bar)
    }
}

private struct FolderListRow: View {
    let folder: MusicFolder
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(.blue).frame(width: 44, height: 44).background(.blue.opacity(0.1)).cornerRadius(8)
            Text(folder.name).font(.body); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }.padding(.vertical, 4)
    }
}

private struct FolderSongRow: View {
    @Environment(AppState.self) private var appState
    let song: Song; let index: Int
    private var isPlaying: Bool { appState.nowPlaying?.id == song.id && appState.playbackState == .playing }
    var body: some View {
        HStack(spacing: 12) {
            Group { if isPlaying { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor) } else { Text("\(index)").foregroundStyle(.secondary) } }
                .font(.subheadline).monospacedDigit().frame(width: 30, alignment: .trailing)
            EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .small).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.body).fontWeight(isPlaying ? .semibold : .regular).lineLimit(1)
                HStack(spacing: 4) { Text(song.artist); if !song.album.isEmpty { Text("-"); Text(song.album) } }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if !song.suffix.isEmpty { Text(song.suffix.uppercased()).font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 4).padding(.vertical, 1).background(.quaternary).cornerRadius(2) }
                if let bitRate = song.bitRate { Text("\(bitRate) kbps").font(.caption2).foregroundStyle(.tertiary) }
            }
            Text(song.formattedDuration).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }.padding(.vertical, 4).contentShape(Rectangle())
    }
}

#Preview { NavigationStack { FolderDetailView(folder: MusicFolder(id: "1", name: "Music Library")).environment(AppState()) } }
