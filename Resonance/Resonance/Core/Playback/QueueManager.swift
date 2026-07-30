import Foundation

@MainActor
@Observable
final class QueueManager {
    private struct QueueStateSnapshot {
        let baseItems: [QueueItem]
        let upNextItems: [QueueItem]
        let autoPlayItems: [QueueItem]
        let history: [QueueItem]
        let currentItem: QueueItem?
        let basePosition: Int
        let isShuffleEnabled: Bool
        let originalBaseOrder: [QueueItem]
    }

    // MARK: - Sectioned Storage

    /// Original album/playlist tracks
    private(set) var baseItems: [QueueItem] = []

    /// User-inserted "Play Next" / "Add to Queue" items (consumed FIFO when played)
    private(set) var upNextItems: [QueueItem] = []

    /// Similar songs fetched when queue exhausts (autoplay)
    private(set) var autoPlayItems: [QueueItem] = []

    /// Previously played items
    private(set) var history: [QueueItem] = []

    /// The currently playing item (not in any section array)
    private(set) var currentItem: QueueItem?

    /// Position within baseItems (index of the last base item played, or the current one if current is from base)
    private(set) var basePosition: Int = -1

    private(set) var isShuffleEnabled: Bool = false

    /// Set to true when playNext() adds to an empty queue - PlaybackManager should start playback
    var needsPlaybackStart: Bool = false

    /// Original base order before shuffle was applied (for restoring)
    private var originalBaseOrder: [QueueItem] = []

    /// Queue state for a history item at the moment it was current.
    private var historySnapshots: [UUID: QueueStateSnapshot] = [:]

    // MARK: - Computed Properties

    var isEmpty: Bool {
        currentItem == nil && baseItems.isEmpty && upNextItems.isEmpty && autoPlayItems.isEmpty
    }

    /// Whether there's a next item available (for UI state like canGoNext)
    var hasNext: Bool {
        !upNextItems.isEmpty
            || basePosition + 1 < baseItems.count
            || !autoPlayItems.isEmpty
    }

    /// Total count of all items including current (for backward compat)
    var count: Int {
        (currentItem != nil ? 1 : 0)
            + upNextItems.count
            + max(0, baseItems.count - basePosition - 1)
            + autoPlayItems.count
    }

    /// Remaining base items after current position (the "Playing Next" section in UI)
    var remainingBaseItems: [QueueItem] {
        remainingBaseItems(limit: remainingBaseCount)
    }

    /// Everything upcoming in playback order: upNext first, then remaining base, then autoplay
    var allUpcoming: [QueueItem] {
        upNextItems + remainingBaseItems + autoPlayItems
    }

    var remainingBaseCount: Int {
        max(0, baseItems.count - basePosition - 1)
    }

    var allUpcomingCount: Int {
        upNextItems.count + remainingBaseCount + autoPlayItems.count
    }

    func remainingBaseItems(limit: Int) -> [QueueItem] {
        guard limit > 0, basePosition + 1 < baseItems.count else { return [] }
        let start = basePosition + 1
        let end = min(baseItems.count, start + min(limit, baseItems.count - start))
        return Array(baseItems[start..<end])
    }

    func upcomingItems(limit: Int) -> [QueueItem] {
        guard limit > 0 else { return [] }

        var remainingLimit = limit
        var items: [QueueItem] = []
        items.reserveCapacity(min(limit, allUpcomingCount))

        if !upNextItems.isEmpty {
            let prefix = upNextItems.prefix(remainingLimit)
            items.append(contentsOf: prefix)
            remainingLimit -= prefix.count
        }

        if remainingLimit > 0 {
            let base = remainingBaseItems(limit: remainingLimit)
            items.append(contentsOf: base)
            remainingLimit -= base.count
        }

        if remainingLimit > 0 {
            items.append(contentsOf: autoPlayItems.prefix(remainingLimit))
        }

        return items
    }

    // MARK: - Playback

    func play(_ songs: [Song], startingAt index: Int = 0) {
        guard !songs.isEmpty else { return }
        baseItems = songs.map { QueueItem(song: $0) }
        basePosition = min(index, baseItems.count - 1)
        currentItem = baseItems[basePosition]
        upNextItems = []
        autoPlayItems = []
        history = []
        isShuffleEnabled = false
        originalBaseOrder = []
        historySnapshots = [:]
        needsPlaybackStart = false
    }

    func playNext(_ song: Song) {
        let item = QueueItem(song: song)
        if currentItem == nil {
            currentItem = item
            needsPlaybackStart = true
        } else {
            upNextItems.insert(item, at: 0)
        }
    }

    func addToQueue(_ song: Song) {
        upNextItems.append(QueueItem(song: song))
    }

    func addToQueue(_ songs: [Song]) {
        upNextItems.append(contentsOf: songs.map { QueueItem(song: $0) })
    }

    // MARK: - Navigation

    /// Advance to the next item. Returns the new current item, or nil if queue is exhausted.
    /// Repeat-all wrapping is handled here when `repeatAll` is true.
    func next(repeatAll: Bool = false) -> QueueItem? {
        appendCurrentToHistory()

        // 1. Check upNext (consumed FIFO)
        if !upNextItems.isEmpty {
            currentItem = upNextItems.removeFirst()
            return currentItem
        }

        // 2. Advance in base items
        if basePosition + 1 < baseItems.count {
            basePosition += 1
            currentItem = baseItems[basePosition]
            return currentItem
        }

        // 3. Check autoplay items
        if !autoPlayItems.isEmpty {
            currentItem = autoPlayItems.removeFirst()
            return currentItem
        }

        // 4. Repeat-all: wrap to first base item
        if repeatAll && !baseItems.isEmpty {
            basePosition = 0
            currentItem = baseItems[0]
            history = []
            historySnapshots = [:]
            return currentItem
        }

        // Queue exhausted
        currentItem = nil
        return nil
    }

    func previous() -> QueueItem? {
        guard let lastPlayed = history.last else { return nil }
        return restoreHistoryItem(id: lastPlayed.id)
    }

    /// Skip to a specific item by ID. Searches all sections.
    func skipTo(id: UUID) -> QueueItem? {
        if currentItem?.id == id {
            return currentItem
        }

        // Check upNext
        if let idx = upNextItems.firstIndex(where: { $0.id == id }) {
            prepareSkippedUpNextHistory(targetIndex: idx)
            currentItem = upNextItems[idx]
            upNextItems.removeSubrange(0...idx)
            return currentItem
        }

        // Check base items (only after current position)
        if let idx = baseItems.firstIndex(where: { $0.id == id }), idx > basePosition {
            prepareSkippedBaseHistory(targetIndex: idx)
            basePosition = idx
            currentItem = baseItems[idx]
            return currentItem
        }

        // Check autoPlay
        if let idx = autoPlayItems.firstIndex(where: { $0.id == id }) {
            prepareSkippedAutoPlayHistory(targetIndex: idx)
            currentItem = autoPlayItems[idx]
            autoPlayItems.removeSubrange(0...idx)
            return currentItem
        }

        return nil
    }

    /// Restore queue state to when a history item was current.
    func restoreHistoryItem(id: UUID) -> QueueItem? {
        if currentItem?.id == id {
            return currentItem
        }

        guard history.contains(where: { $0.id == id }) else { return nil }

        if let snapshot = historySnapshots[id] {
            restore(snapshot)
            pruneHistorySnapshots()
            return currentItem
        }

        return restoreHistoryFallback(id: id)
    }

    // MARK: - Queue Management

    /// Remove an item by ID from any section
    func remove(id: UUID) {
        // Don't remove current item
        guard currentItem?.id != id else { return }

        if let idx = upNextItems.firstIndex(where: { $0.id == id }) {
            upNextItems.remove(at: idx)
        } else if let idx = baseItems.firstIndex(where: { $0.id == id }), idx > basePosition {
            baseItems.remove(at: idx)
            originalBaseOrder.removeAll { $0.id == id }
        } else if let idx = autoPlayItems.firstIndex(where: { $0.id == id }) {
            autoPlayItems.remove(at: idx)
        }
    }

    /// Remove an item at index within upNextItems
    func removeFromUpNext(at index: Int) {
        guard upNextItems.indices.contains(index) else { return }
        upNextItems.remove(at: index)
    }

    /// Remove items at offsets within upNextItems
    func removeFromUpNext(atOffsets offsets: IndexSet) {
        upNextItems.remove(atOffsets: offsets)
    }

    /// Move items within upNextItems (for drag & drop reordering)
    func moveUpNext(from source: IndexSet, to destination: Int) {
        upNextItems.move(fromOffsets: source, toOffset: destination)
    }

    /// Clear all upcoming items, keeping only the current song playing
    func clear() {
        upNextItems = []
        autoPlayItems = []
        // Trim base items to only include up to current position
        if basePosition >= 0 && basePosition < baseItems.count {
            baseItems = Array(baseItems.prefix(basePosition + 1))
        } else {
            baseItems = []
        }
        if isShuffleEnabled {
            originalBaseOrder = baseItems
        }
    }

    func clearHistory() {
        history = []
        historySnapshots = [:]
    }

    /// Update starred status for a song across all sections
    func updateSongStarred(id: String, starred: Date?) {
        updateSongInPlace(songId: id) { song in
            song.starred = starred
        }
    }

    /// Set autoplay items (called by PlaybackManager after fetching similar songs)
    func setAutoPlayItems(_ songs: [Song]) {
        // Filter out songs already in queue or history
        let existingIds = allSongIds
        let filtered = songs.filter { !existingIds.contains($0.id) }
        autoPlayItems = filtered.map { QueueItem(song: $0) }
    }

    // MARK: - Shuffle

    func toggleShuffle() {
        if isShuffleEnabled {
            restoreOriginalBasePlaybackOrder()
            isShuffleEnabled = false
            originalBaseOrder = []
        } else {
            // Save original order before shuffling
            originalBaseOrder = baseItems
            shuffleRemainingBase()
            isShuffleEnabled = true
        }
    }

    /// Shuffle only the remaining base items (after current position)
    private func shuffleRemainingBase() {
        guard basePosition + 1 < baseItems.count else { return }

        let remaining = Array(baseItems[(basePosition + 1)...])
        let shuffled = smartShuffle(remaining)
        baseItems = Array(baseItems.prefix(basePosition + 1)) + shuffled
    }

    private func smartShuffle(_ items: [QueueItem]) -> [QueueItem] {
        guard items.count > 2 else { return items.shuffled() }

        var result: [QueueItem] = []
        var remaining = items.shuffled()
        var lastArtist: String? = nil
        let maxAttempts = items.count * 3
        var attempts = 0

        while !remaining.isEmpty && attempts < maxAttempts {
            if let index = remaining.firstIndex(where: { $0.song.artist != lastArtist }) {
                let song = remaining.remove(at: index)
                result.append(song)
                lastArtist = song.song.artist
            } else {
                result.append(remaining.removeFirst())
                lastArtist = result.last?.song.artist
            }
            attempts += 1
        }

        result.append(contentsOf: remaining)
        return result
    }

    // MARK: - Private Helpers

    /// All song IDs currently in the queue (for dedup)
    private var allSongIds: Set<String> {
        var ids = Set<String>()
        if let c = currentItem { ids.insert(c.song.id) }
        for item in baseItems { ids.insert(item.song.id) }
        for item in upNextItems { ids.insert(item.song.id) }
        for item in autoPlayItems { ids.insert(item.song.id) }
        for item in history { ids.insert(item.song.id) }
        return ids
    }

    /// Update a song's properties in-place across all sections
    private func updateSongInPlace(songId: String, update: (inout Song) -> Void) {
        // Current item
        if let current = currentItem, current.song.id == songId {
            var song = current.song
            update(&song)
            currentItem = QueueItem(id: current.id, song: song, playedAt: current.playedAt)
        }

        // Base items
        for i in baseItems.indices where baseItems[i].song.id == songId {
            var song = baseItems[i].song
            update(&song)
            baseItems[i] = QueueItem(id: baseItems[i].id, song: song, playedAt: baseItems[i].playedAt)
        }

        // Original base order for shuffle restoration
        for i in originalBaseOrder.indices where originalBaseOrder[i].song.id == songId {
            var song = originalBaseOrder[i].song
            update(&song)
            originalBaseOrder[i] = QueueItem(id: originalBaseOrder[i].id, song: song, playedAt: originalBaseOrder[i].playedAt)
        }

        // Up next items
        for i in upNextItems.indices where upNextItems[i].song.id == songId {
            var song = upNextItems[i].song
            update(&song)
            upNextItems[i] = QueueItem(id: upNextItems[i].id, song: song, playedAt: upNextItems[i].playedAt)
        }

        // Autoplay items
        for i in autoPlayItems.indices where autoPlayItems[i].song.id == songId {
            var song = autoPlayItems[i].song
            update(&song)
            autoPlayItems[i] = QueueItem(id: autoPlayItems[i].id, song: song, playedAt: autoPlayItems[i].playedAt)
        }
    }

    private func appendCurrentToHistory() {
        guard let current = currentItem else { return }
        historySnapshots[current.id] = snapshot()
        history.append(playedHistoryItem(from: current))
    }

    private func prepareSkippedUpNextHistory(targetIndex: Int) {
        appendCurrentToHistory()

        guard targetIndex > 0 else { return }

        var simulatedHistory = history
        let originalUpNext = upNextItems
        for idx in 0..<targetIndex {
            let skippedItem = originalUpNext[idx]
            historySnapshots[skippedItem.id] = QueueStateSnapshot(
                baseItems: baseItems,
                upNextItems: Array(originalUpNext[(idx + 1)...]),
                autoPlayItems: autoPlayItems,
                history: simulatedHistory,
                currentItem: skippedItem,
                basePosition: basePosition,
                isShuffleEnabled: isShuffleEnabled,
                originalBaseOrder: originalBaseOrder
            )
            simulatedHistory.append(playedHistoryItem(from: skippedItem))
        }

        history = simulatedHistory
    }

    private func prepareSkippedBaseHistory(targetIndex: Int) {
        appendCurrentToHistory()

        guard targetIndex > basePosition + 1 else { return }

        var simulatedHistory = history
        for idx in (basePosition + 1)..<targetIndex {
            let skippedItem = baseItems[idx]
            historySnapshots[skippedItem.id] = QueueStateSnapshot(
                baseItems: baseItems,
                upNextItems: upNextItems,
                autoPlayItems: autoPlayItems,
                history: simulatedHistory,
                currentItem: skippedItem,
                basePosition: idx,
                isShuffleEnabled: isShuffleEnabled,
                originalBaseOrder: originalBaseOrder
            )
            simulatedHistory.append(playedHistoryItem(from: skippedItem))
        }

        history = simulatedHistory
    }

    private func prepareSkippedAutoPlayHistory(targetIndex: Int) {
        appendCurrentToHistory()

        guard targetIndex > 0 else { return }

        var simulatedHistory = history
        let originalAutoPlay = autoPlayItems
        for idx in 0..<targetIndex {
            let skippedItem = originalAutoPlay[idx]
            historySnapshots[skippedItem.id] = QueueStateSnapshot(
                baseItems: baseItems,
                upNextItems: upNextItems,
                autoPlayItems: Array(originalAutoPlay[(idx + 1)...]),
                history: simulatedHistory,
                currentItem: skippedItem,
                basePosition: basePosition,
                isShuffleEnabled: isShuffleEnabled,
                originalBaseOrder: originalBaseOrder
            )
            simulatedHistory.append(playedHistoryItem(from: skippedItem))
        }

        history = simulatedHistory
    }

    private func restoreOriginalBasePlaybackOrder() {
        guard !originalBaseOrder.isEmpty else { return }

        let originalBaseIds = Set(originalBaseOrder.map(\.id))
        let currentBaseById = Dictionary(uniqueKeysWithValues: baseItems.map { ($0.id, $0) })
        let originalBaseById = Dictionary(uniqueKeysWithValues: originalBaseOrder.map { ($0.id, $0) })

        var playedBaseIds: [UUID] = []
        for item in history where originalBaseIds.contains(item.id) {
            if !playedBaseIds.contains(item.id) {
                playedBaseIds.append(item.id)
            }
        }

        if let current = currentItem, originalBaseIds.contains(current.id), !playedBaseIds.contains(current.id) {
            playedBaseIds.append(current.id)
        }

        let playedBaseSet = Set(playedBaseIds)
        let unplayedOriginalIds = originalBaseOrder.map(\.id).filter { !playedBaseSet.contains($0) }
        let rebuiltIds = playedBaseIds + unplayedOriginalIds

        baseItems = rebuiltIds.compactMap { id in
            currentBaseById[id] ?? originalBaseById[id]
        }

        if let current = currentItem, let restoredIndex = baseItems.firstIndex(where: { $0.id == current.id }) {
            basePosition = restoredIndex
        } else {
            basePosition = max(-1, playedBaseIds.count - 1)
        }
    }

    private func playedHistoryItem(from item: QueueItem) -> QueueItem {
        var historyItem = item
        historyItem.playedAt = Date()
        return historyItem
    }

    private func snapshot() -> QueueStateSnapshot {
        QueueStateSnapshot(
            baseItems: baseItems,
            upNextItems: upNextItems,
            autoPlayItems: autoPlayItems,
            history: history,
            currentItem: currentItem,
            basePosition: basePosition,
            isShuffleEnabled: isShuffleEnabled,
            originalBaseOrder: originalBaseOrder
        )
    }

    private func restore(_ snapshot: QueueStateSnapshot) {
        baseItems = snapshot.baseItems
        upNextItems = snapshot.upNextItems
        autoPlayItems = snapshot.autoPlayItems
        history = snapshot.history
        currentItem = snapshot.currentItem
        basePosition = snapshot.basePosition
        isShuffleEnabled = snapshot.isShuffleEnabled
        originalBaseOrder = snapshot.originalBaseOrder
    }

    private func restoreHistoryFallback(id: UUID) -> QueueItem? {
        guard let historyIndex = history.firstIndex(where: { $0.id == id }) else { return nil }

        let selectedItem = history[historyIndex]
        let earlierHistory = Array(history[..<historyIndex])
        var futureItems = Array(history[(historyIndex + 1)...])
        if let current = currentItem {
            futureItems.append(current)
        }
        futureItems.append(contentsOf: allUpcoming)

        currentItem = selectedItem
        history = earlierHistory
        upNextItems = futureItems
        autoPlayItems = []

        if let selectedBaseIndex = baseItems.firstIndex(where: { $0.id == id }) {
            baseItems = Array(baseItems.prefix(selectedBaseIndex + 1))
            basePosition = selectedBaseIndex
        } else if basePosition >= 0 && basePosition < baseItems.count {
            baseItems = Array(baseItems.prefix(basePosition + 1))
        }

        pruneHistorySnapshots()
        return currentItem
    }

    private func pruneHistorySnapshots() {
        let validIds = Set(history.map(\.id))
        historySnapshots = historySnapshots.filter { validIds.contains($0.key) }
    }
}
