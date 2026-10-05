import Foundation

/// Selection state for a list whose display order is meaningful.  Keeping the
/// anchor separate from the selected set makes reversed Shift ranges behave
/// like Finder lists and avoids deriving order in each row body.
struct OrderedItemSelection<ID: Hashable> {
    private(set) var selectedIDs: Set<ID> = []
    private(set) var anchorID: ID?
    private(set) var focusedID: ID?

    var isEmpty: Bool { selectedIDs.isEmpty }

    /// Keyboard focus is not another selection gesture. A mouse click may
    /// focus a control before its action runs; toggling here would undo Cmd-click.
    mutating func focus(_ id: ID, in orderedIDs: [ID]) {
        guard orderedIDs.contains(id) else { return }
        focusedID = id
    }

    mutating func click(_ id: ID, in orderedIDs: [ID], extending: Bool = false, toggling: Bool = false) {
        guard orderedIDs.contains(id) else { return }
        if extending {
            let range = idsInRange(from: anchorID ?? focusedID ?? id, to: id, in: orderedIDs)
            if toggling { selectedIDs.formUnion(range) } else { selectedIDs = Set(range) }
            if anchorID == nil { anchorID = id }
        } else if toggling {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
            // A Command-click is still an explicit selection gesture: Finder's
            // next Shift-click ranges from that occurrence, even when it was
            // just toggled off.
            anchorID = id
        } else {
            selectedIDs = [id]
            anchorID = id
        }
        focusedID = id
    }

    mutating func moveFocus(by offset: Int, in orderedIDs: [ID], extending: Bool = false) -> ID? {
        guard !orderedIDs.isEmpty else { return nil }
        let currentIndex = focusedID.flatMap { orderedIDs.firstIndex(of: $0) }
            ?? orderedIDs.firstIndex(where: { selectedIDs.contains($0) })
            ?? (offset < 0 ? orderedIDs.count : -1)
        let nextIndex = min(max(0, currentIndex + offset), orderedIDs.count - 1)
        let id = orderedIDs[nextIndex]
        click(id, in: orderedIDs, extending: extending)
        return id
    }

    /// Reconcile a native list's visible selection without replaying N clicks.
    mutating func acceptNativeSelection(_ ids: Set<ID>, in orderedIDs: [ID], loadedIDs: Set<ID>, additive: Bool) {
        let priorVisible = selectedIDs.intersection(loadedIDs)
        selectedIDs = additive ? selectedIDs.subtracting(loadedIDs).union(ids) : ids
        let added = ids.subtracting(priorVisible)
        if added.count == 1, let id = added.first {
            focusedID = id
            anchorID = id
        } else if focusedID == nil || !ids.contains(focusedID!) {
            focusedID = orderedIDs.first(where: ids.contains)
            anchorID = focusedID
        }
    }

    mutating func selectAll(in orderedIDs: [ID]) {
        selectedIDs = Set(orderedIDs)
        if anchorID == nil { anchorID = orderedIDs.first }
        focusedID = orderedIDs.last ?? focusedID
    }

    mutating func prune(to orderedIDs: [ID]) {
        let valid = Set(orderedIDs)
        selectedIDs.formIntersection(valid)
        if let anchorID, !valid.contains(anchorID) { self.anchorID = nil }
        if let focusedID, !valid.contains(focusedID) {
            self.focusedID = orderedIDs.first(where: { selectedIDs.contains($0) })
        }
    }

    func idsInDisplayOrder(_ orderedIDs: [ID]) -> [ID] {
        orderedIDs.filter { selectedIDs.contains($0) }
    }

    private func idsInRange(from start: ID, to end: ID, in orderedIDs: [ID]) -> ArraySlice<ID> {
        guard let startIndex = orderedIDs.firstIndex(of: start),
              let endIndex = orderedIDs.firstIndex(of: end) else { return [end] }
        return orderedIDs[min(startIndex, endIndex)...max(startIndex, endIndex)]
    }
}
