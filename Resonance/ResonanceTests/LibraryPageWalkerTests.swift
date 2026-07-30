import XCTest
@testable import Resonance

/// Regression cover for the pagination termination rule.
///
/// The bug these exist to prevent: the walk used to stop as soon as a page
/// contributed no unseen ids, which silently truncated a 28,992-album library
/// to 618 albums *while reporting success*. The distinction between "the server
/// has no more rows" and "the server re-sent rows I already have" is the whole
/// point of this type.
final class LibraryPageWalkerTests: XCTestCase {

    private func walker(pageSize: Int = 500) -> LibraryPageWalker {
        LibraryPageWalker(pageSize: pageSize, label: "test")
    }

    // MARK: - The clean end

    func testShortPageCompletesTheWalk() {
        var w = walker()
        XCTAssertEqual(
            w.step(batchCount: 120, newItemCount: 120, offset: 0, totalSoFar: 120),
            .stop(.complete)
        )
    }

    func testEmptyPageCompletesTheWalk() {
        var w = walker()
        XCTAssertEqual(
            w.step(batchCount: 0, newItemCount: 0, offset: 5_000, totalSoFar: 5_000),
            .stop(.complete)
        )
    }

    func testShortPageCompletesEvenWhenItAddedNothingNew() {
        // A short page is authoritative regardless of duplicate content.
        var w = walker()
        XCTAssertEqual(
            w.step(batchCount: 3, newItemCount: 0, offset: 1_000, totalSoFar: 900),
            .stop(.complete)
        )
    }

    // MARK: - The regression

    func testFullPageOfDuplicatesDoesNotEndTheWalk() {
        // THE bug. A full page contributing zero new ids must keep walking.
        var w = walker()
        XCTAssertEqual(
            w.step(batchCount: 500, newItemCount: 0, offset: 500, totalSoFar: 618),
            .advance,
            "a full page of duplicates must not be mistaken for the end of the library"
        )
    }

    func testWalkSurvivesDuplicatePagesAndKeepsGoing() {
        // Four duplicate pages is under the tolerance; the walk must continue
        // and then happily accept new rows afterwards.
        var w = walker()
        for i in 0..<(LibraryPageWalker.maxConsecutiveNoProgressPages - 1) {
            XCTAssertEqual(
                w.step(batchCount: 500, newItemCount: 0, offset: 500 * i, totalSoFar: 618),
                .advance
            )
        }
        XCTAssertEqual(
            w.step(batchCount: 500, newItemCount: 500, offset: 2_500, totalSoFar: 1_118),
            .advance
        )
    }

    func testProgressResetsTheDuplicateCounter() {
        // Interleaved duplicate/progress pages must never accumulate toward the
        // bail-out, or a large library with unstable ordering would still truncate.
        var w = walker()
        for i in 0..<50 {
            XCTAssertEqual(
                w.step(batchCount: 500, newItemCount: 0, offset: i * 1_000, totalSoFar: 1_000),
                .advance
            )
            XCTAssertEqual(
                w.step(batchCount: 500, newItemCount: 1, offset: i * 1_000 + 500, totalSoFar: 1_001),
                .advance
            )
        }
    }

    // MARK: - Bounded bail-out, reported honestly

    func testRelentlessDuplicatesEventuallyStopButReportTruncation() {
        var w = walker()
        var last: LibraryPageWalker.Step = .advance
        for i in 0..<LibraryPageWalker.maxConsecutiveNoProgressPages {
            last = w.step(batchCount: 500, newItemCount: 0, offset: i * 500, totalSoFar: 618)
        }

        guard case .stop(let outcome) = last else {
            return XCTFail("expected the walk to stop after relentless duplicate pages")
        }
        XCTAssertFalse(outcome.isComplete, "a bail-out must never be reported as a complete walk")
        XCTAssertNotNil(outcome.truncationReason)
    }

    func testPageCeilingReportsTruncationNotCompletion() {
        var w = walker()
        var last: LibraryPageWalker.Step = .advance
        // Alternate so the duplicate counter never trips; only the ceiling can fire.
        for i in 0..<LibraryPageWalker.maxPages {
            last = w.step(batchCount: 500, newItemCount: 500, offset: i * 500, totalSoFar: (i + 1) * 500)
            if case .stop = last { break }
        }

        guard case .stop(let outcome) = last else {
            return XCTFail("expected the page ceiling to stop the walk")
        }
        XCTAssertFalse(outcome.isComplete)
        XCTAssertEqual(outcome.truncationReason?.contains("ceiling"), true)
    }

    // MARK: - Outcome semantics

    func testWalkOutcomeCompletenessAccessors() {
        XCTAssertTrue(LibraryWalkOutcome.complete.isComplete)
        XCTAssertNil(LibraryWalkOutcome.complete.truncationReason)

        let truncated = LibraryWalkOutcome.truncated(reason: "gave up")
        XCTAssertFalse(truncated.isComplete)
        XCTAssertEqual(truncated.truncationReason, "gave up")
    }
}
