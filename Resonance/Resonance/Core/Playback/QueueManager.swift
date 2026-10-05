import Foundation

/// A queue section with an inexpensive advancing cursor.  Its collection
/// indices deliberately remain zero based, so existing queue consumers retain
/// normal `Array`-style indexing without forcing a new array after each play.
struct QueueSection: RandomAccessCollection, MutableCollection {
    typealias Index = Int
    typealias Element = QueueItem

    private var storage: [QueueItem]
    private var start: Int
    private(set) var materializationCount = 0

    init(_ items: [QueueItem] = []) {
        storage = items
        start = 0
    }

    var startIndex: Int { 0 }
    var endIndex: Int { storage.count - start }

    subscript(position: Int) -> QueueItem {
        get {
            precondition(indices.contains(position), "QueueSection index out of bounds")
            return storage[start + position]
        }
        set {
            precondition(indices.contains(position), "QueueSection index out of bounds")
            storage[start + position] = newValue
        }
    }

    var isEmpty: Bool { start == storage.count }

    mutating func advance() -> QueueItem? {
        guard !isEmpty else { return nil }
        defer { start += 1 }
        return storage[start]
    }

    mutating func append(_ item: QueueItem) {
        compactIfNeeded()
        storage.append(item)
    }

    mutating func append(contentsOf items: [QueueItem]) {
        compactIfNeeded()
        storage.append(contentsOf: items)
    }

    mutating func prepend(_ item: QueueItem) {
        compactIfNeeded()
        storage.insert(item, at: start)
    }

    mutating func remove(at index: Int) {
        precondition(indices.contains(index), "QueueSection index out of bounds")
        storage.remove(at: start + index)
    }

    mutating func removeFirst(_ count: Int) {
        precondition((0...self.count).contains(count), "QueueSection removal out of bounds")
        start += count
    }

    mutating func remove(atOffsets offsets: IndexSet) {
        precondition(offsets.allSatisfy(indices.contains), "QueueSection removal out of bounds")
        for index in offsets.sorted(by: >) {
            storage.remove(at: start + index)
        }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        precondition(source.allSatisfy(indices.contains), "QueueSection move source out of bounds")
        precondition((0...count).contains(destination), "QueueSection move destination out of bounds")
        let moving = source.sorted().map { storage[start + $0] }
        remove(atOffsets: source)
        let removedBeforeDestination = source.filter { $0 < destination }.count
        storage.insert(contentsOf: moving, at: start + destination - removedBeforeDestination)
    }

    private mutating func compactIfNeeded() {
        // Retain the shared buffer while navigation is in progress.  Reclaim a
        // substantially consumed prefix only before a structural mutation.
        guard start > 0 else { return }
        storage = Array(storage[start...])
        start = 0
        materializationCount += 1
    }
}

struct QueueScalabilityProbe {
    fileprivate(set) var snapshotsCreated = 0
    /// Sum of history-prefix lengths recorded by actual snapshots.
    fileprivate(set) var historyPrefixCountTotal = 0
    /// Copies made to compact a cursor-backed section before structural edits.
    fileprivate(set) var sectionMaterializations = 0
}

@MainActor
@Observable
final class QueueManager {
    private struct QueueStateSnapshot {
        let baseItems: [QueueItem]
        let upNextItems: QueueSection
        let autoPlayItems: QueueSection
        let historyCount: Int
        let currentItem: QueueItem?
        let basePosition: Int
        let isShuffleEnabled: Bool
        let originalBaseOrder: [QueueItem]
    }

    // MARK: - Sectioned Storage

    /// Original album/playlist tracks
    private(set) var baseItems: [QueueItem] = []

    /// User-inserted "Play Next" / "Add to Queue" items (consumed FIFO when played)
    private(set) var upNextItems = QueueSection()

    /// Similar songs fetched when queue exhausts (autoplay)
    private(set) var autoPlayItems = QueueSection()

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

    private var snapshotsCreated = 0
    private var historyPrefixCountTotal = 0

    var scalabilityProbe: QueueScalabilityProbe {
        QueueScalabilityProbe(
            snapshotsCreated: snapshotsCreated,
            historyPrefixCountTotal: historyPrefixCountTotal,
            sectionMaterializations: upNextItems.materializationCount + autoPlayItems.materializationCount
        )
    }

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

    /// History takes precedence; a fresh middle-of-album start can also move
    /// backward within its base order. Match the occurrence, not the song ID.
    var hasPrevious: Bool {
        !history.isEmpty || canStepToPreviousBaseItem
    }

    private var canStepToPreviousBaseItem: Bool {
        basePosition > 0
            && baseItems.indices.contains(basePosition)
            && currentItem?.id == baseItems[basePosition].id
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
        Array(upNextItems) + remainingBaseItems + Array(autoPlayItems)
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
        basePosition = max(0, min(index, baseItems.count - 1))
        currentItem = baseItems[basePosition]
        upNextItems = QueueSection()
        autoPlayItems = QueueSection()
        history = []
        isShuffleEnabled = false
        originalBaseOrder = []
        historySnapshots = [:]
        snapshotsCreated = 0
        historyPrefixCountTotal = 0
        needsPlaybackStart = false
    }

    /// Installs a fully sectioned queue for the launch-only parity atlas.
    /// Callers provide stable item identifiers and timestamps so queue/history
    /// screenshots do not depend on UUID generation or live playback. This
    /// mutates only this in-memory manager and never invokes PlaybackManager.
    func installDeterministicFixture(
        baseItems: [QueueItem],
        currentIndex: Int,
        upNextItems: [QueueItem],
        autoPlayItems: [QueueItem],
        history: [QueueItem]
    ) {
        guard baseItems.indices.contains(currentIndex) else { return }

        self.baseItems = baseItems
        self.basePosition = currentIndex
        self.currentItem = baseItems[currentIndex]
        self.upNextItems = QueueSection(upNextItems)
        self.autoPlayItems = QueueSection(autoPlayItems)
        self.history = history
        self.isShuffleEnabled = false
        self.originalBaseOrder = []
        self.historySnapshots = [:]
        self.snapshotsCreated = 0
        self.historyPrefixCountTotal = 0
        self.needsPlaybackStart = false
    }

    /// Installs the launch-only parity queue-empty state.
    ///
    /// This is deliberately separate from `clear()`: the production clear
    /// command keeps the current song, while the atlas empty route must make
    /// `QueueView` observe no current, base, up-next, autoplay, or history
    /// items. It only changes this in-memory queue state and is never called
    /// by normal playback flows.
    func installDeterministicEmptyFixture() {
        resetForServerChange()
    }

    /// Drop every occurrence when leaving its server; unlike Clear Upcoming,
    /// no current item, base prefix, or historical occurrence survives.
    func resetForServerChange() {
        baseItems = []
        upNextItems = QueueSection()
        autoPlayItems = QueueSection()
        history = []
        currentItem = nil
        basePosition = -1
        isShuffleEnabled = false
        originalBaseOrder = []
        historySnapshots = [:]
        snapshotsCreated = 0
        historyPrefixCountTotal = 0
        needsPlaybackStart = false
    }

    func playNext(_ song: Song) {
        let item = QueueItem(song: song)
        if currentItem == nil {
            currentItem = item
            needsPlaybackStart = true
        } else {
            upNextItems.prepend(item)
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
            currentItem = upNextItems.advance()
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
            currentItem = autoPlayItems.advance()
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
        if let lastPlayed = history.last {
            return restoreHistoryItem(id: lastPlayed.id)
        }
        guard canStepToPreviousBaseItem else { return nil }
        // Starting in the middle does not make the earlier tracks played
        // history. Leave manual and autoplay sections intact while stepping back.
        basePosition -= 1
        currentItem = baseItems[basePosition]
        return currentItem
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
            upNextItems.removeFirst(idx + 1)
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
            autoPlayItems.removeFirst(idx + 1)
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

    /// Reorder manual queue occurrences by their current stable IDs, not drag-start indices.
    /// Dropping downward places the source after the target; upward places it before.
    @discardableResult
    func moveUpNextItem(id: UUID, onto targetID: UUID) -> Bool {
        guard let source = upNextItems.firstIndex(where: { $0.id == id }),
              let target = upNextItems.firstIndex(where: { $0.id == targetID }) else {
            return false
        }
        guard source != target else { return true }
        moveUpNext(
            from: IndexSet(integer: source),
            to: target > source ? target + 1 : target
        )
        return true
    }

    /// Clear all upcoming items, keeping only the current song playing
    func clear() {
        upNextItems = QueueSection()
        autoPlayItems = QueueSection()
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
        autoPlayItems = QueueSection(filtered.map { QueueItem(song: $0) })
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
        var buckets: [String: [QueueItem]] = [:]
        for item in items.shuffled() {
            buckets[item.song.artist, default: []].append(item)
        }
        var activeArtists = Array(buckets.keys).shuffled()
        var lastArtist: String?

        while !activeArtists.isEmpty {
            var index = Int.random(in: activeArtists.indices)
            if activeArtists.count > 1, activeArtists[index] == lastArtist {
                index = (index + Int.random(in: 1..<activeArtists.count)) % activeArtists.count
            }
            let artist = activeArtists[index]
            let song = buckets[artist]!.removeLast()
            result.append(song)
            lastArtist = artist
            if buckets[artist]!.isEmpty {
                activeArtists.swapAt(index, activeArtists.count - 1)
                activeArtists.removeLast()
            }
        }
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
            var remainingUpNext = originalUpNext
            remainingUpNext.removeFirst(idx + 1)
            historySnapshots[skippedItem.id] = QueueStateSnapshot(
                baseItems: baseItems,
                upNextItems: remainingUpNext,
                autoPlayItems: autoPlayItems,
                historyCount: simulatedHistory.count,
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
                historyCount: simulatedHistory.count,
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
            var remainingAutoPlay = originalAutoPlay
            remainingAutoPlay.removeFirst(idx + 1)
            historySnapshots[skippedItem.id] = QueueStateSnapshot(
                baseItems: baseItems,
                upNextItems: upNextItems,
                autoPlayItems: remainingAutoPlay,
                historyCount: simulatedHistory.count,
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
        var playedBaseSet = Set<UUID>()
        for item in history where originalBaseIds.contains(item.id) {
            if playedBaseSet.insert(item.id).inserted {
                playedBaseIds.append(item.id)
            }
        }

        if let current = currentItem,
           originalBaseIds.contains(current.id),
           playedBaseSet.insert(current.id).inserted {
            playedBaseIds.append(current.id)
        }

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
        snapshotsCreated += 1
        historyPrefixCountTotal += history.count
        return QueueStateSnapshot(
            baseItems: baseItems,
            upNextItems: upNextItems,
            autoPlayItems: autoPlayItems,
            historyCount: history.count,
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
        history = Array(history.prefix(snapshot.historyCount))
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
        upNextItems = QueueSection(futureItems)
        autoPlayItems = QueueSection()

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
