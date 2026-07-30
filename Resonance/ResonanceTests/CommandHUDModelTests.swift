import Foundation
import XCTest
@testable import Resonance

/// Covers the ⌘K Command HUD model: pure ranking/filtering, selection movement,
/// mode transitions, and query-reset behavior. All of it is exercised without a
/// database or network — the ranking works on `RankableVerb` metadata and the
/// model's stateful behavior rides on the real `CurationVerbRegistry.allVerbs()`
/// (which needs no services to construct) plus plain `Project` fixtures.
@MainActor
final class CommandHUDModelTests: XCTestCase {

    // MARK: - Ranking (pure)

    func testEmptyQueryReturnsDeckFirstNonDestructiveInOrder() {
        let ranked = CommandHUDModel.rankedVerbs(sampleVerbs, query: "")
        // Registry order preserved; destructive verbs (reject) dropped.
        XCTAssertEqual(ranked.map(\.id), ["capture", "mark", "project", "admit", "later"])
    }

    func testPrefixMatchesRankAheadOfSubstringMatches() {
        let verbs = [
            CommandHUDModel.RankableVerb(id: "apple", title: "Apple", isDestructive: false),
            CommandHUDModel.RankableVerb(id: "grape", title: "Grape", isDestructive: false),
            CommandHUDModel.RankableVerb(id: "apricot", title: "Apricot", isDestructive: false),
        ]
        let ranked = CommandHUDModel.rankedVerbs(verbs, query: "ap")
        // Prefix matches (Apple, Apricot) in input order, then the interior match (Grape).
        XCTAssertEqual(ranked.map(\.id), ["apple", "apricot", "grape"])
    }

    func testWithinSameRankDeckOrderWins() {
        let verbs = [
            CommandHUDModel.RankableVerb(id: "deck", title: "Mark", isDestructive: false),
            CommandHUDModel.RankableVerb(id: "tail", title: "Marker", isDestructive: false),
        ]
        // Both are prefix matches; input (deck-first) order breaks the tie.
        let ranked = CommandHUDModel.rankedVerbs(verbs, query: "mar")
        XCTAssertEqual(ranked.map(\.id), ["deck", "tail"])
    }

    func testDestructiveHiddenOnEmptyQueryButPresentWhenMatched() {
        let empty = CommandHUDModel.rankedVerbs(sampleVerbs, query: "")
        XCTAssertFalse(empty.contains { $0.id == "reject" }, "destructive verbs must not browse")

        let matched = CommandHUDModel.rankedVerbs(sampleVerbs, query: "rej")
        XCTAssertEqual(matched.map(\.id), ["reject"], "destructive verb appears once its query matches")
    }

    func testRankingIsCaseInsensitive() {
        let ranked = CommandHUDModel.rankedVerbs(sampleVerbs, query: "CAPT")
        XCTAssertEqual(ranked.map(\.id), ["capture"])
    }

    func testFilteredProjectsMatchesNameSubstringCaseInsensitively() {
        let projects = [
            makeProject(name: "Late Night"),
            makeProject(name: "Morning Ambient"),
            makeProject(name: "night drive"),
        ]
        let filtered = CommandHUDModel.filteredProjects(projects, query: "NIGHT")
        XCTAssertEqual(filtered.map(\.name), ["Late Night", "night drive"])

        XCTAssertEqual(CommandHUDModel.filteredProjects(projects, query: "").count, 3)
    }

    // MARK: - Model: default state & verb rows against the real registry

    func testDefaultsToVerbModeFirstRowCapture() {
        let model = CommandHUDModel()
        XCTAssertEqual(model.mode, .verbs)
        XCTAssertEqual(model.selectionIndex, 0)
        XCTAssertEqual(model.selectedVerb?.id, "capture", "⌘K, Enter must capture")
        // Empty-query browse list leads with the deck and excludes destructive verbs.
        XCTAssertEqual(Array(model.visibleVerbs.prefix(4)).map(\.id), ["capture", "mark", "project", "admit"])
        XCTAssertFalse(model.visibleVerbs.contains { $0.id == "reject" || $0.id == "delete" })
    }

    // MARK: - Selection movement / clamping

    func testSelectionClampsAtBothEnds() {
        let model = CommandHUDModel()
        let last = model.rowCount - 1
        XCTAssertGreaterThan(last, 0)

        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectionIndex, 0, "cannot move above the first row")

        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectionIndex, 1)

        model.moveSelection(by: 10_000)
        XCTAssertEqual(model.selectionIndex, last, "cannot move past the last row")
    }

    // MARK: - Query reset

    func testSettingQueryResetsSelectionToFirstRow() {
        let model = CommandHUDModel()
        model.moveSelection(by: 3)
        XCTAssertEqual(model.selectionIndex, 3)

        model.setQuery("mark")
        XCTAssertEqual(model.selectionIndex, 0)
        XCTAssertEqual(model.selectedVerb?.id, "mark")
    }

    // MARK: - Mode transitions

    func testEnterProjectPickerAddsTrailingNewRowAndClearsQuery() {
        let model = CommandHUDModel()
        model.setQuery("mark")
        model.moveSelection(by: 0)

        let projects = [makeProject(name: "Alpha"), makeProject(name: "Beta")]
        model.enterProjectPicker(projects: projects)

        XCTAssertEqual(model.mode, .projectPicker)
        XCTAssertEqual(model.query, "", "entering the picker clears the verb query")
        XCTAssertEqual(model.selectionIndex, 0)
        XCTAssertEqual(model.rowCount, 3, "two projects plus the New Project row")

        XCTAssertEqual(model.selectedProject?.name, "Alpha")
        XCTAssertFalse(model.isNewProjectRowSelected)

        // The trailing row is the New Project row, not an existing project.
        model.moveSelection(by: 2)
        XCTAssertTrue(model.isNewProjectRowSelected)
        XCTAssertNil(model.selectedProject)
    }

    func testProjectPickerFiltersByQuery() {
        let model = CommandHUDModel()
        model.enterProjectPicker(projects: [
            makeProject(name: "Late Night"),
            makeProject(name: "Morning"),
        ])
        model.setQuery("night")

        XCTAssertEqual(model.visibleProjects.map(\.name), ["Late Night"])
        // One filtered project + the ever-present New Project row.
        XCTAssertEqual(model.rowCount, 2)
    }

    func testExitProjectPickerReturnsToVerbsWithClearedQuery() {
        let model = CommandHUDModel()
        model.enterProjectPicker(projects: [makeProject(name: "Alpha")])
        model.setQuery("alp")

        model.exitProjectPicker()

        XCTAssertEqual(model.mode, .verbs)
        XCTAssertEqual(model.query, "", "backing out clears the previous query")
        XCTAssertEqual(model.selectionIndex, 0)
        XCTAssertEqual(model.selectedVerb?.id, "capture")
    }

    // MARK: - Fixtures

    /// A compact deck-first verb set (with one destructive verb) for pure-ranking
    /// tests. Order mirrors the registry contract: deck verbs before the tail.
    private let sampleVerbs: [CommandHUDModel.RankableVerb] = [
        .init(id: "capture", title: "Capture", isDestructive: false),
        .init(id: "mark", title: "Mark", isDestructive: false),
        .init(id: "project", title: "Project", isDestructive: false),
        .init(id: "admit", title: "Admit", isDestructive: false),
        .init(id: "later", title: "Later", isDestructive: false),
        .init(id: "reject", title: "Reject", isDestructive: true),
    ]

    private func makeProject(name: String) -> Project {
        Project(serverId: "server-hud", name: name, kind: "listening")
    }
}
