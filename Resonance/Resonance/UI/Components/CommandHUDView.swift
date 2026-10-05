import SwiftUI

/// The global ⌘K Command HUD — a Spotlight/Raycast-style panel over any surface.
/// One search field drives two panes (verbs, then the project picker). The verb
/// list is `CurationVerbRegistry.allVerbs()` ranked by `CommandHUDModel`; the
/// subject is the now-playing song.
///
/// Presentation is root's job: root opens this with ⌘K by flipping
/// `AppState.isCommandHUDVisible` and overlays it (with a dimming scrim) in
/// ContentView. This view assumes it is on screen and dismisses itself by
/// setting that flag false.
struct CommandHUDView: View {
    @Environment(AppState.self) private var appState

    @State private var model = CommandHUDModel()
    @FocusState private var searchFocused: Bool

    private static let panelWidth: CGFloat = 560
    private static let listMaxHeight: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            contextLine
            Divider()
            resultList
        }
        .frame(width: Self.panelWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 30, x: 0, y: 16)
        .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.escape) { handleEscape(); return .handled }
        .onAppear { searchFocused = true }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: model.mode == .projectPicker ? "tray.full" : "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField(searchPrompt, text: Binding(
                get: { model.query },
                set: { model.setQuery($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 17))
            .focused($searchFocused)
            .onSubmit { performSelectedRow() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var searchPrompt: String {
        model.mode == .projectPicker ? "Add to project…" : "Command…"
    }

    // MARK: - Context line

    private var contextLine: some View {
        HStack(spacing: 6) {
            if let song = appState.nowPlaying {
                Text(song.title)
                    .foregroundStyle(.secondary)
                Text("—")
                    .foregroundStyle(.tertiary)
                Text(song.artist)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Nothing playing")
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Result list

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    switch model.mode {
                    case .verbs:
                        verbRows
                    case .projectPicker:
                        projectRows
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: Self.listMaxHeight)
            .onChange(of: model.selectionIndex) { _, index in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var verbRows: some View {
        let context = makeContext()
        let verbs = model.visibleVerbs
        if verbs.isEmpty {
            emptyRow("No matching commands")
        } else {
            ForEach(Array(verbs.enumerated()), id: \.element.id) { index, verb in
                HUDRow(
                    systemImage: verb.systemImage,
                    title: verb.title,
                    keyHint: verb.keyHint,
                    isSelected: index == model.selectionIndex,
                    isPrimary: verb.isPrimary,
                    isDestructive: verb.isDestructive,
                    isEnabled: isVerbEnabled(verb, context: context)
                )
                .id(index)
                .onTapGesture {
                    guard isVerbEnabled(verb, context: context) else { return }
                    activateRow(index)
                }
            }
        }
    }

    @ViewBuilder
    private var projectRows: some View {
        let projects = model.visibleProjects
        ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
            HUDRow(
                systemImage: "tray.full",
                title: project.name,
                keyHint: nil,
                isSelected: index == model.selectionIndex,
                isPrimary: false,
                isDestructive: false,
                isEnabled: true
            )
            .id(index)
            .onTapGesture { activateRow(index) }
        }
        // Trailing "New Project from Song" row.
        HUDRow(
            systemImage: "plus.circle",
            title: "New Project from Song",
            keyHint: nil,
            isSelected: model.isNewProjectRowSelected,
            isPrimary: true,
            isDestructive: false,
            isEnabled: true
        )
        .id(projects.count)
        .onTapGesture { activateRow(projects.count) }
    }

    private func emptyRow(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    /// Click a row: move the selection there, then activate it (same path as
    /// Return). Keeps mouse and keyboard driving one code path.
    private func activateRow(_ index: Int) {
        model.moveSelection(by: index - model.selectionIndex)
        performSelectedRow()
    }

    private func performSelectedRow() {
        switch model.mode {
        case .verbs:
            guard let verb = model.selectedVerb else { return }
            guard isVerbEnabled(verb, context: makeContext()) else { return }
            if verb.id == "project" {
                enterProjectPicker()
            } else {
                perform(verb)
            }
        case .projectPicker:
            performProjectRow()
        }
    }

    private func isVerbEnabled(_ verb: CurationVerb, context: CurationVerbContext) -> Bool {
        guard verb.isAvailable(context) else { return false }
        // Project opens a database-backed picker, so it also requires an
        // active server (unlike its shared registry availability predicate).
        return verb.id != "project" || appState.activeServerId != nil
    }

    private func enterProjectPicker() {
        guard let serverId = appState.activeServerId else {
            appState.showFeedback(
                message: "Connect to a server to manage projects",
                style: .warning,
                systemImage: "tray.full"
            )
            return
        }

        do {
            let projects = try appState.databaseManager.loadProjects(serverId: serverId)
            model.enterProjectPicker(projects: projects)
            searchFocused = true
        } catch {
            appState.showFeedback(
                message: "Couldn't load projects",
                detail: error.localizedDescription,
                style: .error,
                systemImage: "tray.full"
            )
        }
    }

    private func perform(_ verb: CurationVerb) {
        let context = makeContext()
        guard verb.isAvailable(context) else { return }
        // Close first: sheet-opening verbs (add-to-playlist, get-info, delete…)
        // set AppState flags in their performs, and closing before performing
        // keeps the HUD overlay from fighting the sheet that appears.
        close()
        Task {
            let outcome = await verb.perform(context)
            guard !outcome.isStale else { return }
            if let message = outcome.message {
                appState.showFeedback(
                    message: message,
                    detail: outcome.detail,
                    style: outcome.style.appFeedbackStyle,
                    systemImage: verb.systemImage
                )
            } else if Self.expectsFeedback(for: verb.id) {
                appState.showFeedback(
                    message: "Couldn't complete \(verb.title.lowercased())",
                    detail: outcome.detail ?? "Please try again.",
                    style: .error,
                    systemImage: "exclamationmark.triangle"
                )
            }
            if verb.id != "favorite" || outcome.localChangeApplied {
                NotificationCenter.default.post(name: .resonanceCurationDidChange, object: nil)
            }
        }
    }

    private static func expectsFeedback(for verbID: String) -> Bool {
        // These verbs intentionally return no toast because they open another
        // app flow. A nil result from a write verb means the action failed.
        !["add-to-playlist", "more-like-this", "get-info", "delete"].contains(verbID)
    }

    private func performProjectRow() {
        guard let serverId = appState.activeServerId else {
            appState.showFeedback(
                message: "Connect to a server to manage projects",
                style: .warning,
                systemImage: "tray.full"
            )
            return
        }
        guard let song = appState.nowPlaying else {
            appState.showFeedback(
                message: "No song is available to add",
                style: .warning,
                systemImage: "tray.full"
            )
            return
        }
        let database = appState.databaseManager
        let systemImage = CurationVerbRegistry.verb(id: "project")?.systemImage ?? "tray.full"

        if let project = model.selectedProject {
            close()
            do {
                try CurationVerbRegistry.addSongToProject(song, project: project, serverId: serverId, database: database)
                appState.showFeedback(message: "Added to \(project.name)", style: .success, systemImage: systemImage)
                NotificationCenter.default.post(name: .resonanceCurationDidChange, object: nil)
            } catch {
                appState.showFeedback(
                    message: "Couldn't add to \(project.name)",
                    detail: error.localizedDescription,
                    style: .error,
                    systemImage: "exclamationmark.triangle"
                )
            }
        } else {
            // New Project from Song row.
            close()
            do {
                let project = try CurationVerbRegistry.createListeningProject(from: song, serverId: serverId, database: database)
                appState.showFeedback(message: "Created project \(project.name)", style: .success, systemImage: systemImage)
                NotificationCenter.default.post(name: .resonanceCurationDidChange, object: nil)
            } catch {
                appState.showFeedback(
                    message: "Couldn't create project",
                    detail: error.localizedDescription,
                    style: .error,
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    private func handleEscape() {
        switch model.mode {
        case .verbs:
            close()
        case .projectPicker:
            model.exitProjectPicker()
            searchFocused = true
        }
    }

    private func close() {
        appState.isCommandHUDVisible = false
    }

    private func makeContext() -> CurationVerbContext {
        CurationVerbContext(appState: appState, song: appState.nowPlaying, album: nil)
    }
}

/// One HUD row: icon, title, optional key badge, selection highlight. Disabled
/// rows dim (verbs with no available subject); primary rows (Admit, New Project)
/// take accent; destructive rows tint the icon red.
private struct HUDRow: View {
    let systemImage: String
    let title: String
    let keyHint: String?
    let isSelected: Bool
    let isPrimary: Bool
    let isDestructive: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 14, weight: isPrimary ? .semibold : .regular))
                .foregroundStyle(isPrimary && isEnabled ? Color.accentColor : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let keyHint {
                Text(keyHint)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var iconColor: Color {
        if isDestructive { return .red }
        if isPrimary { return .accentColor }
        return .secondary
    }
}
