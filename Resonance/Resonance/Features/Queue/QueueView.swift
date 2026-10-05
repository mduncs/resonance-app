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
    @State private var isConfirmingClear = false
    @State private var dropTargetID: UUID?
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
                            .contextMenu {
                                QuickCaptureMenu(song: current.song)
                                Button("Get Info") { appState.getInfoContent = .song(current.song) }
                            }
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
                                .draggable(QueueItemTransfer(id: item.id, sourceIndex: offset)) {
                                    // Drag preview
                                    QueueItemRow(item: item, isCurrent: false)
                                        .frame(width: 280)
                                        .background(.regularMaterial)
                                        .cornerRadius(8)
                                }
                                .dropDestination(for: QueueItemTransfer.self) { items, _ in
                                    guard items.count == 1, let transfer = items.first else { return false }
                                    return appState.queueManager.moveUpNextItem(id: transfer.id, onto: item.id)
                                } isTargeted: { targeted in
                                    if targeted {
                                        dropTargetID = item.id
                                    } else if dropTargetID == item.id {
                                        dropTargetID = nil
                                    }
                                }
                                .overlay {
                                    if dropTargetID == item.id {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(Color.accentColor, lineWidth: 1)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .accessibilityAction(named: "Move Up") {
                                    moveManualItem(item.id, delta: -1)
                                }
                                .accessibilityAction(named: "Move Down") {
                                    moveManualItem(item.id, delta: 1)
                                }
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
                        // Key by position: repeat plays can append duplicate
                        // QueueItem ids to history.
                        ForEach(Array(displayedHistory.reversed().enumerated()), id: \.offset) { _, item in
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
                        isConfirmingClear = true
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
                guard !selectedItemIds.isEmpty else { return .ignored }
                deleteSelectedItems()
                return .handled
            }
            .onKeyPress(keys: [KeyEquivalent("\u{7F}")]) { _ in
                // Backspace key (same as delete on Mac keyboards without dedicated delete)
                guard !selectedItemIds.isEmpty else { return .ignored }
                deleteSelectedItems()
                return .handled
            }
            .onKeyPress(.escape) {
                dismiss()
                return .handled
            }
            .onKeyPress(.return) {
                // Enter: play first selected item
                guard !selectedItemIds.isEmpty else { return .ignored }
                playFirstSelectedItem()
                return .handled
            }
        }
        .frame(minWidth: 350, minHeight: 400)
        // Same consequence and recovery boundary as ContinuePlayingPanel.
        .confirmationDialog(
            "Clear all upcoming songs?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                appState.queueManager.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(appState.queueManager.allUpcomingCount) upcoming songs will be removed. The current song keeps playing.")
        }
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

        Divider()

        Button {
            appState.navigationTargetArtistId = nil
            appState.navigationTargetSongId = nil
            appState.navigationTargetAlbumId = item.song.albumId
            appState.selectedSidebarItem = .albums
            dismiss()
        } label: {
            Label("Go to Album", systemImage: "square.stack")
        }
        .disabled(item.song.albumId.isEmpty)

        Button {
            appState.navigationTargetAlbumId = nil
            appState.navigationTargetSongId = nil
            appState.navigationTargetArtistId = item.song.artistId
            appState.selectedSidebarItem = .artists
            dismiss()
        } label: {
            Label("Go to Artist", systemImage: "music.mic")
        }
        .disabled(item.song.artistId.isEmpty)

        Divider()

        QuickCaptureMenu(song: item.song)

        Button("Get Info") { appState.getInfoContent = .song(item.song) }

        if let index = appState.queueManager.upNextItems.firstIndex(where: { $0.id == item.id }) {
            Divider()
            Button("Move Up") { moveManualItem(item.id, delta: -1) }
                .disabled(index == 0)
            Button("Move Down") { moveManualItem(item.id, delta: 1) }
                .disabled(index + 1 == appState.queueManager.upNextItems.count)
        }

        Divider()

        Button(role: .destructive) {
            appState.queueManager.remove(id: item.id)
        } label: {
            Label("Remove from Queue", systemImage: "minus.circle")
        }
    }

    private func moveManualItem(_ id: UUID, delta: Int) {
        let items = appState.queueManager.upNextItems
        guard let index = items.firstIndex(where: { $0.id == id }),
              items.indices.contains(index + delta) else { return }
        appState.queueManager.moveUpNextItem(id: id, onto: items[index + delta].id)
    }

    /// Delete selected items from the queue
    private func deleteSelectedItems() {
        guard !selectedItemIds.isEmpty else { return }
        for id in selectedItemIds {
            appState.queueManager.remove(id: id)
        }
        selectedItemIds.removeAll()
    }

    /// Play the first selected item
    private func playFirstSelectedItem() {
        guard let selectedId = appState.queueManager.allUpcoming
            .first(where: { selectedItemIds.contains($0.id) })?.id else { return }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.song.title), \(item.song.artist), \(item.song.formattedDuration)\(isCurrent ? ", now playing" : "")")
    }
}

#Preview {
    QueueView()
        .environment(AppState())
}
