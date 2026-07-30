import SwiftUI

struct FolderDetailView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("folderDetailLayoutStyle") private var layoutStyle: FolderLayoutStyle = .list
    let folder: MusicFolder

    @State private var viewState: ViewState = .loading
    @State private var directory: MusicDirectory?
    @State private var navigationPath: [MusicDirectory] = []
    @State private var inlineError: ResonanceError?

    enum ViewState {
        case loading
        case empty
        case error(ResonanceError)
        case populated
    }

    private var currentDirectory: MusicDirectory? {
        navigationPath.last ?? directory
    }

    private var breadcrumbs: [BreadcrumbItem] {
        var items: [BreadcrumbItem] = [BreadcrumbItem(id: folder.id, name: folder.name, directory: nil)]
        for dir in navigationPath {
            items.append(BreadcrumbItem(id: dir.id, name: dir.name, directory: dir))
        }
        return items
    }

    private var folders: [MusicFolder] {
        guard let dir = currentDirectory else { return [] }
        return dir.children.compactMap { child in
            if case .folder(let folder) = child {
                return folder
            }
            return nil
        }
    }

    private var songs: [Song] {
        guard let dir = currentDirectory else { return [] }
        return dir.children.compactMap { child in
            if case .song(let song) = child {
                return song
            }
            return nil
        }.filter { !appState.hiddenSongIds.contains($0.id) }
    }

    private var hasActionableContent: Bool {
        !folders.isEmpty || !songs.isEmpty
    }

    private var isCurrentDirectoryDisplayEmpty: Bool {
        folders.isEmpty && songs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Breadcrumb navigation
            if !navigationPath.isEmpty {
                BreadcrumbBar(items: breadcrumbs) { item in
                    navigateTo(item)
                }
            } else {
                HStack {
                    Label("Server Browser", systemImage: "externaldrive")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }

            if let inlineError {
                ErrorBanner(error: inlineError) {
                    self.inlineError = nil
                }
                .padding(.horizontal)
                .padding(.top, navigationPath.isEmpty ? 12 : 0)
                .padding(.bottom, 12)
            }

            // Content
            Group {
                switch viewState {
                case .loading:
                    InlineLoadingStatusView(title: "Loading folder...")
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                case .empty:
                    CompactStatusView(
                        title: "Empty Folder",
                        systemImage: "folder",
                        message: "This folder contains no music files."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .error(let error):
                    CompactStatusView(
                        title: error.errorTitle,
                        systemImage: error.systemImage,
                        message: error.errorDescription,
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise"
                    ) {
                        Task {
                            if navigationPath.isEmpty {
                                await loadRootFolder()
                            } else if let dir = currentDirectory {
                                await loadDirectory(dir.id)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .populated:
                    folderContent
                }
            }
        }
        .navigationTitle(currentDirectory?.name ?? folder.name)
        .toolbar {
            // .primaryAction keeps these trailing; without an explicit placement
            // .automatic drops them next to the back chevron, where they read as
            // a second transport cluster competing with the floating bar.
            // Folder browsing has no in-page header, so Play/Shuffle stay here.
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Layout", selection: $layoutStyle) {
                        ForEach(FolderLayoutStyle.allCases, id: \.self) { style in
                            Label(style.rawValue, systemImage: style.icon)
                                .tag(style)
                        }
                    }
                } label: {
                    Image(systemName: layoutStyle.icon)
                }
                .help("Change layout style")

                Button {
                    Task {
                        await playFolder()
                    }
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(!hasActionableContent)

                Button {
                    Task {
                        await playFolder(shuffled: true)
                    }
                } label: {
                    Image(systemName: "shuffle")
                }
                .disabled(!hasActionableContent)

                Menu {
                    Button {
                        Task {
                            await addCurrentFolderToQueue()
                        }
                    } label: {
                        Label("Add All to Queue", systemImage: "text.badge.plus")
                    }
                    .disabled(!hasActionableContent)

                    Button {
                        Task {
                            await downloadCurrentFolder()
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .disabled(!hasActionableContent)

                    Divider()

                    Button {
                        Task {
                            await refreshCurrentDirectory()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await loadRootFolder()
        }
    }

    @ViewBuilder
    private var folderContent: some View {
        if isCurrentDirectoryDisplayEmpty {
            CompactStatusView(
                title: "No Visible Music",
                systemImage: "eye.slash",
                message: "Only hidden or unsupported items are in this server folder."
            )
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            switch layoutStyle {
        case .list:
            List {
                if !folders.isEmpty {
                    Section("Server Folders") {
                        ForEach(folders) { subfolder in
                            FolderListRow(folder: subfolder)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task {
                                        await navigateIntoFolder(subfolder)
                                    }
                                }
                                .contextMenu {
                                    folderContextMenu(for: subfolder)
                                }
                        }
                    }
                }

                if !songs.isEmpty {
                    Section("Server Songs (\(songs.count))") {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            folderSongRow(song, index: index)
                        }
                    }
                }
            }
            .listStyle(.inset)
        case .grid:
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !folders.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Server Folders")
                                .font(.headline)

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)],
                                spacing: 16
                            ) {
                                ForEach(folders) { subfolder in
                                    Button {
                                        Task {
                                            await navigateIntoFolder(subfolder)
                                        }
                                    } label: {
                                        FolderGridCard(folder: subfolder)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        folderContextMenu(for: subfolder)
                                    }
                                }
                            }
                        }
                    }

                    if !songs.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Server Songs (\(songs.count))")
                                .font(.headline)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                                .padding(.bottom, 8)

                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                folderSongRow(song, index: index)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 4)

                                if index < songs.count - 1 {
                                    Divider()
                                        .padding(.leading, 16)
                                }
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        }
                    }
                }
                .padding(20)
            }
            }
        }
    }

    private func loadRootFolder() async {
        let fallbackDirectory = directory
        viewState = .loading

        do {
            let dir = try await appState.networkActor.fetchIndexes(musicFolderId: folder.id, folderName: folder.name)
            directory = dir
            inlineError = nil
            viewState = dir.children.isEmpty ? .empty : .populated
        } catch is CancellationError {
            return
        } catch {
            handleLoadFailure(error, fallbackDirectory: fallbackDirectory)
        }
    }

    private func loadDirectory(_ id: String) async {
        let fallbackDirectory = currentDirectory
        viewState = .loading

        do {
            let dir = try await appState.networkActor.fetchMusicDirectory(id: id)
            if navigationPath.isEmpty {
                directory = dir
            } else {
                navigationPath[navigationPath.count - 1] = dir
            }
            inlineError = nil
            viewState = dir.children.isEmpty ? .empty : .populated
        } catch is CancellationError {
            return
        } catch {
            handleLoadFailure(error, fallbackDirectory: fallbackDirectory)
        }
    }

    private func navigateIntoFolder(_ subfolder: MusicFolder) async {
        let fallbackDirectory = currentDirectory
        viewState = .loading

        do {
            let subdir = try await appState.networkActor.fetchMusicDirectory(id: subfolder.id)
            navigationPath.append(subdir)
            inlineError = nil
            viewState = subdir.children.isEmpty ? .empty : .populated
        } catch is CancellationError {
            return
        } catch {
            handleLoadFailure(error, fallbackDirectory: fallbackDirectory)
        }
    }

    private func navigateTo(_ item: BreadcrumbItem) {
        if item.directory == nil {
            navigationPath.removeAll()
        } else if let index = navigationPath.firstIndex(where: { $0.id == item.id }) {
            navigationPath = Array(navigationPath.prefix(through: index))
        }
        inlineError = nil
        if let dir = currentDirectory {
            viewState = dir.children.isEmpty ? .empty : .populated
        }
    }

    private func playFolder(shuffled: Bool = false) async {
        guard let currentDirectory else { return }

        do {
            inlineError = nil
            var songsToPlay = try await FolderTraversalService.fetchVisibleSongs(
                in: currentDirectory,
                using: appState.networkActor,
                hiddenSongIds: appState.hiddenSongIds
            )
            guard !songsToPlay.isEmpty else { return }
            if shuffled {
                songsToPlay.shuffle()
            }
            await appState.playbackManager.play(songs: songsToPlay)
        } catch is CancellationError {
            return
        } catch {
            inlineError = resonanceError(from: error)
        }
    }

    private func playFolderContents(_ subfolder: MusicFolder, shuffled: Bool = false) async {
        do {
            inlineError = nil
            var songsToPlay = try await visibleSongs(in: subfolder)
            guard !songsToPlay.isEmpty else { return }
            if shuffled { songsToPlay.shuffle() }
            await appState.playbackManager.play(songs: songsToPlay)
        } catch is CancellationError {
            return
        } catch {
            inlineError = resonanceError(from: error)
        }
    }

    private func addFolderToQueue(_ subfolder: MusicFolder) async {
        do {
            inlineError = nil
            let songsToAdd = try await visibleSongs(in: subfolder)
            appState.playbackManager.addToQueue(songsToAdd)
        } catch is CancellationError {
            return
        } catch {
            inlineError = resonanceError(from: error)
        }
    }

    private func addCurrentFolderToQueue() async {
        guard let currentDirectory else { return }

        do {
            inlineError = nil
            let songsToAdd = try await FolderTraversalService.fetchVisibleSongs(
                in: currentDirectory,
                using: appState.networkActor,
                hiddenSongIds: appState.hiddenSongIds
            )
            appState.playbackManager.addToQueue(songsToAdd)
        } catch is CancellationError {
            return
        } catch {
            inlineError = resonanceError(from: error)
        }
    }

    private func downloadFolder(_ subfolder: MusicFolder) async {
        guard let server = await appState.networkActor.activeServer else {
            inlineError = .notConfigured
            return
        }

        do {
            inlineError = nil
            let songsToDownload = try await visibleSongs(in: subfolder)
            await appState.cacheActor.queueDownloads(songs: songsToDownload, serverId: server.id)
        } catch is CancellationError {
            return
        } catch {
            inlineError = resonanceError(from: error)
        }
    }

    private func downloadCurrentFolder() async {
        guard let currentDirectory else { return }
        guard let server = await appState.networkActor.activeServer else {
            inlineError = .notConfigured
            return
        }

        do {
            inlineError = nil
            let songsToDownload = try await FolderTraversalService.fetchVisibleSongs(
                in: currentDirectory,
                using: appState.networkActor,
                hiddenSongIds: appState.hiddenSongIds
            )
            await appState.cacheActor.queueDownloads(songs: songsToDownload, serverId: server.id)
        } catch is CancellationError {
            return
        } catch {
            inlineError = resonanceError(from: error)
        }
    }

    private func refreshCurrentDirectory() async {
        if navigationPath.isEmpty {
            await loadRootFolder()
        } else if let dir = currentDirectory {
            await loadDirectory(dir.id)
        }
    }

    private func visibleSongs(in subfolder: MusicFolder) async throws -> [Song] {
        let subdirectory = try await appState.networkActor.fetchMusicDirectory(id: subfolder.id)
        return try await FolderTraversalService.fetchVisibleSongs(
            in: subdirectory,
            using: appState.networkActor,
            hiddenSongIds: appState.hiddenSongIds,
            initiallyVisitedDirectoryIDs: [subfolder.id]
        )
    }

    private func handleLoadFailure(_ error: Error, fallbackDirectory: MusicDirectory?) {
        let resolvedError = resonanceError(from: error)

        if let fallbackDirectory {
            inlineError = resolvedError
            viewState = fallbackDirectory.children.isEmpty ? .empty : .populated
        } else {
            viewState = .error(resolvedError)
        }
    }

    private func resonanceError(from error: Error) -> ResonanceError {
        if let resonanceError = error as? ResonanceError {
            return resonanceError
        }
        return .networkError(error)
    }

    @ViewBuilder
    private func folderSongRow(_ song: Song, index: Int) -> some View {
        FolderSongRow(song: song, index: index + 1)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                Task {
                    await appState.playbackManager.play(songs: songs, startingAt: index)
                }
            }
            .contextMenu {
                SongContextMenu(song: song)
            }
    }

    @ViewBuilder
    private func folderContextMenu(for subfolder: MusicFolder) -> some View {
        Button {
            Task {
                await playFolderContents(subfolder)
            }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            Task {
                await playFolderContents(subfolder, shuffled: true)
            }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Divider()

        Button {
            Task {
                await addFolderToQueue(subfolder)
            }
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }

        Button {
            Task {
                await downloadFolder(subfolder)
            }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
    }
}

// MARK: - Breadcrumb Bar

private struct BreadcrumbItem: Identifiable {
    let id: String
    let name: String
    let directory: MusicDirectory?
}

private struct BreadcrumbBar: View {
    let items: [BreadcrumbItem]
    let onNavigate: (BreadcrumbItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Label("Server Browser", systemImage: "externaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Button {
                        onNavigate(item)
                    } label: {
                        HStack(spacing: 4) {
                            if index == 0 {
                                Image(systemName: "folder.fill")
                                    .font(.caption)
                            }
                            Text(item.name)
                                .lineLimit(1)
                        }
                        .font(.subheadline)
                        .foregroundStyle(index == items.count - 1 ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

// MARK: - Folder List Row

private struct FolderListRow: View {
    let folder: MusicFolder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
                .background(.blue.opacity(0.1))
                .cornerRadius(8)

            Text(folder.name)
                .font(.body)

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Folder Song Row

private struct FolderSongRow: View {
    @Environment(AppState.self) private var appState
    let song: Song
    let index: Int

    private var isPlaying: Bool {
        appState.nowPlaying?.id == song.id && appState.playbackState == .playing
    }

    var body: some View {
        HStack(spacing: 12) {
            // Track number or playing indicator
            Group {
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("\(index)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .monospacedDigit()
            .frame(width: 30, alignment: .trailing)

            // Album art
            EnvironmentAlbumArtView(coverArtId: song.coverArt, size: .small)
                .frame(width: 40, height: 40)

            // Song info
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(song.artist)
                    if !song.album.isEmpty {
                        Text("-")
                        Text(song.album)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if !song.suffix.isEmpty {
                    Text(song.suffix.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .cornerRadius(2)
                }

                if let bitRate = song.bitRate {
                    Text("\(bitRate) kbps")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(song.formattedDuration)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        FolderDetailView(folder: MusicFolder(id: "1", name: "Music Library"))
            .environment(AppState())
    }
}
