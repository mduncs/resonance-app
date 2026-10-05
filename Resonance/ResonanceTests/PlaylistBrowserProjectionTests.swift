import XCTest
@testable import Resonance

final class PlaylistBrowserProjectionTests: XCTestCase {
    func testNameSearchIsNotTruncatedByDisplayWindow() {
        let source = (0..<250).map { make("p\($0)", name: $0 == 249 ? "Needle" : "Playlist \($0)", count: $0, changed: Double($0)) }
        let matches = PlaylistBrowserProjection.matching(source, query: "needle", sort: .name)
        XCTAssertEqual(matches.map(\.id), ["p249"])
    }

    func testSortsUseNameTieBreakThenStableID() {
        let source = [make("b", name: "Same", count: 4, changed: 1), make("a", name: "Same", count: 4, changed: 1), make("c", name: "Other", count: 9, changed: 3)]
        XCTAssertEqual(PlaylistBrowserProjection.matching(source, query: "", sort: .songCount).map(\.id), ["c", "a", "b"])
        XCTAssertEqual(PlaylistBrowserProjection.matching(source, query: "", sort: .changed).map(\.id), ["c", "a", "b"])
    }

    private func make(_ id: String, name: String, count: Int, changed: TimeInterval) -> Playlist {
        Playlist(id: id, name: name, comment: nil, owner: "owner", songCount: count, duration: 0,
                 created: .distantPast, changed: Date(timeIntervalSinceReferenceDate: changed), coverArt: nil, isPublic: false)
    }
}
