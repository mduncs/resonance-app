import SwiftUI

struct FetcherSourcesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @AppStorage(FetcherContractSettings.fixtureDirectoryKey) private var fixtureDirectory = ""

    @State private var snapshot: FetcherContractSnapshot?
    @State private var loadedFixtureDirectory: URL?
    @State private var selectedCollectionKey: String?
    @State private var selectedItem: FetcherSourceItem?
    @State private var mode: FetcherSourceItemMode = .current
    @State private var stagedCandidateKeys = Set<String>()
    @State private var projects: [Project] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionMessage: String?

    private var collections: [FetcherSourceCollection] {
        (snapshot?.sourceCollections ?? [])
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var selectedCollection: FetcherSourceCollection? {
        guard let selectedCollectionKey else { return nil }
        return snapshot?.sourceCollectionsByKey[selectedCollectionKey]
    }

    var body: some View {
        HSplitView {
            sourceListPane
                .frame(minWidth: 280, idealWidth: 340)

            detailPane
                .frame(minWidth: 520)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .task {
            await loadSnapshot()
        }
        .task(id: appState.activeServerId) {
            loadProjects()
        }
        .onChange(of: fixtureDirectory) { _, _ in
            Task { await loadSnapshot() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resonanceProjectItemsDidChange)) { notification in
            guard notification.userInfo?["serverId"] as? String == appState.activeServerId else { return }
            loadProjects()
        }
        .onChange(of: selectedCollectionKey) { _, _ in
            selectedItem = nil
            actionMessage = nil
        }
    }

    private var sourceListPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isLoading {
                FetcherSourcesStatusView(
                    title: "Loading Fetcher Sources...",
                    systemImage: "arrow.triangle.2.circlepath",
                    message: "Reading the local contract fixture directory."
                )
                .padding(.horizontal, 24)
                .padding(.top, 4)
            } else if let errorMessage {
                FetcherSourcesStatusView(
                    title: "Unable to Load Sources",
                    systemImage: "exclamationmark.triangle",
                    message: errorMessage
                )
                .padding(.horizontal, 24)
                .padding(.top, 4)
            } else if snapshot == nil {
                missingConfigurationState
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
            } else if collections.isEmpty {
                FetcherSourcesStatusView(
                    title: "No Sources",
                    systemImage: "tray.and.arrow.down",
                    message: "The selected Fetcher contract fixture has no source collections."
                )
                .padding(.horizontal, 24)
                .padding(.top, 4)
            } else {
                List(selection: $selectedCollectionKey) {
                    ForEach(collections) { collection in
                        FetcherSourceCollectionRow(collection: collection)
                            .tag(collection.sourceCollectionKey)
                    }
                }
                .listStyle(.sidebar)
                .frame(minHeight: 260, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text(summaryText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var summaryText: String {
        guard let snapshot else { return "Local Fetcher contract fixture" }
        let warningCount = snapshot.warningHealthRows.count
        let warningText = warningCount == 0 ? "healthy" : "\(warningCount) warnings"
        return "\(snapshot.sourceCollections.count) collections - \(warningText)"
    }

    private var missingConfigurationState: some View {
        VStack(alignment: .leading, spacing: 12) {
            FetcherSourcesStatusView(
                title: "No Fixture Directory",
                systemImage: "folder.badge.questionmark",
                message: "Choose a Fetcher contract export in Settings > Advanced, or set RESONANCE_FETCHER_CONTRACT_FIXTURE_DIR for development."
            )

            Button("Open Advanced Settings") {
                UserDefaults.standard.set(SettingsTab.advanced.rawValue, forKey: SettingsTab.storageKey)
                openSettings()
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let snapshot, let selectedCollection {
            FetcherSourceDetailPane(
                snapshot: snapshot,
                collection: selectedCollection,
                fixtureDirectory: loadedFixtureDirectory,
                mode: $mode,
                selectedItem: $selectedItem,
                stagedCandidateKeys: stagedCandidateKeys,
                activeServerId: appState.activeServerId,
                actionMessage: actionMessage,
                projects: projects,
                onStageCandidate: stageCandidate,
                onAddToProject: addToProject,
                onCreateProject: createProject
            )
        } else {
            FetcherSourcesStatusView(
                title: "Select a Source",
                systemImage: "tray.and.arrow.down",
                message: "Choose a Fetcher source collection to inspect current, all-seen, and removed source evidence."
            )
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// A live export is ~110MB of JSON across eight files, so the decode itself
    /// must never touch the main actor. Everything that mutates view state stays
    /// on the main actor; only the URL crosses into the detached decode.
    @MainActor
    private func loadSnapshot() async {
        isLoading = true
        actionMessage = nil
        stagedCandidateKeys.removeAll()

        guard let directory = FetcherContractLoader().configuredDirectory() else {
            snapshot = nil
            loadedFixtureDirectory = nil
            selectedCollectionKey = nil
            selectedItem = nil
            errorMessage = nil
            isLoading = false
            return
        }

        let exportStamp = FetcherSnapshotCache.stamp(for: directory)
        if let cachedSnapshot = FetcherSnapshotCache.snapshot(for: directory, stamp: exportStamp) {
            apply(cachedSnapshot, directory: directory)
            isLoading = false
            return
        }

        do {
            let loadedSnapshot = try await Task.detached(priority: .userInitiated) {
                try FetcherContractLoader().loadSnapshot(from: directory)
            }.value
            FetcherSnapshotCache.store(loadedSnapshot, directory: directory, stamp: exportStamp)
            apply(loadedSnapshot, directory: directory)
        } catch {
            snapshot = nil
            loadedFixtureDirectory = nil
            selectedCollectionKey = nil
            selectedItem = nil
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func apply(_ loadedSnapshot: FetcherContractSnapshot, directory: URL) {
        snapshot = loadedSnapshot
        loadedFixtureDirectory = directory
        importSourceAttribution(from: loadedSnapshot)
        if selectedCollectionKey == nil || loadedSnapshot.sourceCollectionsByKey[selectedCollectionKey ?? ""] == nil {
            selectedCollectionKey = loadedSnapshot.sourceCollections.first?.sourceCollectionKey
        }
        selectedItem = nil
        errorMessage = nil
    }

    /// Fire-and-forget, idempotent import of Fetcher provenance rows into GRDB,
    /// followed by project automake (which joins through those rows, so it must
    /// run strictly after the upsert). Gated by the same fixture-directory config
    /// as the rest of the contract; a snapshot without the optional attribution
    /// file is a no-op for both steps.
    ///
    /// Both steps are also gated on the export's identity: a live export upserts
    /// 21k rows and then scans them for automake, which is pure contention with
    /// the page's own reads if it reruns on every visit. One run per export
    /// generation per server is enough.
    private func importSourceAttribution(from snapshot: FetcherContractSnapshot) {
        let rows = snapshot.sourceAttribution
        guard !rows.isEmpty else { return }
        let database = appState.databaseManager
        let serverId = appState.activeServerId
        let markerKey = Self.attributionImportMarkerKey(serverId: serverId)
        let marker = snapshot.metadata.exportIdentityMarker
        guard UserDefaults.standard.string(forKey: markerKey) != marker else { return }

        Task.detached {
            do {
                try database.upsertSourceAttributions(rows)
            } catch {
                // Leave the marker unset so the next visit retries the import.
                return
            }

            var automakeSummary: FetcherProjectAutomake.Summary?
            if let serverId {
                automakeSummary = try? FetcherProjectAutomake.run(
                    snapshot: snapshot,
                    serverId: serverId,
                    database: database
                )
            }

            UserDefaults.standard.set(marker, forKey: markerKey)

            guard let serverId, automakeSummary?.didChangeAnything == true else { return }

            await MainActor.run {
                NotificationCenter.default.post(
                    name: .resonanceProjectItemsDidChange,
                    object: nil,
                    userInfo: ["serverId": serverId]
                )
            }
        }
    }

    private static func attributionImportMarkerKey(serverId: String?) -> String {
        "fetcherAttributionImportedMarker.\(serverId ?? "no-server")"
    }

    private func loadProjects() {
        guard let serverId = appState.activeServerId else {
            projects = []
            return
        }

        projects = (try? appState.databaseManager.loadProjects(serverId: serverId)) ?? []
    }

    private func stageCandidate(_ candidate: FetcherCandidateImport) {
        guard let serverId = appState.activeServerId else {
            actionMessage = "Choose an active server before staging Fetcher candidates."
            return
        }

        guard let songId = candidate.navidromeSongId, !songId.isEmpty else {
            actionMessage = "This Fetcher candidate is not mapped to a Navidrome song yet."
            return
        }

        guard FetcherCandidateRoute(rawContractValue: candidate.recommendedResonanceRoute) == .waitingRoom else {
            actionMessage = "Only Waiting Room Fetcher candidates can be staged."
            return
        }

        do {
            guard let song = try appState.databaseManager.loadCachedSong(id: songId, serverId: serverId) else {
                actionMessage = "No cached Navidrome song was found for this Fetcher candidate."
                return
            }

            try appState.databaseManager.upsertWaitingRoomItem(
                song: song,
                serverId: serverId,
                state: .unheard,
                source: "fetcher_contract",
                notes: candidate.waitingRoomNotes
            )
            stagedCandidateKeys.insert(candidate.candidateKey)
            actionMessage = "Staged \"\(candidate.title)\" in Waiting Room."
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    private func addToProject(
        project: Project,
        collection: FetcherSourceCollection,
        mode: FetcherSourceItemMode,
        items: [FetcherSourceItem]
    ) {
        guard let serverId = appState.activeServerId else {
            actionMessage = "Choose an active server before adding source rows to a project."
            return
        }

        guard let snapshot else {
            actionMessage = "Load a Fetcher contract fixture before adding source rows to a project."
            return
        }

        let songIds = snapshot.mappedNavidromeSongIds(for: items)
        guard !songIds.isEmpty else {
            actionMessage = "No Navidrome-mapped songs were available for this source view."
            return
        }

        do {
            let insertResult = try appState.databaseManager.addProjectSongReferences(
                projectId: project.id,
                songIds: songIds,
                serverId: serverId,
                addedBy: "fetcher_source",
                note: "Fetcher source: \(collection.sourceCollectionKey); view: \(mode.rawValue)"
            )

            NotificationCenter.default.post(
                name: .resonanceProjectItemsDidChange,
                object: nil,
                userInfo: [
                    "serverId": serverId,
                    "projectId": project.id
                ]
            )

            if insertResult.addedCount == 0 {
                actionMessage = "\"\(project.name)\" already contains all mapped songs from this source view."
            } else {
                actionMessage = "Added \(insertResult.addedCount) song references to \"\(project.name)\"."
            }
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    private func createProject(
        collection: FetcherSourceCollection,
        mode: FetcherSourceItemMode,
        items: [FetcherSourceItem]
    ) {
        guard let serverId = appState.activeServerId else {
            actionMessage = "Choose an active server before creating a source project."
            return
        }

        guard let snapshot else {
            actionMessage = "Load a Fetcher contract fixture before creating a source project."
            return
        }

        let songIds = snapshot.mappedNavidromeSongIds(for: items)

        guard !songIds.isEmpty else {
            actionMessage = "No Navidrome-mapped songs were available for this source view."
            return
        }

        do {
            let project = Project(
                serverId: serverId,
                name: "\(collection.displayName) - \(mode.rawValue)",
                kind: "collection",
                notes: [
                    "Fetcher source: \(collection.sourceCollectionKey)",
                    "Source view: \(mode.rawValue)",
                    "Source rows: \(items.count)"
                ].joined(separator: "\n")
            )

            let insertResult = try appState.databaseManager.saveProjectWithSongReferences(
                project,
                songIds: songIds,
                addedBy: "fetcher_source",
                note: "Fetcher source: \(collection.sourceCollectionKey)"
            )

            NotificationCenter.default.post(
                name: .resonanceProjectItemsDidChange,
                object: nil,
                userInfo: [
                    "serverId": serverId,
                    "projectId": project.id
                ]
            )
            actionMessage = "Created project \"\(project.name)\" with \(insertResult.addedCount) song references."
        } catch {
            actionMessage = error.localizedDescription
        }
    }
}

/// Keeps the most recently decoded export around so reopening the page doesn't
/// pay the multi-second decode again. Invalidated when the fixture directory
/// changes or `contract-version.json` is rewritten (every re-export rewrites it).
@MainActor
private enum FetcherSnapshotCache {
    private static var cached: (path: String, stamp: Date, snapshot: FetcherContractSnapshot)?

    static func stamp(for directory: URL) -> Date? {
        let versionFile = directory.appendingPathComponent("contract-version.json")
        return (try? versionFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func snapshot(for directory: URL, stamp: Date?) -> FetcherContractSnapshot? {
        guard let stamp,
              let cached,
              cached.path == directory.path,
              cached.stamp == stamp else { return nil }
        return cached.snapshot
    }

    static func store(_ snapshot: FetcherContractSnapshot, directory: URL, stamp: Date?) {
        guard let stamp else {
            cached = nil
            return
        }
        cached = (directory.path, stamp, snapshot)
    }
}

private struct FetcherSourceDetailPane: View {
    let snapshot: FetcherContractSnapshot
    let collection: FetcherSourceCollection
    let fixtureDirectory: URL?
    @Binding var mode: FetcherSourceItemMode
    @Binding var selectedItem: FetcherSourceItem?
    let stagedCandidateKeys: Set<String>
    let activeServerId: String?
    let actionMessage: String?
    let projects: [Project]
    let onStageCandidate: (FetcherCandidateImport) -> Void
    let onAddToProject: (Project, FetcherSourceCollection, FetcherSourceItemMode, [FetcherSourceItem]) -> Void
    let onCreateProject: (FetcherSourceCollection, FetcherSourceItemMode, [FetcherSourceItem]) -> Void

    @State private var availabilityFilter: FetcherSourceAvailabilityFilter = .all

    private var sourceItems: [FetcherSourceItem] {
        snapshot.items(for: collection.sourceCollectionKey, mode: mode)
    }

    private var visibleItems: [FetcherSourceItem] {
        sourceItems.filter { item in
            availabilityFilter.accepts(availability(for: item))
        }
    }

    private var candidates: [FetcherCandidateImport] {
        snapshot.candidates(for: collection.sourceCollectionKey)
    }

    private var diagnosticsSummary: FetcherSourceContractDiagnosticsSummary {
        snapshot.diagnosticsSummary(for: collection.sourceCollectionKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader

            if let actionMessage {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    FetcherContractDiagnosticsSection(summary: diagnosticsSummary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)

                    Divider()
                        .padding(.leading, 24)

                    FetcherGeneratedViewManifestsSection(
                        manifests: diagnosticsSummary.generatedViewManifests,
                        fixtureDirectory: fixtureDirectory
                    )
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)

                    Divider()
                        .padding(.leading, 24)

                    if sourceItems.isEmpty {
                        FetcherSourcesStatusView(
                            title: "No \(mode.rawValue) Items",
                            systemImage: "music.note.list",
                            message: "This source has no contract rows for the selected source state."
                        )
                        .padding(24)
                    } else if visibleItems.isEmpty {
                        FetcherSourcesStatusView(
                            title: "No Matching Items",
                            systemImage: "line.3.horizontal.decrease.circle",
                            message: "No \(mode.rawValue.lowercased()) rows match the \(availabilityFilter.label.lowercased()) filter."
                        )
                        .padding(24)
                    } else {
                        ForEach(visibleItems) { item in
                            let evidenceRows = snapshot.evidence(for: item.sourceItemKey)
                            FetcherSourceItemRow(
                                item: item,
                                isSelected: selectedItem?.id == item.id,
                                evidenceCount: evidenceRows.count,
                                availability: availability(for: item)
                            ) {
                                selectedItem = item
                            }
                            Divider()
                                .padding(.leading, 24)
                        }
                    }

                    if !candidates.isEmpty {
                        FetcherCandidateImportsSection(
                            candidates: candidates,
                            stagedCandidateKeys: stagedCandidateKeys,
                            activeServerId: activeServerId,
                            onStageCandidate: onStageCandidate
                        )
                            .padding(.top, 18)
                    }
                }
                .padding(.vertical, 8)
            }

            if let selectedItem {
                Divider()
                FetcherEvidencePanel(
                    item: selectedItem,
                    evidenceRows: snapshot.evidence(for: selectedItem.sourceItemKey),
                    identityRows: snapshot.identityRows(for: selectedItem.sourceItemKey),
                    candidates: snapshot.candidates(forSourceItem: selectedItem.sourceItemKey)
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: collection.sourceCollectionKey) { _, _ in
            selectedItem = nil
        }
        .onChange(of: mode) { _, _ in
            selectedItem = nil
        }
        .onChange(of: availabilityFilter) { _, _ in
            selectedItem = nil
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(collection.displayName)
                        .font(.title)
                        .fontWeight(.semibold)
                        .lineLimit(2)

                    HStack(spacing: 10) {
                        FetcherSourceKindBadge(text: collection.sourceKind)
                        FetcherSourceStaleBadge(staleState: collection.staleState)
                        Text("\(collection.currentItemCount) current")
                        Text("\(collection.allSeenItemCount) all seen")
                        Text("\(collection.removedItemCount) removed")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    if projects.isEmpty {
                        Text("No active projects")
                    } else {
                        ForEach(projects) { project in
                            Button {
                                onAddToProject(project, collection, mode, visibleItems)
                            } label: {
                                Label(project.name, systemImage: "tray.and.arrow.down")
                            }
                        }
                    }
                } label: {
                    Label("Add to Project", systemImage: "tray.and.arrow.down")
                }
                .disabled(activeServerId == nil || visibleItems.isEmpty || projects.isEmpty)
                .help("Add Navidrome-mapped songs from the filtered source view to an existing Resonance Project.")

                Button {
                    onCreateProject(collection, mode, visibleItems)
                } label: {
                    Label("Create Project", systemImage: "tray.full")
                }
                .disabled(activeServerId == nil || visibleItems.isEmpty)
                .help("Create a Resonance Project from Navidrome-mapped songs in the filtered source view.")
            }

            HStack(spacing: 12) {
                Picker("Source State", selection: $mode) {
                    ForEach(FetcherSourceItemMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)

                Picker("Availability", selection: $availabilityFilter) {
                    ForEach(FetcherSourceAvailabilityFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 170)

                Text("\(visibleItems.count) shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Source evidence and generated-view manifests come from a read-only local Fetcher export snapshot. Candidate actions, when available, stage Navidrome-matched songs only in Resonance Waiting Room and never write Fetcher state.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private func availability(for item: FetcherSourceItem) -> FetcherSourceItemAvailability {
        item.availability(
            evidenceRows: snapshot.evidence(for: item.sourceItemKey),
            identityRows: snapshot.identityRows(for: item.sourceItemKey),
            candidates: snapshot.candidates(forSourceItem: item.sourceItemKey)
        )
    }
}

private struct FetcherContractDiagnosticsSection: View {
    let summary: FetcherSourceContractDiagnosticsSummary

    private let columns = [
        GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)
    ]

    private var manifestRows: [FetcherGeneratedViewManifest] {
        Array((summary.activeGeneratedViewManifests + summary.inactiveGeneratedViewManifests).prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Diagnostics & Preflight")
                    .font(.headline)
                Text("Read-only Fetcher contract checks for this source collection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                FetcherDiagnosticsCard(
                    title: "Identity Bridge",
                    value: "\(summary.identityBridgeRows.count)",
                    detail: summary.identityBridgeRows.isEmpty ? "No mapped rows for this source." : firstBridgeDetail,
                    systemImage: "point.3.connected.trianglepath.dotted"
                )

                FetcherDiagnosticsCard(
                    title: "Generated Views",
                    value: "\(summary.activeGeneratedViewManifests.count) active",
                    detail: "\(summary.inactiveGeneratedViewManifests.count) inactive or unknown",
                    systemImage: "doc.text.magnifyingglass"
                )

                FetcherDiagnosticsCard(
                    title: "Contract Health",
                    value: "\(summary.warningHealthRows.count)",
                    detail: summary.warningHealthRows.first?.summary ?? "No source-scoped warnings.",
                    systemImage: summary.warningHealthRows.isEmpty ? "checkmark.seal" : "exclamationmark.triangle"
                )

                FetcherDiagnosticsCard(
                    title: "Candidate Preflight",
                    value: "\(summary.candidateStageability.stageableCount) ready",
                    detail: candidatePreflightDetail,
                    systemImage: "checklist"
                )
            }

            if !manifestRows.isEmpty || !summary.warningHealthRows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(manifestRows.enumerated()), id: \.offset) { _, manifest in
                        FetcherDiagnosticsLine(
                            title: manifest.displayKey,
                            detail: [
                                manifest.manifestKind,
                                manifest.resonanceScope,
                                manifest.activeStateLabel
                            ].compactMap { value in
                                guard let value, !value.isEmpty else { return nil }
                                return value
                            }.joined(separator: " - ")
                        )
                    }

                    ForEach(summary.warningHealthRows.prefix(3)) { healthRow in
                        FetcherDiagnosticsLine(
                            title: "\(healthRow.status.uppercased()): \(healthRow.healthKey)",
                            detail: healthRow.summary
                        )
                    }
                }
            }
        }
    }

    private var firstBridgeDetail: String {
        guard let bridgeRow = summary.identityBridgeRows.first else {
            return "No mapped rows for this source."
        }

        return [
            bridgeRow.mappingStatus,
            bridgeRow.mappingConfidence,
            bridgeRow.navidromeSongId.map { "Navidrome \($0)" }
        ].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " - ")
    }

    private var candidatePreflightDetail: String {
        let stageability = summary.candidateStageability
        return "\(stageability.missingNavidromeIDCount) missing Navidrome ID - \(stageability.unsupportedRouteCount) unsupported route - \(stageability.totalCount) total"
    }
}

private struct FetcherGeneratedViewManifestsSection: View {
    let manifests: [FetcherGeneratedViewManifest]
    let fixtureDirectory: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Generated View Manifests")
                    .font(.headline)
                Text("Fixture-relative generated outputs for this source. Previews are bounded local reads only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if manifests.isEmpty {
                FetcherDiagnosticsLine(
                    title: "No manifests",
                    detail: "No generated-view manifest rows are scoped to this source collection."
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(manifests.enumerated()), id: \.offset) { _, manifest in
                        FetcherGeneratedViewManifestRow(
                            manifest: manifest,
                            preview: preview(for: manifest)
                        )
                    }
                }
            }
        }
    }

    private func preview(for manifest: FetcherGeneratedViewManifest) -> FetcherGeneratedViewManifestOutputPreview? {
        guard let fixtureDirectory else { return nil }
        return FetcherContractLoader().previewGeneratedViewManifestOutput(
            for: manifest,
            fixtureDirectory: fixtureDirectory
        )
    }
}

private struct FetcherGeneratedViewManifestRow: View {
    let manifest: FetcherGeneratedViewManifest
    let preview: FetcherGeneratedViewManifestOutputPreview?

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 10, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.displayKey)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(manifest.manifestKind.fetcherDisplayValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(statusLabel)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                FetcherManifestField(label: "Scope", value: manifest.resonanceScope.fetcherDisplayValue)
                FetcherManifestField(label: "Active State", value: manifest.activeStateLabel)
                FetcherManifestField(label: "Item Count", value: manifest.itemCount.map(String.init) ?? "Unknown")
                FetcherManifestField(label: "Output Path", value: manifest.outputRelativePath.fetcherDisplayValue)
                FetcherManifestField(label: "Generated", value: manifest.generatedAt.fetcherDisplayValue)
                FetcherManifestField(label: "Contract Hash", value: manifest.contractHash.fetcherDisplayValue)
                FetcherManifestField(label: "Status", value: statusLabel)
            }

            if let preview, let text = preview.text {
                DisclosureGroup(preview.isTruncated ? "Output Preview (truncated to \(preview.byteLimit) bytes)" : "Output Preview") {
                    ScrollView(.horizontal) {
                        Text(text.isEmpty ? "Empty file." : text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .font(.caption)
            } else {
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var statusLabel: String {
        preview?.status.displayLabel ?? "Fixture directory unavailable"
    }

    private var statusDetail: String {
        preview?.status.detail ?? "The fixture directory for this snapshot is unavailable, so no output file was read."
    }

    private var statusColor: Color {
        guard let preview else { return .secondary }
        switch preview.status {
        case .available:
            return .green
        case .missingFile, .noOutputPath:
            return .secondary
        case .rejectedAbsolutePath, .rejectedPathTraversal, .rejectedOutsideFixtureDirectory, .unreadableFile:
            return .orange
        }
    }
}

private struct FetcherManifestField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

private struct FetcherDiagnosticsCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.title3)
                .fontWeight(.semibold)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct FetcherDiagnosticsLine: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(detail.isEmpty ? "No additional details." : detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct FetcherSourceCollectionRow: View {
    let collection: FetcherSourceCollection

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(collection.displayName)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(collection.sourceKind.fetcherSourceKindDisplayName)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())

                    Text("\(collection.currentItemCount) current / \(collection.allSeenItemCount) all seen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if collection.staleState != "fresh" {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(height: 38)
    }

    private var iconName: String {
        switch collection.sourceKind {
        case "apple_music_club_schedule":
            return "dot.radiowaves.left.and.right"
        case "apple_room", "dj_mix_room":
            return "square.grid.2x2"
        default:
            return "music.note.list"
        }
    }
}

private struct FetcherSourceItemRow: View {
    let item: FetcherSourceItem
    let isSelected: Bool
    let evidenceCount: Int
    let availability: FetcherSourceItemAvailability
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                if let position = item.position {
                    Text("\(position)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                } else {
                    Image(systemName: item.isCurrent ? "checkmark.circle" : "minus.circle")
                        .foregroundStyle(item.isCurrent ? .green : .secondary)
                        .frame(width: 28)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    FetcherLocalAvailabilityBadge(availability: availability)

                    Text("\(evidenceCount) evidence")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        [item.artistDisplay, item.albumOrRelease]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " - ")
    }
}

private struct FetcherCandidateImportsSection: View {
    let candidates: [FetcherCandidateImport]
    let stagedCandidateKeys: Set<String>
    let activeServerId: String?
    let onStageCandidate: (FetcherCandidateImport) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Candidate Imports")
                    .font(.headline)
                Text("Candidate rows from the fixture. Stage writes only to Resonance Waiting Room for the active Navidrome server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)

            ForEach(candidates.prefix(25)) { candidate in
                FetcherCandidateRow(
                    candidate: candidate,
                    isStaged: stagedCandidateKeys.contains(candidate.candidateKey),
                    disabledReason: candidate.stageDisabledReason(activeServerId: activeServerId)
                ) {
                    onStageCandidate(candidate)
                }
                Divider()
                    .padding(.leading, 24)
            }

            if candidates.count > 25 {
                Text("\(candidates.count - 25) more candidates not shown in this prototype.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
        }
    }
}

private struct FetcherCandidateRow: View {
    let candidate: FetcherCandidateImport
    let isStaged: Bool
    let disabledReason: String?
    let onStage: () -> Void

    private var route: FetcherCandidateRoute {
        FetcherCandidateRoute(rawContractValue: candidate.recommendedResonanceRoute)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .lineLimit(1)
                Text(candidate.artistDisplay ?? candidate.albumOrRelease ?? candidate.candidateState)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(route.displayLabel)
                .font(.caption)
                .foregroundStyle(route.isActionableWithoutPolicy ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())

            Button(isStaged ? "Staged" : "Stage", action: onStage)
                .disabled(isStaged || disabledReason != nil)
                .help(disabledReason ?? "Stage this Navidrome-matched Fetcher candidate in Waiting Room.")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
    }
}

private extension FetcherCandidateImport {
    var waitingRoomNotes: String {
        [
            recommendationReason,
            sourceCollectionKey.map { "Fetcher source: \($0)" },
            sourceItemKey.map { "Fetcher source item: \($0)" },
            localAssetKey.map { "Fetcher local asset: \($0)" }
        ]
        .compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        .joined(separator: "\n")
    }

    func stageDisabledReason(activeServerId: String?) -> String? {
        guard activeServerId != nil else {
            return "Choose an active server before staging Fetcher candidates."
        }

        guard FetcherCandidateRoute(rawContractValue: recommendedResonanceRoute) == .waitingRoom else {
            return "Only Waiting Room candidates can be staged from this prototype."
        }

        guard let navidromeSongId, !navidromeSongId.isEmpty else {
            return "This candidate is not mapped to a Navidrome song yet."
        }

        return nil
    }
}

private struct FetcherEvidencePanel: View {
    let item: FetcherSourceItem
    let evidenceRows: [FetcherSourceEvidence]
    let identityRows: [FetcherIdentityBridgeRow]
    let candidates: [FetcherCandidateImport]

    private var availability: FetcherSourceItemAvailability {
        item.availability(
            evidenceRows: evidenceRows,
            identityRows: identityRows,
            candidates: candidates
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Evidence")
                    .font(.headline)
                Spacer()
                Text(item.sourceItemKind.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(item.title)
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 8) {
                FetcherLocalAvailabilityBadge(availability: availability)
                Text(availability.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if evidenceRows.isEmpty {
                Text("No evidence rows for this source item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(evidenceRows.prefix(4)) { evidence in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(evidence.evidenceLabel)
                            .font(.caption)
                        Text("\(evidence.evidenceKind) - \(evidence.confidence)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

private enum FetcherSourceItemAvailability: Equatable {
    case indexed
    case localAsset
    case candidate(String)
    case observedOnly

    var label: String {
        switch self {
        case .indexed:
            return "Indexed"
        case .localAsset:
            return "Available Locally"
        case let .candidate(state):
            return state.fetcherSourceKindDisplayName
        case .observedOnly:
            return "Observed Only"
        }
    }

    var detail: String {
        switch self {
        case .indexed:
            return "Mapped to a Navidrome song through the Fetcher contract."
        case .localAsset:
            return "Fetcher evidence includes a local asset identity, but no Navidrome song ID is mapped yet."
        case let .candidate(state):
            return "Candidate import state from Fetcher: \(state.fetcherSourceKindDisplayName)."
        case .observedOnly:
            return "Source evidence only. This does not create Library membership."
        }
    }

    var color: Color {
        switch self {
        case .indexed:
            return .green
        case .localAsset:
            return .blue
        case .candidate:
            return .orange
        case .observedOnly:
            return .secondary
        }
    }
}

private enum FetcherSourceAvailabilityFilter: String, CaseIterable, Identifiable {
    case all
    case indexed
    case localAsset
    case candidate
    case observedOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:
            return "All Availability"
        case .indexed:
            return "Indexed"
        case .localAsset:
            return "Local Asset"
        case .candidate:
            return "Candidates"
        case .observedOnly:
            return "Observed Only"
        }
    }

    func accepts(_ availability: FetcherSourceItemAvailability) -> Bool {
        switch (self, availability) {
        case (.all, _), (.indexed, .indexed), (.localAsset, .localAsset), (.candidate, .candidate(_)), (.observedOnly, .observedOnly):
            return true
        default:
            return false
        }
    }
}

private struct FetcherLocalAvailabilityBadge: View {
    let availability: FetcherSourceItemAvailability

    var body: some View {
        Text(availability.label)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(availability.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .help(availability.detail)
    }
}

private struct FetcherSourceKindBadge: View {
    let text: String

    var body: some View {
        Text(text.replacingOccurrences(of: "_", with: " "))
            .textCase(.uppercase)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

private struct FetcherSourceStaleBadge: View {
    let staleState: String

    var body: some View {
        Text(staleState)
            .textCase(.uppercase)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(staleState == "fresh" ? .green : .orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

private extension Optional where Wrapped == String {
    var fetcherDisplayValue: String {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return "Not provided"
        }
        return value
    }
}

private extension String {
    var fetcherSourceKindDisplayName: String {
        replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private extension FetcherContractSnapshot {
    func identityRows(for sourceItemKey: String) -> [FetcherIdentityBridgeRow] {
        bridgeRowsBySourceItemKey[sourceItemKey] ?? []
    }

    /// Same rows as the snapshot's own per-item accessor, but ordered by title
    /// for display. Per-item buckets hold a handful of rows, so the sort is free.
    func candidates(forSourceItem sourceItemKey: String) -> [FetcherCandidateImport] {
        (candidatesBySourceItemKey[sourceItemKey] ?? [])
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

private extension FetcherSourceItem {
    func availability(
        evidenceRows: [FetcherSourceEvidence],
        identityRows: [FetcherIdentityBridgeRow],
        candidates: [FetcherCandidateImport]
    ) -> FetcherSourceItemAvailability {
        if identityRows.contains(where: { row in
            guard let navidromeSongId = row.navidromeSongId else { return false }
            return !navidromeSongId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return .indexed
        }

        if identityRows.contains(where: { row in
            guard let localAssetKey = row.localAssetKey else { return false }
            return !localAssetKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) || evidenceRows.contains(where: { row in
            guard let localAssetKey = row.localAssetKey else { return false }
            return !localAssetKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return .localAsset
        }

        if let candidate = candidates.first {
            return .candidate(candidate.candidateState)
        }

        return .observedOnly
    }
}

private struct FetcherSourcesStatusView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
