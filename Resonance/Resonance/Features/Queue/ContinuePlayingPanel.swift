import SwiftUI

/// Apple Music-style "Continue Playing" right sidebar panel
struct ContinuePlayingPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.emotionEngine) private var emotionEngine
    @State private var hoveredItemId: UUID?
    private let sectionPreviewLimit = 80
    private let historyPreviewLimit = 50

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()
                .padding(.horizontal)

            // Queue content
            if appState.queueManager.isEmpty {
                emptyState
            } else {
                queueList
            }
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Continue Playing")
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()

                // Clear button
                if appState.queueManager.allUpcomingCount > 0 {
                    Button("Clear") {
                        appState.queueManager.clear()
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(emotionEngine.primaryColor)
                }
            }

            // Source subtitle (e.g., "From Album Name" or "From Playlist Name")
            if let sourceName = queueSourceName {
                Text("From \(sourceName)")
                    .font(.subheadline)
                    .foregroundStyle(emotionEngine.primaryColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Queue Source

    /// Determines the source name for the queue (album or playlist name)
    private var queueSourceName: String? {
        guard let currentSong = appState.queueManager.currentItem?.song else { return nil }

        // Try to find the album name from the current song
        if !currentSong.album.isEmpty {
            return currentSong.album
        }

        return nil
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompactStatusView(
                title: "Queue Empty",
                systemImage: "music.note.list",
                message: "Add music to start playing."
            )
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Queue List

    private var queueList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Now Playing section
                if let current = appState.queueManager.currentItem {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NOW PLAYING")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)

                        ContinuePlayingRow(
                            item: current,
                            isCurrent: true,
                            isHovered: hoveredItemId == current.id,
                            onPlay: { },
                            onRemove: nil
                        )
                        .onHover { isHovered in
                            hoveredItemId = isHovered ? current.id : nil
                        }
                    }
                }

                // Up Next section (user-inserted items)
                let upNextCount = appState.queueManager.upNextItems.count
                if upNextCount > 0 {
                    let upNextItems = Array(appState.queueManager.upNextItems.prefix(sectionPreviewLimit))
                    sectionView(
                        title: "UP NEXT",
                        items: upNextItems,
                        totalCount: upNextCount
                    )
                }

                // Playing Next section (remaining base items from album/playlist)
                let remainingBaseCount = appState.queueManager.remainingBaseCount
                if remainingBaseCount > 0 {
                    let remainingBase = appState.queueManager.remainingBaseItems(limit: sectionPreviewLimit)
                    sectionView(
                        title: "PLAYING NEXT",
                        items: remainingBase,
                        totalCount: remainingBaseCount
                    )
                }

                // AutoPlay section
                let autoPlayCount = appState.queueManager.autoPlayItems.count
                if autoPlayCount > 0 {
                    let autoPlayItems = Array(appState.queueManager.autoPlayItems.prefix(sectionPreviewLimit))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("AUTOPLAY")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)

                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        ForEach(autoPlayItems) { item in
                            queueRow(item: item)
                        }

                        QueueOverflowRow(hiddenCount: autoPlayCount - autoPlayItems.count)
                    }
                }

                // History section (collapsed by default, expandable)
                let history = appState.queueManager.history
                if !history.isEmpty {
                    HistorySection(
                        history: Array(history.suffix(historyPreviewLimit)),
                        totalCount: history.count
                    )
                        .padding(.top, 16)
                }
            }
            .padding(.bottom, 80) // Space for now playing bar
        }
    }

    // MARK: - Section View

    private func sectionView(title: String, items: [QueueItem], totalCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            ForEach(items) { item in
                queueRow(item: item)
            }

            QueueOverflowRow(hiddenCount: totalCount - items.count)
        }
    }

    private func queueRow(item: QueueItem) -> some View {
        ContinuePlayingRow(
            item: item,
            isCurrent: false,
            isHovered: hoveredItemId == item.id,
            onPlay: {
                Task {
                    if let selectedItem = appState.queueManager.skipTo(id: item.id) {
                        await appState.playbackManager.play(song: selectedItem.song)
                    }
                }
            },
            onRemove: {
                appState.queueManager.remove(id: item.id)
            }
        )
        .onHover { isHovered in
            hoveredItemId = isHovered ? item.id : nil
        }
        .contextMenu {
            Button {
                Task {
                    if let selectedItem = appState.queueManager.skipTo(id: item.id) {
                        await appState.playbackManager.play(song: selectedItem.song)
                    }
                }
            } label: {
                Label("Play Now", systemImage: "play")
            }

            Divider()

            Button {
                appState.navigationTargetAlbumId = item.song.albumId
                appState.selectedSidebarItem = .albums
                appState.isQueueVisible = false
            } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
            .disabled(item.song.albumId.isEmpty)

            Button {
                appState.navigationTargetArtistId = item.song.artistId
                appState.selectedSidebarItem = .artists
                appState.isQueueVisible = false
            } label: {
                Label("Go to Artist", systemImage: "music.mic")
            }
            .disabled(item.song.artistId.isEmpty)

            Divider()

            Button(role: .destructive) {
                appState.queueManager.remove(id: item.id)
            } label: {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
        }
    }
}

private struct QueueOverflowRow: View {
    let hiddenCount: Int

    var body: some View {
        if hiddenCount > 0 {
            Text("+ \(hiddenCount) more not shown")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
    }
}

// MARK: - Continue Playing Row

struct ContinuePlayingRow: View {
    let item: QueueItem
    let isCurrent: Bool
    let isHovered: Bool
    let onPlay: () -> Void
    let onRemove: (() -> Void)?

    @Environment(\.emotionEngine) private var emotionEngine

    var body: some View {
        HStack(spacing: 12) {
            // Album art with play overlay on hover
            ZStack {
                EnvironmentAlbumArtView(coverArtId: item.song.coverArt, size: .small)
                    .frame(width: 44, height: 44)
                    .cornerRadius(6)

                // Play overlay for non-current items
                if !isCurrent && isHovered {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.black.opacity(0.5))
                        .frame(width: 44, height: 44)

                    Image(systemName: "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }

                // Now playing indicator
                if isCurrent {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(emotionEngine.primaryColor, lineWidth: 2)
                        .frame(width: 44, height: 44)
                }
            }
            .onTapGesture {
                if !isCurrent {
                    onPlay()
                }
            }

            // Song info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.song.title)
                    .font(.subheadline)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? emotionEngine.primaryColor : .primary)
                    .lineLimit(1)

                Text(item.song.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Reserve trailing space so hover state does not reflow text.
            Menu {
                Button {
                    onPlay()
                } label: {
                    Label("Play Now", systemImage: "play")
                }

                if let remove = onRemove {
                    Divider()

                    Button(role: .destructive) {
                        remove()
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .opacity(isHovered && !isCurrent ? 1 : 0)
            .allowsHitTesting(isHovered && !isCurrent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered && !isCurrent ? Color.primary.opacity(0.05) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - History Section

struct HistorySection: View {
    let history: [QueueItem]
    let totalCount: Int
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("HISTORY")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Spacer()

                    Text("\(totalCount)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(history.reversed()) { item in
                    HistoryRow(item: item)
                }
                QueueOverflowRow(hiddenCount: totalCount - history.count)
            }
        }
    }
}

struct HistoryRow: View {
    @Environment(AppState.self) private var appState
    let item: QueueItem

    var body: some View {
        HStack(spacing: 12) {
            EnvironmentAlbumArtView(coverArtId: item.song.coverArt, size: .small)
                .frame(width: 36, height: 36)
                .cornerRadius(4)
                .opacity(0.7)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.song.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(item.song.artist)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                Task {
                    if let restoredItem = appState.queueManager.restoreHistoryItem(id: item.id) {
                        await appState.playbackManager.play(song: restoredItem.song)
                    }
                }
            } label: {
                Label("Play", systemImage: "play")
            }

            Button {
                appState.playbackManager.playNext(item.song)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                appState.playbackManager.addToQueue(item.song)
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
        }
    }
}

#Preview {
    ContinuePlayingPanel()
        .environment(AppState())
        .frame(width: 320, height: 600)
}
