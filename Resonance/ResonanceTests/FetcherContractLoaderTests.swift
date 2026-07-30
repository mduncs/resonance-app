import XCTest
@testable import Resonance

final class FetcherContractLoaderTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for tempDir in tempDirs {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDirs = []
        try super.tearDownWithError()
    }

    func testLoaderDecodesContractSnapshotWithoutCurationState() throws {
        let directory = try writeMinimalFixture()

        let snapshot = try FetcherContractLoader().loadSnapshot(from: directory)

        XCTAssertEqual(snapshot.metadata.fetcherContractVersion, 1)
        XCTAssertEqual(snapshot.sourceCollections.count, 1)
        XCTAssertEqual(snapshot.sourceItems.count, 2)
        XCTAssertEqual(snapshot.items(for: "fetcher:source_collection:alpha", mode: .current).map(\.title), ["Alpha Track"])
        XCTAssertEqual(snapshot.items(for: "fetcher:source_collection:alpha", mode: .removed).map(\.title), ["Removed Track"])
        XCTAssertEqual(snapshot.candidates(for: "fetcher:source_collection:alpha").first?.recommendedResonanceRoute, "waiting_room")
        XCTAssertEqual(snapshot.generatedViewManifests.first?.manifestKind, "resonance_source_fixture")
        XCTAssertTrue(snapshot.generatedViewManifests.first?.isActive == true)
        XCTAssertEqual(FetcherCandidateRoute(rawContractValue: "waiting_room").displayLabel, "Waiting Room")
        XCTAssertTrue(FetcherCandidateRoute(rawContractValue: "needs_policy").isActionableWithoutPolicy == false)
    }

    func testConfiguredEnvironmentFixtureDecodesFromTempDirectory() throws {
        let directory = try writeMinimalFixture()

        let configuredDirectory = FetcherContractLoader().configuredDirectory(
            environment: ["RESONANCE_FETCHER_CONTRACT_FIXTURE_DIR": directory.path]
        )
        let snapshot = try FetcherContractLoader().loadSnapshot(from: try XCTUnwrap(configuredDirectory))

        XCTAssertEqual(snapshot.metadata.exportSchemaVersion, 1)
        XCTAssertEqual(snapshot.metadata.fetcherContractVersion, 1)
        XCTAssertEqual(snapshot.metadata.rowCounts["source-collections.json"], snapshot.sourceCollections.count)
        XCTAssertEqual(snapshot.metadata.rowCounts["source-items.json"], snapshot.sourceItems.count)
        XCTAssertEqual(snapshot.metadata.rowCounts["source-evidence.json"], snapshot.sourceEvidence.count)
        XCTAssertEqual(snapshot.metadata.rowCounts["candidate-imports.json"], snapshot.candidateImports.count)
        XCTAssertEqual(snapshot.metadata.rowCounts["identity-bridge.json"], snapshot.identityBridge.count)
        XCTAssertEqual(snapshot.metadata.rowCounts["generated-view-manifests.json"], snapshot.generatedViewManifests.count)
        XCTAssertEqual(snapshot.metadata.rowCounts["contract-health.json"], snapshot.contractHealth.count)
        XCTAssertFalse(snapshot.sourceCollections.isEmpty)
    }

    func testConfiguredFetcherExportDecodesWhenProvided() throws {
        let exportPath = ProcessInfo.processInfo.environment["RESONANCE_FETCHER_CONTRACT_FIXTURE_DIR"] ?? ""
        guard !exportPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set RESONANCE_FETCHER_CONTRACT_FIXTURE_DIR to smoke-test a real Fetcher export.")
        }

        let snapshot = try FetcherContractLoader().loadSnapshot(from: URL(fileURLWithPath: exportPath))

        XCTAssertEqual(snapshot.metadata.exportSchemaVersion, 1)
        XCTAssertEqual(snapshot.metadata.fetcherContractVersion, 1)
        XCTAssertEqual(snapshot.metadata.rowCounts["source-collections.json"], snapshot.sourceCollections.count)
        XCTAssertEqual(snapshot.metadata.rowCounts["source-items.json"], snapshot.sourceItems.count)
        XCTAssertEqual(snapshot.metadata.rowCounts["source-evidence.json"], snapshot.sourceEvidence.count)
        XCTAssertEqual(snapshot.metadata.rowCounts["candidate-imports.json"], snapshot.candidateImports.count)
        XCTAssertEqual(snapshot.metadata.rowCounts["identity-bridge.json"], snapshot.identityBridge.count)
        XCTAssertEqual(snapshot.metadata.rowCounts["generated-view-manifests.json"], snapshot.generatedViewManifests.count)
        XCTAssertEqual(snapshot.metadata.rowCounts["contract-health.json"], snapshot.contractHealth.count)
        XCTAssertFalse(snapshot.sourceCollections.isEmpty)
    }

    func testConfiguredDirectoryPrefersEnvironmentOverride() throws {
        let suiteName = "FetcherContractLoaderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("/stored/path", forKey: FetcherContractSettings.fixtureDirectoryKey)

        let url = FetcherContractLoader().configuredDirectory(
            defaults: defaults,
            environment: ["RESONANCE_FETCHER_CONTRACT_FIXTURE_DIR": "/env/path"]
        )

        XCTAssertEqual(url?.path, "/env/path")
    }

    func testMissingRequiredFileFailsClearly() throws {
        let directory = try makeTempDir()
        try write("{}", named: "contract-version.json", in: directory)

        XCTAssertThrowsError(try FetcherContractLoader().loadSnapshot(from: directory)) { error in
            XCTAssertEqual(error as? FetcherContractLoaderError, .missingFile("source-collections.json"))
        }
    }

    func testUnsupportedVersionsFailBeforeRowsAreTrusted() throws {
        let directory = try writeMinimalFixture(exportSchemaVersion: 2)

        XCTAssertThrowsError(try FetcherContractLoader().loadSnapshot(from: directory)) { error in
            XCTAssertEqual(error as? FetcherContractLoaderError, .unsupportedExportSchemaVersion(2))
        }
    }

    func testSourceDiagnosticsSummariesAreFixtureOnlyAndReadOnly() throws {
        let directory = try writeDiagnosticsFixture()

        let snapshot = try FetcherContractLoader().loadSnapshot(from: directory)
        let alpha = snapshot.diagnosticsSummary(for: "fetcher:source_collection:alpha")
        let beta = snapshot.diagnosticsSummary(for: "fetcher:source_collection:beta")

        XCTAssertEqual(alpha.identityBridgeRows.map(\.bridgeKey), ["bridge:alpha-one", "bridge:alpha-two"])
        XCTAssertEqual(beta.identityBridgeRows.map(\.bridgeKey), ["bridge:beta-one"])

        XCTAssertEqual(alpha.generatedViewManifests.count, 3)
        XCTAssertEqual(alpha.activeGeneratedViewManifests.map(\.manifestKey), ["manifest:alpha-active"])
        XCTAssertEqual(alpha.inactiveGeneratedViewManifests.count, 2)
        XCTAssertTrue(alpha.inactiveGeneratedViewManifests.contains { $0.manifestKey == nil })
        XCTAssertEqual(
            alpha.generatedViewManifests.first { $0.manifestKey == "manifest:alpha-unknown" }?.activeStateLabel,
            "Unknown (2)"
        )
        XCTAssertEqual(beta.activeGeneratedViewManifests.map(\.manifestKey), ["manifest:beta-active"])

        XCTAssertEqual(snapshot.warningHealthRows.map(\.status).sorted(), ["mystery", "warn", "warn", "warn"])
        XCTAssertEqual(alpha.warningHealthRows.map(\.healthKey), ["health:alpha-mystery", "health:alpha-warn"])
        XCTAssertEqual(beta.warningHealthRows.map(\.healthKey), ["health:beta-warn"])

        XCTAssertEqual(alpha.candidateStageability.totalCount, 4)
        XCTAssertEqual(alpha.candidateStageability.stageableCount, 1)
        XCTAssertEqual(alpha.candidateStageability.missingNavidromeIDCount, 1)
        XCTAssertEqual(alpha.candidateStageability.unsupportedRouteCount, 2)

        XCTAssertEqual(snapshot.navidromeSongIds(forSourceItem: "source:alpha-one"), ["nav-song-alpha-one"])
        XCTAssertEqual(snapshot.navidromeSongIds(forSourceItem: "source:alpha-stageable"), ["nav-song-alpha"])
        XCTAssertEqual(snapshot.navidromeSongIds(forSourceItem: "source:alpha-missing-id"), [])
    }

    func testMappedNavidromeSongIdsPreserveSourceOrderAndMode() {
        let snapshot = FetcherContractSnapshot(
            metadata: FetcherContractMetadata(
                exportSchemaVersion: 1,
                generatedAt: "2026-05-02T00:00:00.000Z",
                fetcherContractVersion: 1,
                sourceDatabase: FetcherContractSourceDatabase(label: "fixture"),
                rowCounts: [:],
                contentHash: "sha256:fixture",
                files: [],
                redactedPaths: true
            ),
            sourceCollections: [],
            sourceItems: [
                FetcherSourceItem(
                    sourceCollectionKey: "source:alpha",
                    sourceItemKey: "item:second",
                    sourceItemKind: "song",
                    title: "Second",
                    artistDisplay: nil,
                    albumOrRelease: nil,
                    durationMs: nil,
                    externalUrl: nil,
                    externalId: nil,
                    position: 2,
                    isCurrentValue: 1,
                    firstSeenAt: nil,
                    lastSeenAt: nil,
                    removedAt: nil,
                    latestObservationKey: nil,
                    membershipFactKey: nil,
                    metadataJson: nil
                ),
                FetcherSourceItem(
                    sourceCollectionKey: "source:alpha",
                    sourceItemKey: "item:first",
                    sourceItemKind: "song",
                    title: "First",
                    artistDisplay: nil,
                    albumOrRelease: nil,
                    durationMs: nil,
                    externalUrl: nil,
                    externalId: nil,
                    position: 1,
                    isCurrentValue: 1,
                    firstSeenAt: nil,
                    lastSeenAt: nil,
                    removedAt: nil,
                    latestObservationKey: nil,
                    membershipFactKey: nil,
                    metadataJson: nil
                ),
                FetcherSourceItem(
                    sourceCollectionKey: "source:alpha",
                    sourceItemKey: "item:removed",
                    sourceItemKind: "song",
                    title: "Removed",
                    artistDisplay: nil,
                    albumOrRelease: nil,
                    durationMs: nil,
                    externalUrl: nil,
                    externalId: nil,
                    position: 3,
                    isCurrentValue: 0,
                    firstSeenAt: nil,
                    lastSeenAt: nil,
                    removedAt: "2026-05-02T00:00:00.000Z",
                    latestObservationKey: nil,
                    membershipFactKey: nil,
                    metadataJson: nil
                )
            ],
            sourceEvidence: [],
            candidateImports: [
                FetcherCandidateImport(
                    candidateKey: "candidate:first-duplicate",
                    sourceCollectionKey: "source:alpha",
                    sourceItemKey: "item:first",
                    fetcherCanonicalItemKey: nil,
                    localAssetKey: nil,
                    navidromeSongId: "nav-first",
                    title: "First",
                    artistDisplay: nil,
                    albumOrRelease: nil,
                    candidateState: "downloaded",
                    recommendedResonanceRoute: "waiting_room",
                    recommendationReason: nil,
                    firstSeenAt: nil,
                    updatedAt: nil,
                    errorSummary: nil,
                    detailsJson: nil
                ),
                FetcherCandidateImport(
                    candidateKey: "candidate:removed",
                    sourceCollectionKey: "source:alpha",
                    sourceItemKey: "item:removed",
                    fetcherCanonicalItemKey: nil,
                    localAssetKey: nil,
                    navidromeSongId: "nav-removed",
                    title: "Removed",
                    artistDisplay: nil,
                    albumOrRelease: nil,
                    candidateState: "downloaded",
                    recommendedResonanceRoute: "waiting_room",
                    recommendationReason: nil,
                    firstSeenAt: nil,
                    updatedAt: nil,
                    errorSummary: nil,
                    detailsJson: nil
                )
            ],
            identityBridge: [
                FetcherIdentityBridgeRow(
                    bridgeKey: "bridge:first",
                    sourceItemKey: "item:first",
                    sourceCollectionKey: "source:alpha",
                    fetcherCanonicalItemKey: nil,
                    downloadJobKey: nil,
                    localAssetKey: nil,
                    localFileRelativePath: nil,
                    contentFingerprint: nil,
                    navidromeSongId: "nav-first",
                    navidromeAlbumId: nil,
                    navidromeArtistId: nil,
                    resonanceImportKey: "first",
                    mappingConfidence: "exact",
                    mappingStatus: "active",
                    updatedAt: nil,
                    notesJson: nil
                ),
                FetcherIdentityBridgeRow(
                    bridgeKey: "bridge:second",
                    sourceItemKey: "item:second",
                    sourceCollectionKey: "source:alpha",
                    fetcherCanonicalItemKey: nil,
                    downloadJobKey: nil,
                    localAssetKey: nil,
                    localFileRelativePath: nil,
                    contentFingerprint: nil,
                    navidromeSongId: "nav-second",
                    navidromeAlbumId: nil,
                    navidromeArtistId: nil,
                    resonanceImportKey: "second",
                    mappingConfidence: "exact",
                    mappingStatus: "active",
                    updatedAt: nil,
                    notesJson: nil
                )
            ],
            generatedViewManifests: [],
            contractHealth: []
        )

        XCTAssertEqual(snapshot.mappedNavidromeSongIds(for: "source:alpha", mode: .current), ["nav-first", "nav-second"])
        XCTAssertEqual(snapshot.mappedNavidromeSongIds(for: "source:alpha", mode: .allSeen), ["nav-first", "nav-second", "nav-removed"])
        XCTAssertEqual(snapshot.mappedNavidromeSongIds(for: "source:alpha", mode: .removed), ["nav-removed"])
    }

    func testSongSourceEvidenceJoinsBridgeCandidatesAndDedupesSourceItems() {
        let snapshot = FetcherContractSnapshot(
            metadata: FetcherContractMetadata(
                exportSchemaVersion: 1,
                generatedAt: "2026-05-02T00:00:00.000Z",
                fetcherContractVersion: 1,
                sourceDatabase: FetcherContractSourceDatabase(label: "fixture"),
                rowCounts: [:],
                contentHash: "sha256:fixture",
                files: [],
                redactedPaths: true
            ),
            sourceCollections: [
                FetcherSourceCollection(
                    sourceCollectionKey: "source:alpha",
                    sourceKind: "apple_playlist",
                    domain: "apple_music",
                    displayName: "Alpha Source",
                    externalUrl: nil,
                    externalId: nil,
                    lastObservedAt: nil,
                    lastSuccessfulObservedAt: nil,
                    staleState: "fresh",
                    currentItemCount: 2,
                    allSeenItemCount: 2,
                    removedItemCount: 0,
                    lastChangeAt: nil,
                    sourceSpecificJson: nil,
                    contractVersion: 1
                ),
                FetcherSourceCollection(
                    sourceCollectionKey: "source:beta",
                    sourceKind: "apple_radio",
                    domain: "apple_music",
                    displayName: "Beta Source",
                    externalUrl: nil,
                    externalId: nil,
                    lastObservedAt: nil,
                    lastSuccessfulObservedAt: nil,
                    staleState: "fresh",
                    currentItemCount: 1,
                    allSeenItemCount: 1,
                    removedItemCount: 0,
                    lastChangeAt: nil,
                    sourceSpecificJson: nil,
                    contractVersion: 1
                )
            ],
            sourceItems: [
                FetcherSourceItem(
                    sourceCollectionKey: "source:alpha",
                    sourceItemKey: "item:bridge",
                    sourceItemKind: "track",
                    title: "Bridge Track",
                    artistDisplay: "Alpha Artist",
                    albumOrRelease: "Alpha Album",
                    durationMs: nil,
                    externalUrl: nil,
                    externalId: nil,
                    position: 2,
                    isCurrentValue: 1,
                    firstSeenAt: nil,
                    lastSeenAt: nil,
                    removedAt: nil,
                    latestObservationKey: nil,
                    membershipFactKey: nil,
                    metadataJson: nil
                ),
                FetcherSourceItem(
                    sourceCollectionKey: "source:beta",
                    sourceItemKey: "item:candidate",
                    sourceItemKind: "track",
                    title: "Candidate Track",
                    artistDisplay: "Beta Artist",
                    albumOrRelease: "Beta Album",
                    durationMs: nil,
                    externalUrl: nil,
                    externalId: nil,
                    position: 1,
                    isCurrentValue: 1,
                    firstSeenAt: nil,
                    lastSeenAt: nil,
                    removedAt: nil,
                    latestObservationKey: nil,
                    membershipFactKey: nil,
                    metadataJson: nil
                ),
                FetcherSourceItem(
                    sourceCollectionKey: "source:alpha",
                    sourceItemKey: "item:duplicate",
                    sourceItemKind: "track",
                    title: "Duplicate Track",
                    artistDisplay: "Alpha Artist",
                    albumOrRelease: "Alpha Album",
                    durationMs: nil,
                    externalUrl: nil,
                    externalId: nil,
                    position: 1,
                    isCurrentValue: 1,
                    firstSeenAt: nil,
                    lastSeenAt: nil,
                    removedAt: nil,
                    latestObservationKey: nil,
                    membershipFactKey: nil,
                    metadataJson: nil
                )
            ],
            sourceEvidence: [
                FetcherSourceEvidence(
                    evidenceKey: "evidence:bridge",
                    sourceCollectionKey: "source:alpha",
                    sourceItemKey: "item:bridge",
                    localAssetKey: "local:bridge",
                    fetcherCanonicalItemKey: "apple_song:bridge",
                    evidenceKind: "current_membership",
                    evidenceLabel: "Current in Alpha Source",
                    firstSeenAt: nil,
                    lastSeenAt: nil,
                    removedAt: nil,
                    position: 2,
                    confidence: "exact",
                    detailsJson: nil
                ),
                FetcherSourceEvidence(
                    evidenceKey: "evidence:candidate",
                    sourceCollectionKey: "source:beta",
                    sourceItemKey: "item:candidate",
                    localAssetKey: "local:candidate",
                    fetcherCanonicalItemKey: "apple_song:candidate",
                    evidenceKind: "current_membership",
                    evidenceLabel: "Current in Beta Source",
                    firstSeenAt: nil,
                    lastSeenAt: nil,
                    removedAt: nil,
                    position: 1,
                    confidence: "exact",
                    detailsJson: nil
                ),
                FetcherSourceEvidence(
                    evidenceKey: "evidence:duplicate",
                    sourceCollectionKey: "source:alpha",
                    sourceItemKey: "item:duplicate",
                    localAssetKey: "local:duplicate",
                    fetcherCanonicalItemKey: "apple_song:duplicate",
                    evidenceKind: "current_membership",
                    evidenceLabel: "Current in Alpha Source duplicate",
                    firstSeenAt: nil,
                    lastSeenAt: nil,
                    removedAt: nil,
                    position: 1,
                    confidence: "exact",
                    detailsJson: nil
                )
            ],
            candidateImports: [
                FetcherCandidateImport(
                    candidateKey: "candidate:candidate",
                    sourceCollectionKey: "source:beta",
                    sourceItemKey: "item:candidate",
                    fetcherCanonicalItemKey: "apple_song:candidate",
                    localAssetKey: "local:candidate",
                    navidromeSongId: "nav-candidate",
                    title: "Candidate Track",
                    artistDisplay: "Beta Artist",
                    albumOrRelease: "Beta Album",
                    candidateState: "downloaded",
                    recommendedResonanceRoute: "waiting_room",
                    recommendationReason: nil,
                    firstSeenAt: nil,
                    updatedAt: nil,
                    errorSummary: nil,
                    detailsJson: nil
                ),
                FetcherCandidateImport(
                    candidateKey: "candidate:duplicate",
                    sourceCollectionKey: "source:alpha",
                    sourceItemKey: "item:duplicate",
                    fetcherCanonicalItemKey: "apple_song:duplicate",
                    localAssetKey: "local:duplicate",
                    navidromeSongId: "nav-duplicate",
                    title: "Duplicate Track",
                    artistDisplay: "Alpha Artist",
                    albumOrRelease: "Alpha Album",
                    candidateState: "downloaded",
                    recommendedResonanceRoute: "waiting_room",
                    recommendationReason: nil,
                    firstSeenAt: nil,
                    updatedAt: nil,
                    errorSummary: nil,
                    detailsJson: nil
                )
            ],
            identityBridge: [
                FetcherIdentityBridgeRow(
                    bridgeKey: "bridge:bridge",
                    sourceItemKey: "item:bridge",
                    sourceCollectionKey: "source:alpha",
                    fetcherCanonicalItemKey: "apple_song:bridge",
                    downloadJobKey: nil,
                    localAssetKey: "local:bridge",
                    localFileRelativePath: nil,
                    contentFingerprint: nil,
                    navidromeSongId: "nav-bridge",
                    navidromeAlbumId: nil,
                    navidromeArtistId: nil,
                    resonanceImportKey: "bridge",
                    mappingConfidence: "exact",
                    mappingStatus: "active",
                    updatedAt: nil,
                    notesJson: nil
                ),
                FetcherIdentityBridgeRow(
                    bridgeKey: "bridge:duplicate",
                    sourceItemKey: "item:duplicate",
                    sourceCollectionKey: "source:alpha",
                    fetcherCanonicalItemKey: "apple_song:duplicate",
                    downloadJobKey: nil,
                    localAssetKey: "local:duplicate",
                    localFileRelativePath: nil,
                    contentFingerprint: nil,
                    navidromeSongId: "nav-duplicate",
                    navidromeAlbumId: nil,
                    navidromeArtistId: nil,
                    resonanceImportKey: "duplicate",
                    mappingConfidence: "exact",
                    mappingStatus: "active",
                    updatedAt: nil,
                    notesJson: nil
                )
            ],
            generatedViewManifests: [],
            contractHealth: []
        )

        let bridgeEvidence = snapshot.songSourceEvidence(forNavidromeSongId: " nav-bridge ")
        XCTAssertEqual(bridgeEvidence.map(\.sourceItem.sourceItemKey), ["item:bridge"])
        XCTAssertEqual(bridgeEvidence.first?.collectionDisplayName, "Alpha Source")
        XCTAssertEqual(bridgeEvidence.first?.mappingSummary, "Active / Exact")
        XCTAssertEqual(bridgeEvidence.first?.evidenceRows.map(\.evidenceLabel), ["Current in Alpha Source"])

        let candidateEvidence = snapshot.songSourceEvidence(forNavidromeSongId: "nav-candidate")
        XCTAssertEqual(candidateEvidence.map(\.sourceItem.sourceItemKey), ["item:candidate"])
        XCTAssertEqual(candidateEvidence.first?.collectionDisplayName, "Beta Source")
        XCTAssertEqual(candidateEvidence.first?.mappingSummary, "Candidate: Downloaded")

        let dedupedEvidence = snapshot.songSourceEvidence(forNavidromeSongId: "nav-duplicate")
        XCTAssertEqual(dedupedEvidence.map(\.sourceItem.sourceItemKey), ["item:duplicate"])
        XCTAssertEqual(dedupedEvidence.first?.evidenceRows.map(\.evidenceLabel), ["Current in Alpha Source duplicate"])

        XCTAssertTrue(snapshot.songSourceEvidence(forNavidromeSongId: "missing-song").isEmpty)
    }

    func testGeneratedViewManifestPreviewTreatsMissingAndNilOutputAsNonFatalStatus() throws {
        let directory = try makeTempDir()
        let loader = FetcherContractLoader()

        let missing = loader.previewGeneratedViewManifestOutput(
            relativePath: "fixtures/missing-output.json",
            fixtureDirectory: directory
        )
        let nilPath = loader.previewGeneratedViewManifestOutput(
            relativePath: nil,
            fixtureDirectory: directory
        )

        XCTAssertEqual(missing.status, .missingFile)
        XCTAssertTrue(missing.resolvedPath?.hasSuffix("fixtures/missing-output.json") == true)
        XCTAssertNil(missing.text)
        XCTAssertFalse(missing.isTruncated)
        XCTAssertEqual(nilPath.status, .noOutputPath)
        XCTAssertNil(nilPath.resolvedPath)
    }

    func testGeneratedViewManifestPreviewRejectsTraversalAbsoluteAndEscapingSymlinkPaths() throws {
        let fixtureDirectory = try makeTempDir()
        let outsideDirectory = try makeTempDir()
        try write("outside", named: "outside.json", in: outsideDirectory)

        let loader = FetcherContractLoader()
        let traversal = loader.previewGeneratedViewManifestOutput(
            relativePath: "../\(outsideDirectory.lastPathComponent)/outside.json",
            fixtureDirectory: fixtureDirectory
        )
        let absolute = loader.previewGeneratedViewManifestOutput(
            relativePath: outsideDirectory.appendingPathComponent("outside.json").path,
            fixtureDirectory: fixtureDirectory
        )

        let symlinkURL = fixtureDirectory.appendingPathComponent("escaping-link.json")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: outsideDirectory.appendingPathComponent("outside.json")
        )
        let escapingSymlink = loader.previewGeneratedViewManifestOutput(
            relativePath: "escaping-link.json",
            fixtureDirectory: fixtureDirectory
        )

        XCTAssertEqual(traversal.status, .rejectedPathTraversal)
        XCTAssertNil(traversal.text)
        XCTAssertEqual(absolute.status, .rejectedAbsolutePath)
        XCTAssertNil(absolute.text)
        XCTAssertEqual(escapingSymlink.status, .rejectedOutsideFixtureDirectory)
        XCTAssertNil(escapingSymlink.text)
    }

    func testGeneratedViewManifestPreviewReadsBoundedRawTextUnderFixtureDirectory() throws {
        let directory = try makeTempDir()
        let outputDirectory = directory.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try write("abcdefghijklmnopqrstuvwxyz", named: "bounded.json", in: outputDirectory)

        let preview = FetcherContractLoader().previewGeneratedViewManifestOutput(
            relativePath: "fixtures/bounded.json",
            fixtureDirectory: directory,
            byteLimit: 8
        )

        XCTAssertEqual(preview.status, .available)
        XCTAssertEqual(preview.text, "abcdefgh")
        XCTAssertEqual(preview.byteLimit, 8)
        XCTAssertTrue(preview.isTruncated)
    }

    private func writeMinimalFixture(
        exportSchemaVersion: Int = 1,
        contractVersion: Int = 1
    ) throws -> URL {
        let directory = try makeTempDir()

        try write(
            """
            {
              "export_schema_version": \(exportSchemaVersion),
              "generated_at": "2026-05-02T00:00:00.000Z",
              "fetcher_contract_version": \(contractVersion),
              "source_database": { "label": "fixture" },
              "row_counts": {
                "source-collections.json": 1,
                "source-items.json": 2,
                "source-evidence.json": 1,
                "candidate-imports.json": 1,
                "identity-bridge.json": 1,
                "generated-view-manifests.json": 1,
                "contract-health.json": 1
              },
              "content_hash": "sha256:fixture",
              "files": [],
              "redacted_paths": false
            }
            """,
            named: "contract-version.json",
            in: directory
        )

        try write(
            """
            [
              {
                "source_collection_key": "fetcher:source_collection:alpha",
                "source_kind": "apple_playlist",
                "domain": "apple_music",
                "display_name": "Alpha Source",
                "external_url": "https://music.apple.com/playlist/alpha",
                "external_id": "pl.alpha",
                "last_observed_at": "2026-05-02T00:00:00.000Z",
                "last_successful_observed_at": "2026-05-02T00:00:00.000Z",
                "stale_state": "fresh",
                "current_item_count": 1,
                "all_seen_item_count": 2,
                "removed_item_count": 1,
                "last_change_at": "2026-05-02T00:00:00.000Z",
                "source_specific_json": "{}",
                "contract_version": 1
              }
            ]
            """,
            named: "source-collections.json",
            in: directory
        )

        try write(
            """
            [
              {
                "source_collection_key": "fetcher:source_collection:alpha",
                "source_item_key": "source:alpha-track",
                "source_item_kind": "track",
                "title": "Alpha Track",
                "artist_display": "Alpha Artist",
                "album_or_release": "Alpha Album",
                "duration_ms": 180000,
                "external_url": null,
                "external_id": "song.alpha",
                "position": 1,
                "is_current": 1,
                "first_seen_at": "2026-05-02T00:00:00.000Z",
                "last_seen_at": "2026-05-02T00:00:00.000Z",
                "removed_at": null,
                "latest_observation_key": "source_observation:1",
                "membership_fact_key": "playlist_track:1",
                "metadata_json": "{}"
              },
              {
                "source_collection_key": "fetcher:source_collection:alpha",
                "source_item_key": "source:removed-track",
                "source_item_kind": "track",
                "title": "Removed Track",
                "artist_display": "Beta Artist",
                "album_or_release": "Beta Album",
                "duration_ms": 180000,
                "external_url": null,
                "external_id": "song.removed",
                "position": 2,
                "is_current": 0,
                "first_seen_at": "2026-05-01T00:00:00.000Z",
                "last_seen_at": "2026-05-01T00:00:00.000Z",
                "removed_at": "2026-05-02T00:00:00.000Z",
                "latest_observation_key": "source_observation:1",
                "membership_fact_key": "playlist_track:2",
                "metadata_json": "{}"
              }
            ]
            """,
            named: "source-items.json",
            in: directory
        )

        try write(
            """
            [
              {
                "evidence_key": "evidence:alpha-track",
                "source_collection_key": "fetcher:source_collection:alpha",
                "source_item_key": "source:alpha-track",
                "local_asset_key": "fetcher:local_asset:playlist_track:1",
                "fetcher_canonical_item_key": "apple_song:song.alpha",
                "evidence_kind": "current_membership",
                "evidence_label": "Current in Apple Music playlist",
                "first_seen_at": "2026-05-02T00:00:00.000Z",
                "last_seen_at": "2026-05-02T00:00:00.000Z",
                "removed_at": null,
                "position": 1,
                "confidence": "exact",
                "details_json": "{}"
              }
            ]
            """,
            named: "source-evidence.json",
            in: directory
        )

        try write(
            """
            [
              {
                "candidate_key": "candidate:alpha-track",
                "source_collection_key": "fetcher:source_collection:alpha",
                "source_item_key": "source:alpha-track",
                "fetcher_canonical_item_key": "apple_song:song.alpha",
                "local_asset_key": "fetcher:local_asset:playlist_track:1",
                "navidrome_song_id": null,
                "title": "Alpha Track",
                "artist_display": "Alpha Artist",
                "album_or_release": "Alpha Album",
                "candidate_state": "downloaded",
                "recommended_resonance_route": "waiting_room",
                "recommendation_reason": "Local asset exists.",
                "first_seen_at": "2026-05-02T00:00:00.000Z",
                "updated_at": "2026-05-02T00:00:00.000Z",
                "error_summary": null,
                "details_json": "{}"
              }
            ]
            """,
            named: "candidate-imports.json",
            in: directory
        )

        try write(
            """
            [
              {
                "bridge_key": "bridge:alpha-track",
                "source_item_key": "source:alpha-track",
                "source_collection_key": "fetcher:source_collection:alpha",
                "fetcher_canonical_item_key": "apple_song:song.alpha",
                "download_job_key": null,
                "local_asset_key": "fetcher:local_asset:playlist_track:1",
                "local_file_relative_path": null,
                "content_fingerprint": null,
                "navidrome_song_id": null,
                "navidrome_album_id": null,
                "navidrome_artist_id": null,
                "resonance_import_key": "fetcher:local_asset:playlist_track:1",
                "mapping_confidence": "exact",
                "mapping_status": "active",
                "updated_at": "2026-05-02T00:00:00.000Z",
                "notes_json": "{}"
              }
            ]
            """,
            named: "identity-bridge.json",
            in: directory
        )

        try write(
            """
            [
              {
                "manifest_key": "manifest:alpha-current",
                "manifest_kind": "resonance_source_fixture",
                "source_collection_key": "fetcher:source_collection:alpha",
                "resonance_scope": "source_current",
                "output_relative_path": "fixtures/source-current/alpha.json",
                "item_count": 1,
                "generated_at": "2026-05-02T00:00:00.000Z",
                "contract_hash": "sha256:fixture",
                "is_active": 1,
                "details_json": "{}"
              }
            ]
            """,
            named: "generated-view-manifests.json",
            in: directory
        )

        try write(
            """
            [
              {
                "health_key": "overall",
                "status": "ok",
                "summary": "Fixture ok",
                "last_checked_at": "2026-05-02T00:00:00.000Z",
                "details_json": "{}"
              }
            ]
            """,
            named: "contract-health.json",
            in: directory
        )

        return directory
    }

    private func writeDiagnosticsFixture() throws -> URL {
        let directory = try makeTempDir()

        try write(
            """
            {
              "export_schema_version": 1,
              "generated_at": "2026-05-02T00:00:00.000Z",
              "fetcher_contract_version": 1,
              "source_database": { "label": "diagnostics-fixture" },
              "row_counts": {
                "source-collections.json": 2,
                "source-items.json": 0,
                "source-evidence.json": 0,
                "candidate-imports.json": 5,
                "identity-bridge.json": 4,
                "generated-view-manifests.json": 5,
                "contract-health.json": 5
              },
              "content_hash": "sha256:diagnostics-fixture",
              "files": [],
              "redacted_paths": false
            }
            """,
            named: "contract-version.json",
            in: directory
        )

        try write(
            """
            [
              {
                "source_collection_key": "fetcher:source_collection:alpha",
                "source_kind": "apple_playlist",
                "domain": "apple_music",
                "display_name": "Alpha Source",
                "external_url": null,
                "external_id": "pl.alpha",
                "last_observed_at": null,
                "last_successful_observed_at": null,
                "stale_state": "fresh",
                "current_item_count": 0,
                "all_seen_item_count": 0,
                "removed_item_count": 0,
                "last_change_at": null,
                "source_specific_json": "{}",
                "contract_version": 1
              },
              {
                "source_collection_key": "fetcher:source_collection:beta",
                "source_kind": "apple_playlist",
                "domain": "apple_music",
                "display_name": "Beta Source",
                "external_url": null,
                "external_id": "pl.beta",
                "last_observed_at": null,
                "last_successful_observed_at": null,
                "stale_state": "fresh",
                "current_item_count": 0,
                "all_seen_item_count": 0,
                "removed_item_count": 0,
                "last_change_at": null,
                "source_specific_json": "{}",
                "contract_version": 1
              }
            ]
            """,
            named: "source-collections.json",
            in: directory
        )

        try write("[]", named: "source-items.json", in: directory)
        try write("[]", named: "source-evidence.json", in: directory)

        try write(
            """
            [
              {
                "candidate_key": "candidate:alpha-stageable",
                "source_collection_key": "fetcher:source_collection:alpha",
                "source_item_key": "source:alpha-stageable",
                "fetcher_canonical_item_key": "apple_song:alpha-stageable",
                "local_asset_key": "local:alpha-stageable",
                "navidrome_song_id": "nav-song-alpha",
                "title": "Alpha Stageable",
                "artist_display": "Alpha Artist",
                "album_or_release": "Alpha Album",
                "candidate_state": "downloaded",
                "recommended_resonance_route": "waiting_room",
                "recommendation_reason": "Ready.",
                "first_seen_at": null,
                "updated_at": null,
                "error_summary": null,
                "details_json": "{}"
              },
              {
                "candidate_key": "candidate:alpha-missing-id",
                "source_collection_key": "fetcher:source_collection:alpha",
                "source_item_key": "source:alpha-missing-id",
                "fetcher_canonical_item_key": "apple_song:alpha-missing-id",
                "local_asset_key": "local:alpha-missing-id",
                "navidrome_song_id": null,
                "title": "Alpha Missing ID",
                "artist_display": "Alpha Artist",
                "album_or_release": "Alpha Album",
                "candidate_state": "downloaded",
                "recommended_resonance_route": "waiting_room",
                "recommendation_reason": "Needs mapping.",
                "first_seen_at": null,
                "updated_at": null,
                "error_summary": null,
                "details_json": "{}"
              },
              {
                "candidate_key": "candidate:alpha-project",
                "source_collection_key": "fetcher:source_collection:alpha",
                "source_item_key": "source:alpha-project",
                "fetcher_canonical_item_key": "apple_song:alpha-project",
                "local_asset_key": "local:alpha-project",
                "navidrome_song_id": "nav-song-project",
                "title": "Alpha Project",
                "artist_display": "Alpha Artist",
                "album_or_release": "Alpha Album",
                "candidate_state": "downloaded",
                "recommended_resonance_route": "project_only",
                "recommendation_reason": "Project route.",
                "first_seen_at": null,
                "updated_at": null,
                "error_summary": null,
                "details_json": "{}"
              },
              {
                "candidate_key": "candidate:alpha-unknown",
                "source_collection_key": "fetcher:source_collection:alpha",
                "source_item_key": "source:alpha-unknown",
                "fetcher_canonical_item_key": "apple_song:alpha-unknown",
                "local_asset_key": "local:alpha-unknown",
                "navidrome_song_id": null,
                "title": "Alpha Unknown",
                "artist_display": "Alpha Artist",
                "album_or_release": "Alpha Album",
                "candidate_state": "downloaded",
                "recommended_resonance_route": "new_route",
                "recommendation_reason": "Unknown route.",
                "first_seen_at": null,
                "updated_at": null,
                "error_summary": null,
                "details_json": "{}"
              },
              {
                "candidate_key": "candidate:beta-stageable",
                "source_collection_key": "fetcher:source_collection:beta",
                "source_item_key": "source:beta-stageable",
                "fetcher_canonical_item_key": "apple_song:beta-stageable",
                "local_asset_key": "local:beta-stageable",
                "navidrome_song_id": "nav-song-beta",
                "title": "Beta Stageable",
                "artist_display": "Beta Artist",
                "album_or_release": "Beta Album",
                "candidate_state": "downloaded",
                "recommended_resonance_route": "waiting_room",
                "recommendation_reason": "Ready.",
                "first_seen_at": null,
                "updated_at": null,
                "error_summary": null,
                "details_json": "{}"
              }
            ]
            """,
            named: "candidate-imports.json",
            in: directory
        )

        try write(
            """
            [
              {
                "bridge_key": "bridge:alpha-two",
                "source_item_key": "source:alpha-two",
                "source_collection_key": "fetcher:source_collection:alpha",
                "fetcher_canonical_item_key": "apple_song:alpha-two",
                "download_job_key": null,
                "local_asset_key": "local:alpha-two",
                "local_file_relative_path": null,
                "content_fingerprint": null,
                "navidrome_song_id": "nav-song-alpha-two",
                "navidrome_album_id": null,
                "navidrome_artist_id": null,
                "resonance_import_key": "local:alpha-two",
                "mapping_confidence": "exact",
                "mapping_status": "active",
                "updated_at": null,
                "notes_json": "{}"
              },
              {
                "bridge_key": "bridge:beta-one",
                "source_item_key": "source:beta-one",
                "source_collection_key": "fetcher:source_collection:beta",
                "fetcher_canonical_item_key": "apple_song:beta-one",
                "download_job_key": null,
                "local_asset_key": "local:beta-one",
                "local_file_relative_path": null,
                "content_fingerprint": null,
                "navidrome_song_id": "nav-song-beta-one",
                "navidrome_album_id": null,
                "navidrome_artist_id": null,
                "resonance_import_key": "local:beta-one",
                "mapping_confidence": "exact",
                "mapping_status": "active",
                "updated_at": null,
                "notes_json": "{}"
              },
              {
                "bridge_key": "bridge:alpha-one",
                "source_item_key": "source:alpha-one",
                "source_collection_key": "fetcher:source_collection:alpha",
                "fetcher_canonical_item_key": "apple_song:alpha-one",
                "download_job_key": null,
                "local_asset_key": "local:alpha-one",
                "local_file_relative_path": null,
                "content_fingerprint": null,
                "navidrome_song_id": "nav-song-alpha-one",
                "navidrome_album_id": null,
                "navidrome_artist_id": null,
                "resonance_import_key": "local:alpha-one",
                "mapping_confidence": "exact",
                "mapping_status": "active",
                "updated_at": null,
                "notes_json": "{}"
              },
              {
                "bridge_key": "bridge:nil-source",
                "source_item_key": "source:nil-source",
                "source_collection_key": null,
                "fetcher_canonical_item_key": "apple_song:nil-source",
                "download_job_key": null,
                "local_asset_key": "local:nil-source",
                "local_file_relative_path": null,
                "content_fingerprint": null,
                "navidrome_song_id": null,
                "navidrome_album_id": null,
                "navidrome_artist_id": null,
                "resonance_import_key": "local:nil-source",
                "mapping_confidence": "unknown",
                "mapping_status": "unknown",
                "updated_at": null,
                "notes_json": "{}"
              }
            ]
            """,
            named: "identity-bridge.json",
            in: directory
        )

        try write(
            """
            [
              {
                "manifest_key": "manifest:alpha-active",
                "manifest_kind": "resonance_source_fixture",
                "source_collection_key": "fetcher:source_collection:alpha",
                "resonance_scope": "source_current",
                "output_relative_path": "fixtures/alpha-current.json",
                "item_count": 1,
                "generated_at": null,
                "contract_hash": "sha256:diagnostics-fixture",
                "is_active": 1,
                "details_json": "{}"
              },
              {
                "manifest_key": null,
                "manifest_kind": "resonance_source_fixture",
                "source_collection_key": "fetcher:source_collection:alpha",
                "resonance_scope": "source_removed",
                "output_relative_path": "fixtures/alpha-removed.json",
                "item_count": 0,
                "generated_at": null,
                "contract_hash": "sha256:diagnostics-fixture",
                "is_active": 0,
                "details_json": "{}"
              },
              {
                "manifest_key": "manifest:alpha-unknown",
                "manifest_kind": "resonance_source_fixture",
                "source_collection_key": "fetcher:source_collection:alpha",
                "resonance_scope": "source_unknown",
                "output_relative_path": "fixtures/alpha-unknown.json",
                "item_count": 0,
                "generated_at": null,
                "contract_hash": "sha256:diagnostics-fixture",
                "is_active": 2,
                "details_json": "{}"
              },
              {
                "manifest_key": "manifest:beta-active",
                "manifest_kind": "resonance_source_fixture",
                "source_collection_key": "fetcher:source_collection:beta",
                "resonance_scope": "source_current",
                "output_relative_path": "fixtures/beta-current.json",
                "item_count": 1,
                "generated_at": null,
                "contract_hash": "sha256:diagnostics-fixture",
                "is_active": 1,
                "details_json": "{}"
              },
              {
                "manifest_key": "manifest:nil-source",
                "manifest_kind": "resonance_source_fixture",
                "source_collection_key": null,
                "resonance_scope": "source_current",
                "output_relative_path": "fixtures/nil-source.json",
                "item_count": 1,
                "generated_at": null,
                "contract_hash": "sha256:diagnostics-fixture",
                "is_active": 1,
                "details_json": "{}"
              }
            ]
            """,
            named: "generated-view-manifests.json",
            in: directory
        )

        try write(
            """
            [
              {
                "health_key": "health:alpha-warn",
                "source_collection_key": "fetcher:source_collection:alpha",
                "status": "warn",
                "summary": "Alpha warning",
                "last_checked_at": null,
                "details_json": "{}"
              },
              {
                "health_key": "health:alpha-mystery",
                "source_collection_key": "fetcher:source_collection:alpha",
                "status": "mystery",
                "summary": "Alpha unknown status",
                "last_checked_at": null,
                "details_json": "{}"
              },
              {
                "health_key": "health:alpha-ok",
                "source_collection_key": "fetcher:source_collection:alpha",
                "status": "ok",
                "summary": "Alpha ok",
                "last_checked_at": null,
                "details_json": "{}"
              },
              {
                "health_key": "health:beta-warn",
                "source_collection_key": "fetcher:source_collection:beta",
                "status": "warn",
                "summary": "Beta warning",
                "last_checked_at": null,
                "details_json": "{}"
              },
              {
                "health_key": "health:nil-source",
                "source_collection_key": null,
                "status": "warn",
                "summary": "Global warning",
                "last_checked_at": null,
                "details_json": "{}"
              }
            ]
            """,
            named: "contract-health.json",
            in: directory
        )

        return directory
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-fetcher-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    private func write(_ contents: String, named filename: String, in directory: URL) throws {
        try contents.write(to: directory.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }

}
