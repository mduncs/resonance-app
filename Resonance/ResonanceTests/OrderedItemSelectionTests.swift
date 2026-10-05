import XCTest
@testable import Resonance

final class OrderedItemSelectionTests: XCTestCase {
    func testFocusBeforeCommandClickDoesNotToggleSelectionTwice() {
        let ids = ["first", "second", "third"]
        var selection = OrderedItemSelection<String>()
        selection.click("first", in: ids)
        selection.focus("second", in: ids)
        XCTAssertEqual(selection.selectedIDs, ["first"])
        XCTAssertEqual(selection.anchorID, "first")
        selection.click("second", in: ids, toggling: true)
        XCTAssertEqual(selection.selectedIDs, ["first", "second"])
        selection.focus("third", in: ids)
        XCTAssertEqual(selection.focusedID, "third")
        XCTAssertEqual(selection.selectedIDs, ["first", "second"])
    }

    func testCommandToggleAndShiftReversalKeepStableAnchor() {
        var selection = OrderedItemSelection<String>()
        let ids = ["disc1-1", "disc1-2", "disc2-1", "disc2-2"]

        selection.click("disc1-2", in: ids)
        selection.click("disc2-2", in: ids, toggling: true)
        XCTAssertEqual(selection.selectedIDs, ["disc1-2", "disc2-2"])

        XCTAssertEqual(selection.anchorID, "disc2-2")
        selection.click("disc1-1", in: ids, extending: true)
        XCTAssertEqual(selection.idsInDisplayOrder(ids), ids)
        selection.click("disc2-2", in: ids, extending: true, toggling: true)
        XCTAssertEqual(selection.idsInDisplayOrder(ids), ids)
    }

    func testPruneAndKeyboardShiftExtension() {
        var selection = OrderedItemSelection<Int>()
        let ids = [1, 2, 3, 4]
        selection.click(2, in: ids)
        XCTAssertEqual(selection.moveFocus(by: 2, in: ids, extending: true), 4)
        XCTAssertEqual(selection.idsInDisplayOrder(ids), [2, 3, 4])
        selection.prune(to: [1, 3, 4])
        XCTAssertEqual(selection.idsInDisplayOrder([1, 3, 4]), [3, 4])
        XCTAssertNil(selection.anchorID)
    }

    func testKeyboardMovementChangesTheActivationTarget() {
        var selection = OrderedItemSelection<String>()
        selection.click("one", in: ["one", "two", "three"])
        XCTAssertEqual(selection.moveFocus(by: 2, in: ["one", "two", "three"]), "three")
        XCTAssertEqual(selection.focusedID, "three")
    }

    func testNativeSelectionPreservesOffPageIDsForCommandAddAndReplacesForPlainClick() {
        let allIDs = ["first", "page-old", "page-new", "last"]
        let loadedIDs: Set<String> = ["page-old", "page-new"]
        var selection = OrderedItemSelection<String>()
        selection.click("first", in: allIDs)
        selection.click("page-old", in: allIDs, toggling: true)

        // Command-clicking a row on the current page retains the off-page ID.
        selection.acceptNativeSelection(["page-new"], in: allIDs, loadedIDs: loadedIDs, additive: true)
        XCTAssertEqual(selection.idsInDisplayOrder(allIDs), ["first", "page-new"])
        XCTAssertEqual(selection.focusedID, "page-new")
        XCTAssertEqual(selection.anchorID, "page-new")

        // A normal native click replaces the entire selection and focus target.
        selection.acceptNativeSelection(["page-old"], in: allIDs, loadedIDs: loadedIDs, additive: false)
        XCTAssertEqual(selection.idsInDisplayOrder(allIDs), ["page-old"])
        XCTAssertEqual(selection.focusedID, "page-old")
        XCTAssertEqual(selection.anchorID, "page-old")
    }

    func testFiftyThousandIDsKeepDisplayOrderAndLatestCommandAnchor() {
        let ids = (0..<50_000).map { "entry-\($0)" }
        var selection = OrderedItemSelection<String>()
        selection.selectAll(in: ids)
        XCTAssertEqual(selection.idsInDisplayOrder(ids).count, 50_000)
        selection.click("entry-40000", in: ids, toggling: true)
        selection.click("entry-40002", in: ids, extending: true)
        XCTAssertEqual(selection.anchorID, "entry-40000")
        XCTAssertEqual(selection.idsInDisplayOrder(ids), ["entry-40000", "entry-40001", "entry-40002"])
    }

    func testPlaylistProjectionPreservesDuplicateOccurrencesAndCompleteSelection() {
        let duplicate = Song.placeholder
        let first = PlaylistSongEntry(id: UUID(), song: duplicate)
        let second = PlaylistSongEntry(id: UUID(), song: duplicate)
        let projection = PlaylistFindProjection.make(
            entries: [first, second], hiddenSongIDs: [], hiddenAlbumIDs: [], hiddenArtistIDs: [],
            query: "", limit: 1
        )
        XCTAssertEqual(projection.matchingEntries.map(\.id), [first.id, second.id])
        XCTAssertEqual(projection.displayedEntries.map(\.id), [first.id])
        XCTAssertEqual(projection.sourceIndexByID[first.id], 0)
        XCTAssertEqual(projection.sourceIndexByID[second.id], 1)

        var selection = OrderedItemSelection<UUID>()
        selection.selectAll(in: projection.matchingEntries.map(\.id))
        XCTAssertEqual(selection.idsInDisplayOrder(projection.matchingEntries.map(\.id)), [first.id, second.id])
    }
}
