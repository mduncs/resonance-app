import XCTest
@testable import Resonance

final class SmartPlaylistEngineTests: XCTestCase {

    func testLikedRuleCompilesToLikedItemsJoinAndPredicate() {
        let playlist = SmartPlaylist(
            name: "Liked Songs",
            serverId: "server-1",
            ruleGroup: SmartPlaylistRuleGroup(
                conjunction: .and,
                rules: [
                    SmartPlaylistRule(field: .liked, op: .isTrue, value: "")
                ]
            )
        )

        let compiled = SmartPlaylistCompiler.buildEvaluationQuery(playlist: playlist)

        XCTAssertTrue(compiled.sql.contains("SELECT item_id, liked_at FROM liked_items"))
        XCTAssertTrue(compiled.sql.contains("li.item_id IS NOT NULL"))
        XCTAssertEqual(compiled.arguments.count, 5)
    }

    func testLikedAtSortUsesLikedTimestampColumn() {
        let playlist = SmartPlaylist(
            name: "Recently Liked",
            serverId: "server-1",
            ruleGroup: SmartPlaylistRuleGroup(),
            sortBy: "likedAt",
            sortOrder: .desc
        )

        let compiled = SmartPlaylistCompiler.buildEvaluationQuery(playlist: playlist)

        XCTAssertTrue(compiled.sql.contains("ORDER BY li.liked_at DESC"))
    }

    func testLikedDateFieldExposesDateOperatorsAndLabel() {
        XCTAssertEqual(SmartPlaylistRule.RuleField.liked.displayName, "Is Liked")
        XCTAssertEqual(SmartPlaylistRule.RuleField.likedAt.displayName, "Liked Date")
        XCTAssertEqual(SmartPlaylistRule.RuleField.liked.compatibleOperators, [.isTrue, .isFalse])
        XCTAssertEqual(SmartPlaylistRule.RuleField.likedAt.compatibleOperators, [.inLast, .notInLast])
    }
}
