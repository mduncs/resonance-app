import SwiftUI

/// Posted after any ⌘K HUD verb or project write lands, so surfaces that show
/// curation state (the plane's tiles, the Waiting Room) can refresh. Named to
/// match `.resonanceProjectItemsDidChange` in ProjectsView.swift; root wires
/// PlaneView to observe it.
extension Notification.Name {
    static let resonanceCurationDidChange = Notification.Name("ResonanceCurationDidChange")
}

/// State + pure ranking for the global ⌘K Command HUD. The view (`CommandHUDView`)
/// owns presentation and side effects (performing verbs, toasts, closing); this
/// model owns only what can be tested without a database or network:
/// query/selection/mode, the ranked verb list, and the filtered project list.
///
/// The ranking/filtering is exposed as static functions over lightweight
/// metadata (`RankableVerb`, plain `Project`) so tests never need `AppState`.
@MainActor
@Observable
final class CommandHUDModel {

    /// Two panes behind one search field: the verb list, and the project picker
    /// the "project" verb switches into.
    enum Mode: Equatable {
        case verbs
        case projectPicker
    }

    /// The only verb metadata ranking depends on — kept free of the closures and
    /// `@MainActor` context of `CurationVerb` so the rank function is pure and
    /// trivially testable. Input order encodes registry order (deck verbs first).
    struct RankableVerb: Equatable {
        let id: String
        let title: String
        let isDestructive: Bool
    }

    private let allVerbs: [CurationVerb]

    private(set) var mode: Mode = .verbs
    var query: String = ""
    private(set) var selectionIndex: Int = 0
    /// Projects loaded when the picker opens; filtered by `query` for display.
    private(set) var projects: [Project] = []

    init(verbs: [CurationVerb] = CurationVerbRegistry.allVerbs()) {
        self.allVerbs = verbs
    }

    // MARK: - Ranked / filtered rows

    /// The verbs to show for the current query, ranked. Empty query → deck-first
    /// registry order with destructive verbs hidden; non-empty → substring
    /// matches with prefix matches first, deck before tail within a tier.
    var visibleVerbs: [CurationVerb] {
        let rankable = allVerbs.map {
            RankableVerb(id: $0.id, title: $0.title, isDestructive: $0.isDestructive)
        }
        let ranked = Self.rankedVerbs(rankable, query: query)
        let byId = Dictionary(allVerbs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.compactMap { byId[$0.id] }
    }

    /// The projects to show in the picker, filtered by name (query-insensitive
    /// when empty). The final "New Project from Song" row is not part of this
    /// list — it always trails it (see `rowCount` / `isNewProjectRowSelected`).
    var visibleProjects: [Project] {
        Self.filteredProjects(projects, query: query)
    }

    /// Total selectable rows in the current mode. The picker always has one extra
    /// row (New Project from Song) after the filtered projects.
    var rowCount: Int {
        switch mode {
        case .verbs: return visibleVerbs.count
        case .projectPicker: return visibleProjects.count + 1
        }
    }

    /// True when the selection is on the trailing New Project row of the picker.
    var isNewProjectRowSelected: Bool {
        mode == .projectPicker && selectionIndex == visibleProjects.count
    }

    /// The selected verb in verb mode (nil out of range or in picker mode).
    var selectedVerb: CurationVerb? {
        guard mode == .verbs else { return nil }
        let verbs = visibleVerbs
        guard verbs.indices.contains(selectionIndex) else { return nil }
        return verbs[selectionIndex]
    }

    /// The selected existing project in picker mode (nil on the New Project row
    /// or in verb mode).
    var selectedProject: Project? {
        guard mode == .projectPicker else { return nil }
        let projects = visibleProjects
        guard projects.indices.contains(selectionIndex) else { return nil }
        return projects[selectionIndex]
    }

    // MARK: - Mutations

    /// Edit the query and snap the selection back to the first row.
    func setQuery(_ newValue: String) {
        query = newValue
        selectionIndex = 0
    }

    /// Move the selection, clamped to the current rows. A negative delta moves up.
    func moveSelection(by delta: Int) {
        let count = rowCount
        guard count > 0 else {
            selectionIndex = 0
            return
        }
        selectionIndex = min(max(0, selectionIndex + delta), count - 1)
    }

    /// Enter the project picker with a freshly loaded project list; clears the
    /// query and resets the selection to the first row.
    func enterProjectPicker(projects: [Project]) {
        mode = .projectPicker
        self.projects = projects
        query = ""
        selectionIndex = 0
    }

    /// Back out of the picker to the verb list; clears the (project) query so the
    /// verb list opens fresh, per the spec.
    func exitProjectPicker() {
        mode = .verbs
        projects = []
        query = ""
        selectionIndex = 0
    }

    // MARK: - Pure ranking / filtering

    /// Rank verbs for a query. Empty query returns the non-destructive verbs in
    /// input (registry / deck-first) order. Non-empty returns case-insensitive
    /// substring matches — including destructive ones when they match — with
    /// prefix matches ahead of interior matches, ties broken by input order so
    /// deck verbs precede tail verbs within a tier.
    static func rankedVerbs(_ verbs: [RankableVerb], query: String) -> [RankableVerb] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return verbs.filter { !$0.isDestructive }
        }
        return verbs.enumerated()
            .filter { $0.element.title.lowercased().contains(needle) }
            .sorted { lhs, rhs in
                let lPrefix = lhs.element.title.lowercased().hasPrefix(needle)
                let rPrefix = rhs.element.title.lowercased().hasPrefix(needle)
                if lPrefix != rPrefix { return lPrefix }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Filter projects by name substring (case-insensitive); empty query keeps
    /// the input order and set.
    static func filteredProjects(_ projects: [Project], query: String) -> [Project] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return projects }
        return projects.filter { $0.name.lowercased().contains(needle) }
    }
}
