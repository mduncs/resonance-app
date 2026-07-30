import SwiftUI

enum FolderLayoutStyle: String, CaseIterable {
    case list = "List"
    case grid = "Grid"

    var icon: String {
        switch self {
        case .list:
            return "list.bullet"
        case .grid:
            return "square.grid.2x2"
        }
    }
}

enum FolderTraversalService {
    static func fetchVisibleSongs(
        in folder: MusicFolder,
        using networkActor: NetworkActor,
        hiddenSongIds: Set<String>
    ) async throws -> [Song] {
        let rootDirectory = try await networkActor.fetchIndexes(
            musicFolderId: folder.id,
            folderName: folder.name
        )
        return try await fetchVisibleSongs(
            in: rootDirectory,
            using: networkActor,
            hiddenSongIds: hiddenSongIds,
            initiallyVisitedDirectoryIDs: [folder.id, rootDirectory.id]
        )
    }

    static func fetchVisibleSongs(
        in directory: MusicDirectory,
        using networkActor: NetworkActor,
        hiddenSongIds: Set<String>,
        initiallyVisitedDirectoryIDs: Set<String> = []
    ) async throws -> [Song] {
        var collectedSongs: [Song] = []
        var seenSongIds = Set<String>()
        var visitedDirectoryIDs = initiallyVisitedDirectoryIDs
        var pendingDirectories = [directory]
        var currentIndex = 0

        visitedDirectoryIDs.insert(directory.id)

        while currentIndex < pendingDirectories.count {
            let currentDirectory = pendingDirectories[currentIndex]
            currentIndex += 1

            appendVisibleSongs(
                from: currentDirectory,
                into: &collectedSongs,
                seenSongIds: &seenSongIds,
                hiddenSongIds: hiddenSongIds
            )

            for childFolder in childFolders(in: currentDirectory) {
                guard visitedDirectoryIDs.insert(childFolder.id).inserted else { continue }
                let childDirectory = try await networkActor.fetchMusicDirectory(id: childFolder.id)
                pendingDirectories.append(childDirectory)
            }
        }

        return collectedSongs
    }

    private static func childFolders(in directory: MusicDirectory) -> [MusicFolder] {
        directory.children.compactMap { child in
            guard case .folder(let folder) = child else { return nil }
            return folder
        }
    }

    private static func appendVisibleSongs(
        from directory: MusicDirectory,
        into songs: inout [Song],
        seenSongIds: inout Set<String>,
        hiddenSongIds: Set<String>
    ) {
        for child in directory.children {
            guard case .song(let song) = child else { continue }
            guard !hiddenSongIds.contains(song.id) else { continue }
            guard seenSongIds.insert(song.id).inserted else { continue }
            songs.append(song)
        }
    }
}

struct FoldersView: View {
    @Environment(AppState.self) private var appState
    @State private var musicFolders: [MusicFolder] = []
    @State private var isLoading = true
    @State private var error: ResonanceError?
    @State private var actionError: ResonanceError?
    @AppStorage("foldersRootLayoutStyle") private var layoutStyle: FolderLayoutStyle = .list

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folders")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Label(
                        musicFolders.isEmpty ? "Server Browser" : "Server Browser - \(musicFolders.count) folders",
                        systemImage: "externaldrive"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Layout", selection: $layoutStyle) {
                    ForEach(FolderLayoutStyle.allCases, id: \.self) { style in
                        Image(systemName: style.icon)
                            .tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Change layout style")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if let actionError {
                ErrorBanner(error: actionError) {
                    self.actionError = nil
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            Group {
                if isLoading {
                    InlineLoadingStatusView(title: "Loading folders...")
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                } else if let error {
                    CompactStatusView(
                        title: error.errorTitle,
                        systemImage: error.systemImage,
                        message: error.errorDescription,
                        actionTitle: "Retry",
                        actionSystemImage: "arrow.clockwise"
                    ) {
                        Task { await loadMusicFolders() }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if musicFolders.isEmpty {
                    CompactStatusView(
                        title: "No Folders",
                        systemImage: "folder",
                        message: "Music folders from your server will appear here."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    switch layoutStyle {
                    case .list:
                        List(musicFolders) { folder in
                            NavigationLink(value: folder) {
                                FolderRow(folder: folder)
                            }
                            .contextMenu {
                                folderContextMenu(for: folder)
                            }
                        }
                        .listStyle(.inset)
                        .frame(minHeight: 240, maxHeight: .infinity)
                    case .grid:
                        ScrollView {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)],
                                spacing: 16
                            ) {
                                ForEach(musicFolders) { folder in
                                    NavigationLink(value: folder) {
                                        FolderGridCard(folder: folder)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        folderContextMenu(for: folder)
                                    }
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .task {
            await loadMusicFolders()
        }
    }

    private func loadMusicFolders() async {
        isLoading = true
        error = nil

        do {
            musicFolders = try await appState.networkActor.fetchMusicFolders()
        } catch let err as ResonanceError {
            error = err
        } catch {
            self.error = .networkError(error)
        }

        isLoading = false
    }

    @ViewBuilder
    private func folderContextMenu(for folder: MusicFolder) -> some View {
        Button {
            Task {
                await play(folder)
            }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            Task {
                await play(folder, shuffled: true)
            }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Divider()

        Button {
            Task {
                await addToQueue(folder)
            }
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }

        Button {
            Task {
                await download(folder)
            }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
    }

    private func play(_ folder: MusicFolder, shuffled: Bool = false) async {
        do {
            actionError = nil
            var songs = try await FolderTraversalService.fetchVisibleSongs(
                in: folder,
                using: appState.networkActor,
                hiddenSongIds: appState.hiddenSongIds
            )
            guard !songs.isEmpty else { return }
            if shuffled {
                songs.shuffle()
            }
            await appState.playbackManager.play(songs: songs)
        } catch is CancellationError {
            return
        } catch let error as ResonanceError {
            actionError = error
        } catch {
            actionError = .networkError(error)
        }
    }

    private func addToQueue(_ folder: MusicFolder) async {
        do {
            actionError = nil
            let songs = try await FolderTraversalService.fetchVisibleSongs(
                in: folder,
                using: appState.networkActor,
                hiddenSongIds: appState.hiddenSongIds
            )
            appState.playbackManager.addToQueue(songs)
        } catch is CancellationError {
            return
        } catch let error as ResonanceError {
            actionError = error
        } catch {
            actionError = .networkError(error)
        }
    }

    private func download(_ folder: MusicFolder) async {
        guard let server = await appState.networkActor.activeServer else {
            actionError = .notConfigured
            return
        }

        do {
            actionError = nil
            let songs = try await FolderTraversalService.fetchVisibleSongs(
                in: folder,
                using: appState.networkActor,
                hiddenSongIds: appState.hiddenSongIds
            )
            await appState.cacheActor.queueDownloads(songs: songs, serverId: server.id)
        } catch is CancellationError {
            return
        } catch let error as ResonanceError {
            actionError = error
        } catch {
            actionError = .networkError(error)
        }
    }
}

struct FolderRow: View {
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
        }
        .padding(.vertical, 4)
    }
}

struct FolderGridCard: View {
    let folder: MusicFolder
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.blue.opacity(isHovered ? 0.18 : 0.12))
                .frame(height: 120)
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.blue)
                }

            Text(folder.name)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(isHovered ? 0.12 : 0.04), radius: isHovered ? 10 : 4, y: 4)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

#Preview {
    NavigationStack {
        FoldersView()
            .environment(AppState())
    }
}
