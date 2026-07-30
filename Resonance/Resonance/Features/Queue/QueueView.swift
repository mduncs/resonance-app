import SwiftUI
import UniformTypeIdentifiers

/// Transferable wrapper for queue item drag & drop
struct QueueItemTransfer: Codable, Transferable {
    let id: UUID
    let sourceIndex: Int  // Index within upNextItems array (0-based)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .queueItem)
    }
}

extension UTType {
    static var queueItem: UTType {
        UTType(exportedAs: "com.resonance.queue-item")
    }
}

struct QueueView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var draggingItem: UUID?
    @State private var selectedItemIds = Set<UUID>()
    @FocusState private var isListFocused: Bool
    private let sectionDisplayLimit = 500
    private let historyDisplayLimit = 200

    var body: some View {
        NavigationStack {
            List(selection: $selectedItemIds) {
                // Now Playing
                if let current = appState.queueManager.currentItem {
                    Section("Now Playing") {
                        QueueItemRow(item: current, isCurrent: true)
                    }
                }

                // Up Next (user-inserted items — drag & drop reorderable)
                let upNextCount = appState.queueManager.upNextItems.count
                if upNextCount > 0 {
                    let upNextItems = Array(appState.queueManager.upNextItems.prefix(sectionDisplayLimit))
                    Section("Up Next") {
                        ForEach(Array(upNextItems.enumerated()), id: \.element.id) { offset, item in
                            QueueItemRow(item: item, isCurrent: false, showDragHandle: true)
                                .tag(item.id)
                                .opacity(draggingItem == item.id ? 0.5 : 1.0)
                                .draggable(QueueItemTransfer(id: item.id, sourceIndex: offset)) {
                                    // Drag preview
                                    QueueItemRow(item: item, isCurrent: false)
                                        .frame(width: 280)
                                        .background(.regularMaterial)
                                        .cornerRadius(8)
                                }
                                .dropDestination(for: QueueItemTransfer.self) { items, _ in
                                    guard let transfer = items.first else { return false }
                                    // Find current source index by UUID
                                    let currentUpNext = appState.queueManager.upNextItems
                                    guard let currentSourceOffset = currentUpNext.firstIndex(where: { $0.id == transfer.id }) else {
                                        return false
                                    }
                                    let destOffset = offset

                                    if currentSourceOffset != destOffset {
                                        let adjustedDest = destOffset > currentSourceOffset ? destOffset + 1 : destOffset
                                        appState.queueManager.moveUpNext(
                                            from: IndexSet(integer: currentSourceOffset),
                                            to: adjustedDest
                                        )
                                    }
                                    return true
                                } isTargeted: { _ in }
                                .contextMenu {
                                    queueItemContextMenu(item: item)
                                }
                        }
                        .onDelete { offsets in
                            appState.queueManager.removeFromUpNext(atOffsets: offsets)
                        }

                        QueueListOverflowRow(hiddenCount: upNextCount - upNextItems.count)
                    }
                }

                // Playing Next (remaining base items from album/playlist)
                let remainingBaseCount = appState.queueManager.remainingBaseCount
                if remainingBaseCount > 0 {
                    let remainingBase = appState.queueManager.remainingBaseItems(limit: sectionDisplayLimit)
                    Section("Playing Next") {
                        ForEach(remainingBase) { item in
                            QueueItemRow(item: item, isCurrent: false)
                                .tag(item.id)
                                .contextMenu {
                                    queueItemContextMenu(item: item)
                                }
                        }

                        QueueListOverflowRow(hiddenCount: remainingBaseCount - remainingBase.count)
                    }
                }

                // AutoPlay
                let autoPlayCount = appState.queueManager.autoPlayItems.count
                if autoPlayCount > 0 {
                    let autoPlayItems = Array(appState.queueManager.autoPlayItems.prefix(sectionDisplayLimit))
                    Section {
                        ForEach(autoPlayItems) { item in
                            QueueItemRow(item: item, isCurrent: false)
                                .tag(item.id)
                                .contextMenu {
                                    queueItemContextMenu(item: item)
                                }
                        }
                        QueueListOverflowRow(hiddenCount: autoPlayCount - autoPlayItems.count)
                    } header: {
                        HStack(spacing: 4) {
                            Text("Autoplay")
                            Image(systemName: "sparkles")
                                .font(.caption2)
                        }
                    }
                }

                // History
                let history = appState.queueManager.history
                if !history.isEmpty {
                    let displayedHistory = Array(history.suffix(historyDisplayLimit))
                    Section("History") {
                        ForEach(displayedHistory.reversed()) { item in
                            QueueItemRow(item: item, isCurrent: false)
                                .opacity(0.6)
                        }
                        QueueListOverflowRow(hiddenCount: history.count - displayedHistory.count)
                    }
                }
            }
            .listStyle(.inset)
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        appState.queueManager.toggleShuffle()
                    } label: {
                        Image(systemName: "shuffle")
                            .foregroundStyle(appState.queueManager.isShuffleEnabled ? Color.accentColor : .primary)
                    }
                    .disabled(appState.queueManager.allUpcomingCount == 0)

                    Button {
                        appState.queueManager.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(appState.queueManager.allUpcomingCount == 0)
                }
            }
            .overlay {
                if appState.queueManager.isEmpty {
                    CompactStatusView(
                        title: "Queue Empty",
                        systemImage: "music.note.list",
                        message: "Add some music to get started."
                    )
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress(.delete) {
                deleteSelectedItems()
                return .handled
            }
            .onKeyPress(keys: [KeyEquivalent("\u{7F}")]) { _ in
                // Backspace key (same as delete on Mac keyboards without dedicated delete)
                deleteSelectedItems()
                return .handled
            }
            .onKeyPress(.escape) {
                dismiss()
                return .handled
            }
            .onKeyPress(.return) {
                // Enter: play first selected item
                playFirstSelectedItem()
                return .handled
            }
        }
        .frame(minWidth: 350, minHeight: 400)
        .onAppear {
            isListFocused = true
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func queueItemContextMenu(item: QueueItem) -> some View {
        Button {
            Task {
                if let selectedItem = appState.queueManager.skipTo(id: item.id) {
                    await appState.playbackManager.play(song: selectedItem.song)
                }
            }
        } label: {
            Label("Play Now", systemImage: "play")
        }

        Button(role: .destructive) {
            appState.queueManager.remove(id: item.id)
        } label: {
            Label("Remove", systemImage: "minus.circle")
        }

        Divider()

        Button {
            appState.navigationTargetAlbumId = item.song.albumId
            appState.selectedSidebarItem = .albums
            dismiss()
        } label: {
            Label("Go to Album", systemImage: "square.stack")
        }
        .disabled(item.song.albumId.isEmpty)

        Button {
            appState.navigationTargetArtistId = item.song.artistId
            appState.selectedSidebarItem = .artists
            dismiss()
        } label: {
            Label("Go to Artist", systemImage: "music.mic")
        }
        .disabled(item.song.artistId.isEmpty)
    }

    /// Delete selected items from the queue
    private func deleteSelectedItems() {
        for id in selectedItemIds {
            appState.queueManager.remove(id: id)
        }
        selectedItemIds.removeAll()
    }

    /// Play the first selected item
    private func playFirstSelectedItem() {
        guard let selectedId = selectedItemIds.first else { return }
        Task {
            if let item = appState.queueManager.skipTo(id: selectedId) {
                await appState.playbackManager.play(song: item.song)
            }
        }
    }
}

private struct QueueListOverflowRow: View {
    let hiddenCount: Int

    var body: some View {
        if hiddenCount > 0 {
            Text("+ \(hiddenCount) more not shown")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

struct QueueItemRow: View {
    let item: QueueItem
    let isCurrent: Bool
    var showDragHandle: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // Drag handle for reorderable items
            if showDragHandle {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }

            // Album art
            EnvironmentAlbumArtView(coverArtId: item.song.coverArt, size: .small)
                .frame(width: 40, height: 40)
                .cornerRadius(4)

            // Song info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.song.title)
                    .font(.body)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)

                Text(item.song.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Duration
            Text(item.song.formattedDuration)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // Playing indicator
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    QueueView()
        .environment(AppState())
}
