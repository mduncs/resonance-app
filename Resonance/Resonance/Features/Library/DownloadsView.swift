import SwiftUI
import AppKit

struct DownloadsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewState: ViewState = .loading
    @State private var downloads: [DownloadedSong] = []
    @State private var selection = Set<String>()
    @State private var sortOrder: SortOrder = .title
    @State private var showDeleteConfirmation = false
    @State private var itemsToDelete: [DownloadedSong] = []

    enum ViewState {
        case loading
        case empty
        case populated
    }

    enum SortOrder: String, CaseIterable {
        case title = "Title"
        case artist = "Artist"
        case album = "Album"
        case size = "Size"
    }

    private var sortedDownloads: [DownloadedSong] {
        switch sortOrder {
        case .title:
            return downloads.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case .artist:
            return downloads.sorted { $0.displayArtist.localizedCaseInsensitiveCompare($1.displayArtist) == .orderedAscending }
        case .album:
            return downloads.sorted { $0.displayAlbum.localizedCaseInsensitiveCompare($1.displayAlbum) == .orderedAscending }
        case .size:
            return downloads.sorted { $0.fileSize > $1.fileSize }
        }
    }

    private var totalSize: String {
        let bytes = downloads.reduce(0) { $0 + $1.fileSize }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var downloadProgress: DownloadProgressState {
        appState.cacheActor.downloadProgress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Apple Music-style page header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloads")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    if !downloads.isEmpty {
                        Text("\(downloads.count) songs - \(totalSize)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        itemsToDelete = downloads
                        showDeleteConfirmation = true
                    } label: {
                        Label("Remove All Downloads", systemImage: "trash")
                    }
                    .disabled(downloads.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Content
            Group {
                switch viewState {
                case .loading:
                    InlineLoadingStatusView(title: "Loading downloads...")
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                case .empty:
                    VStack(alignment: .leading, spacing: 12) {
                        if downloadProgress.isDownloading {
                            ActiveDownloadsBar(progress: downloadProgress)
                        }

                        if !downloadProgress.failedDownloads.isEmpty {
                            FailedDownloadsSection(progress: downloadProgress)
                        }

                        CompactStatusView(
                            title: emptyStateTitle,
                            systemImage: emptyStateSymbol,
                            message: emptyStateDescription
                        )
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                case .populated:
                    VStack(spacing: 0) {
                        // Active downloads section
                        if downloadProgress.isDownloading {
                            ActiveDownloadsBar(progress: downloadProgress)
                        }

                        if !downloadProgress.failedDownloads.isEmpty {
                            FailedDownloadsSection(progress: downloadProgress)
                            Divider()
                        }

                        // Selection actions bar
                        if !selection.isEmpty {
                            HStack {
                                Text("\(selection.count) selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Button(role: .destructive) {
                                    itemsToDelete = downloads.filter { selection.contains($0.id) }
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Remove \(selection.count)", systemImage: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                            .background(.bar)

                            Divider()
                        }

                        // Downloads list
                        List(selection: $selection) {
                            ForEach(sortedDownloads) { item in
                                DownloadedSongRow(item: item)
                                    .tag(item.id)
                                    .contextMenu {
                                        DownloadedSongContextMenu(item: item) {
                                            await removeDownload(item)
                                        }
                                    }
                            }
                            .onDelete { indexSet in
                                let toDelete = indexSet.map { sortedDownloads[$0] }
                                itemsToDelete = toDelete
                                showDeleteConfirmation = true
                            }
                        }
                        .listStyle(.inset)
                        .frame(minHeight: 240, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .confirmationDialog(
            "Remove Downloads?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    for item in itemsToDelete {
                        await removeDownload(item)
                    }
                    itemsToDelete = []
                }
            }
            Button("Cancel", role: .cancel) {
                itemsToDelete = []
            }
        } message: {
            if itemsToDelete.count == 1 {
                Text("This will remove \"\(itemsToDelete.first?.displayTitle ?? "")\" from your device.")
            } else {
                Text("This will remove \(itemsToDelete.count) downloaded songs from your device.")
            }
        }
        .task {
            await loadDownloads()
        }
        .onChange(of: downloadProgress.recentlyCompleted) { _, completed in
            // Refresh when downloads complete
            if !completed.isEmpty {
                Task {
                    await loadDownloads()
                    await MainActor.run {
                        downloadProgress.clearCompleted()
                    }
                }
            }
        }
    }

    private func loadDownloads() async {
        guard let server = appState.activeServer else {
            downloads = []
            viewState = .empty
            return
        }

        let downloadedSongs = await appState.cacheActor.enumerateDownloadedSongs(serverId: server.id)

        if downloadedSongs.isEmpty {
            downloads = []
            viewState = .empty
            return
        }

        downloads = downloadedSongs
        viewState = .populated
    }

    private func removeDownload(_ item: DownloadedSong) async {
        guard let server = appState.activeServer else { return }

        await appState.cacheActor.deleteDownload(songId: item.songId, serverId: server.id)

        downloads.removeAll { $0.id == item.id }
        selection.remove(item.id)

        if downloads.isEmpty {
            viewState = .empty
        }
    }

    private var emptyStateTitle: String {
        if downloadProgress.isDownloading {
            return "Downloading Songs"
        }
        if !downloadProgress.failedDownloads.isEmpty {
            return "Downloads Need Attention"
        }
        return "No Downloads"
    }

    private var emptyStateSymbol: String {
        if downloadProgress.isDownloading {
            return "arrow.down.circle.fill"
        }
        if !downloadProgress.failedDownloads.isEmpty {
            return "exclamationmark.triangle"
        }
        return "arrow.down.circle"
    }

    private var emptyStateDescription: String {
        if downloadProgress.isDownloading {
            return "Downloaded songs will appear here as soon as they finish."
        }
        if !downloadProgress.failedDownloads.isEmpty {
            return "Some downloads failed. Retry them from the song, album, or playlist menu."
        }
        return "Download songs for offline listening. Right-click any song and select Download."
    }
}

// MARK: - Active Downloads Bar

struct ActiveDownloadsBar: View {
    let progress: DownloadProgressState

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)

                Text("Downloading \(progress.activeDownloads.count) songs...")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !progress.failedDownloads.isEmpty {
                    Text("\(progress.failedDownloads.count) failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            // Individual download progress
            ForEach(Array(progress.activeDownloads.keys.sorted()), id: \.self) { songId in
                if let progressValue = progress.activeDownloads[songId] {
                    HStack {
                        Text(progress.displayTitle(for: songId))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)

                        Spacer()

                        ProgressView(value: progressValue)
                            .frame(width: 100)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

struct FailedDownloadsSection: View {
    let progress: DownloadProgressState

    private var sortedFailures: [(songId: String, error: String)] {
        progress.failedDownloads
            .map { (songId: $0.key, error: $0.value) }
            .sorted { lhs, rhs in
                progress.displayTitle(for: lhs.songId)
                    .localizedCaseInsensitiveCompare(progress.displayTitle(for: rhs.songId)) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                sortedFailures.count == 1 ? "1 Download Failed" : "\(sortedFailures.count) Downloads Failed",
                systemImage: "exclamationmark.triangle.fill"
            )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)

            ForEach(sortedFailures, id: \.songId) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.displayTitle(for: failure.songId))
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(failure.error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.red.opacity(0.08))
    }
}

// MARK: - Downloaded Song Row

struct DownloadedSongRow: View {
    let item: DownloadedSong

    var body: some View {
        HStack(spacing: 12) {
            EnvironmentAlbumArtView(coverArtId: item.coverArtId, size: .small)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.body)
                    .lineLimit(1)

                if item.song != nil {
                    HStack(spacing: 4) {
                        Text(item.displayArtist)
                        Text("-")
                        Text(item.displayAlbum)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else {
                    Text("Cached audio file")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)

                    Text(item.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Downloaded Song Context Menu

struct DownloadedSongContextMenu: View {
    @Environment(AppState.self) private var appState
    let item: DownloadedSong
    let onRemove: () async -> Void

    var body: some View {
        if let song = item.song {
            Button {
                Task {
                    await appState.playbackManager.playNow(song)
                }
            } label: {
                Label("Play", systemImage: "play")
            }

            Button {
                appState.playbackManager.playNext(song)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                appState.playbackManager.addToQueue(song)
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }

            Divider()

            Button {
                appState.navigationTargetAlbumId = song.albumId
                appState.selectedSidebarItem = .albums
            } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
            .disabled(song.albumId.isEmpty)

            Button {
                appState.navigationTargetArtistId = song.artistId
                appState.selectedSidebarItem = .artists
            } label: {
                Label("Go to Artist", systemImage: "music.mic")
            }
            .disabled(song.artistId.isEmpty)

            Divider()

            Button {
                appState.getInfoContent = .song(song)
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }

            Divider()
        }

        Button {
            NSWorkspace.shared.selectFile(item.filePath.path, inFileViewerRootedAtPath: "")
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }

        Button(role: .destructive) {
            Task {
                await onRemove()
            }
        } label: {
            Label("Remove Download", systemImage: "trash")
        }
    }
}

#Preview {
    NavigationStack {
        DownloadsView()
            .environment(AppState())
    }
}
