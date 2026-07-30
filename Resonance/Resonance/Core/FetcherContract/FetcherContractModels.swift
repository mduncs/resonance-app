import Foundation

struct FetcherContractSnapshot: Sendable {
    let metadata: FetcherContractMetadata
    let sourceCollections: [FetcherSourceCollection]
    let sourceItems: [FetcherSourceItem]
    let sourceEvidence: [FetcherSourceEvidence]
    let candidateImports: [FetcherCandidateImport]
    let identityBridge: [FetcherIdentityBridgeRow]
    let generatedViewManifests: [FetcherGeneratedViewManifest]
    let contractHealth: [FetcherContractHealthRow]
    /// Optional provenance rows from the preferred v2 or legacy v1 export.
    /// Empty when an older Fetcher export omits both additive files.
    let sourceAttribution: [FetcherSourceAttribution]

    // MARK: Precomputed lookup indexes
    //
    // A live Fetcher export runs ~28k rows per view. Every accessor below used
    // to linear-scan (and re-sort) the full arrays, and SwiftUI calls them from
    // `body` once per visible row — so the page cost was quadratic in export
    // size. The indexes are built once here, on whatever thread decodes the
    // snapshot, and every accessor is a dictionary lookup afterwards.

    let sourceCollectionsByKey: [String: FetcherSourceCollection]
    let sourceItemsByKey: [String: FetcherSourceItem]
    let itemsByCollectionKey: [String: [FetcherSourceItem]]
    /// Buckets pre-sorted by `evidenceKey`.
    let evidenceBySourceItemKey: [String: [FetcherSourceEvidence]]
    /// Buckets pre-sorted by `bridgeKey`.
    let bridgeRowsBySourceItemKey: [String: [FetcherIdentityBridgeRow]]
    /// Keyed on the trimmed, non-empty Navidrome song id; pre-sorted by `bridgeKey`.
    let bridgeRowsByNavidromeSongId: [String: [FetcherIdentityBridgeRow]]
    /// Buckets pre-sorted by title (case-insensitive), matching `candidates(for:)`.
    let candidatesByCollectionKey: [String: [FetcherCandidateImport]]
    /// Buckets pre-sorted by `candidateKey`.
    let candidatesBySourceItemKey: [String: [FetcherCandidateImport]]
    /// Keyed on the trimmed, non-empty Navidrome song id; pre-sorted by `candidateKey`.
    let candidatesByNavidromeSongId: [String: [FetcherCandidateImport]]
    let warningHealthRows: [FetcherContractHealthRow]
    let diagnosticsSummariesBySourceCollectionKey: [String: FetcherSourceContractDiagnosticsSummary]

    init(
        metadata: FetcherContractMetadata,
        sourceCollections: [FetcherSourceCollection],
        sourceItems: [FetcherSourceItem],
        sourceEvidence: [FetcherSourceEvidence],
        candidateImports: [FetcherCandidateImport],
        identityBridge: [FetcherIdentityBridgeRow],
        generatedViewManifests: [FetcherGeneratedViewManifest],
        contractHealth: [FetcherContractHealthRow],
        sourceAttribution: [FetcherSourceAttribution] = []
    ) {
        self.metadata = metadata
        self.sourceCollections = sourceCollections
        self.sourceItems = sourceItems
        self.sourceEvidence = sourceEvidence
        self.candidateImports = candidateImports
        self.identityBridge = identityBridge
        self.generatedViewManifests = generatedViewManifests
        self.contractHealth = contractHealth
        self.sourceAttribution = sourceAttribution

        self.sourceCollectionsByKey = Dictionary(
            sourceCollections.map { ($0.sourceCollectionKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.sourceItemsByKey = Dictionary(
            sourceItems.map { ($0.sourceItemKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.itemsByCollectionKey = Dictionary(grouping: sourceItems, by: \.sourceCollectionKey)
        self.evidenceBySourceItemKey = Self.grouped(
            sourceEvidence,
            by: { $0.sourceItemKey },
            sortedBy: { $0.evidenceKey < $1.evidenceKey }
        )
        self.bridgeRowsBySourceItemKey = Self.grouped(
            identityBridge,
            by: { $0.sourceItemKey },
            sortedBy: { $0.bridgeKey < $1.bridgeKey }
        )
        self.bridgeRowsByNavidromeSongId = Self.grouped(
            identityBridge,
            by: { Self.normalizedNonEmpty($0.navidromeSongId) },
            sortedBy: { $0.bridgeKey < $1.bridgeKey }
        )
        self.candidatesByCollectionKey = Self.grouped(
            candidateImports,
            by: { $0.sourceCollectionKey },
            sortedBy: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        )
        self.candidatesBySourceItemKey = Self.grouped(
            candidateImports,
            by: { $0.sourceItemKey },
            sortedBy: { $0.candidateKey < $1.candidateKey }
        )
        self.candidatesByNavidromeSongId = Self.grouped(
            candidateImports,
            by: { Self.normalizedNonEmpty($0.navidromeSongId) },
            sortedBy: { $0.candidateKey < $1.candidateKey }
        )

        let warningHealthRows = contractHealth.filter { $0.isWarning }
        self.warningHealthRows = warningHealthRows
        self.diagnosticsSummariesBySourceCollectionKey = Self.buildDiagnosticsSummaries(
            sourceCollections: sourceCollections,
            identityBridge: identityBridge,
            generatedViewManifests: generatedViewManifests,
            warningHealthRows: warningHealthRows,
            candidateImports: candidateImports
        )
    }

    private static func grouped<Element, Key: Hashable>(
        _ elements: [Element],
        by key: (Element) -> Key?,
        sortedBy areInIncreasingOrder: (Element, Element) -> Bool
    ) -> [Key: [Element]] {
        var buckets: [Key: [Element]] = [:]
        for element in elements {
            guard let elementKey = key(element) else { continue }
            buckets[elementKey, default: []].append(element)
        }
        return buckets.mapValues { $0.sorted(by: areInIncreasingOrder) }
    }

    func items(for collectionKey: String, mode: FetcherSourceItemMode) -> [FetcherSourceItem] {
        (itemsByCollectionKey[collectionKey] ?? [])
            .filter { item in
                switch mode {
                case .current:
                    return item.isCurrent
                case .allSeen:
                    return true
                case .removed:
                    return !item.isCurrent || item.removedAt != nil
                }
            }
            .sorted { lhs, rhs in
                switch (lhs.position, rhs.position) {
                case let (lhsPosition?, rhsPosition?) where lhsPosition != rhsPosition:
                    return lhsPosition < rhsPosition
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }
    }

    func candidates(for collectionKey: String) -> [FetcherCandidateImport] {
        candidatesByCollectionKey[collectionKey] ?? []
    }

    func evidence(for sourceItemKey: String) -> [FetcherSourceEvidence] {
        evidenceBySourceItemKey[sourceItemKey] ?? []
    }

    func songSourceEvidence(forNavidromeSongId navidromeSongId: String) -> [FetcherSongSourceEvidence] {
        guard let targetSongId = Self.normalizedNonEmpty(navidromeSongId) else { return [] }

        var seenSourceItemKeys = Set<String>()
        var matchedSourceItemKeys: [String] = []

        func appendSourceItemKey(_ sourceItemKey: String?) {
            guard let sourceItemKey = Self.normalizedNonEmpty(sourceItemKey),
                  seenSourceItemKeys.insert(sourceItemKey).inserted else { return }
            matchedSourceItemKeys.append(sourceItemKey)
        }

        for bridgeRow in bridgeRowsByNavidromeSongId[targetSongId] ?? [] {
            appendSourceItemKey(bridgeRow.sourceItemKey)
        }

        for candidate in candidatesByNavidromeSongId[targetSongId] ?? [] {
            appendSourceItemKey(candidate.sourceItemKey)
        }

        return matchedSourceItemKeys
            .compactMap { sourceItemKey -> FetcherSongSourceEvidence? in
                guard let sourceItem = sourceItemsByKey[sourceItemKey] else { return nil }
                return FetcherSongSourceEvidence(
                    sourceCollection: sourceCollectionsByKey[sourceItem.sourceCollectionKey],
                    sourceItem: sourceItem,
                    evidenceRows: evidence(for: sourceItemKey),
                    identityRows: identityRows(forSourceItem: sourceItemKey),
                    candidates: candidates(forSourceItem: sourceItemKey)
                )
            }
            .sorted(by: songSourceEvidencePrecedes)
    }

    func navidromeSongIds(forSourceItem sourceItemKey: String) -> [String] {
        uniqueNonEmptyValues(
            from: (bridgeRowsBySourceItemKey[sourceItemKey] ?? []).map(\.navidromeSongId)
                + (candidatesBySourceItemKey[sourceItemKey] ?? []).map(\.navidromeSongId)
        )
    }

    func mappedNavidromeSongIds(for collectionKey: String, mode: FetcherSourceItemMode) -> [String] {
        mappedNavidromeSongIds(for: items(for: collectionKey, mode: mode))
    }

    func mappedNavidromeSongIds(for items: [FetcherSourceItem]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for item in items {
            for songId in navidromeSongIds(forSourceItem: item.sourceItemKey) where seen.insert(songId).inserted {
                result.append(songId)
            }
        }

        return result
    }

    func diagnosticsSummary(for collectionKey: String) -> FetcherSourceContractDiagnosticsSummary {
        diagnosticsSummariesBySourceCollectionKey[collectionKey] ?? FetcherSourceContractDiagnosticsSummary.empty(collectionKey: collectionKey)
    }

    private static func buildDiagnosticsSummaries(
        sourceCollections: [FetcherSourceCollection],
        identityBridge: [FetcherIdentityBridgeRow],
        generatedViewManifests: [FetcherGeneratedViewManifest],
        warningHealthRows: [FetcherContractHealthRow],
        candidateImports: [FetcherCandidateImport]
    ) -> [String: FetcherSourceContractDiagnosticsSummary] {
        var builders = Dictionary(
            sourceCollections.map {
                ($0.sourceCollectionKey, FetcherSourceContractDiagnosticsBuilder(sourceCollectionKey: $0.sourceCollectionKey))
            },
            uniquingKeysWith: { first, _ in first }
        )

        for bridgeRow in identityBridge {
            guard let sourceCollectionKey = bridgeRow.sourceCollectionKey else { continue }
            builders[sourceCollectionKey, default: FetcherSourceContractDiagnosticsBuilder(sourceCollectionKey: sourceCollectionKey)]
                .identityBridgeRows.append(bridgeRow)
        }

        for manifest in generatedViewManifests {
            guard let sourceCollectionKey = manifest.sourceCollectionKey else { continue }
            var builder = builders[sourceCollectionKey, default: FetcherSourceContractDiagnosticsBuilder(sourceCollectionKey: sourceCollectionKey)]
            builder.generatedViewManifests.append(manifest)
            if manifest.activeState == .active {
                builder.activeGeneratedViewManifests.append(manifest)
            } else {
                builder.inactiveGeneratedViewManifests.append(manifest)
            }
            builders[sourceCollectionKey] = builder
        }

        for healthRow in warningHealthRows {
            guard let sourceCollectionKey = healthRow.sourceCollectionKey else { continue }
            builders[sourceCollectionKey, default: FetcherSourceContractDiagnosticsBuilder(sourceCollectionKey: sourceCollectionKey)]
                .warningHealthRows.append(healthRow)
        }

        for candidate in candidateImports {
            guard let sourceCollectionKey = candidate.sourceCollectionKey else { continue }
            builders[sourceCollectionKey, default: FetcherSourceContractDiagnosticsBuilder(sourceCollectionKey: sourceCollectionKey)]
                .candidateStageability.add(candidate)
        }

        return builders.mapValues { $0.summary }
    }

    private func uniqueNonEmptyValues(from values: [String?]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for rawValue in values {
            guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  seen.insert(value).inserted else { continue }
            result.append(value)
        }

        return result
    }

    private func identityRows(forSourceItem sourceItemKey: String) -> [FetcherIdentityBridgeRow] {
        bridgeRowsBySourceItemKey[sourceItemKey] ?? []
    }

    private func candidates(forSourceItem sourceItemKey: String) -> [FetcherCandidateImport] {
        candidatesBySourceItemKey[sourceItemKey] ?? []
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func songSourceEvidencePrecedes(_ lhs: FetcherSongSourceEvidence, _ rhs: FetcherSongSourceEvidence) -> Bool {
        if lhs.sourceItem.isCurrent != rhs.sourceItem.isCurrent {
            return lhs.sourceItem.isCurrent
        }

        let lhsCollectionName = lhs.sourceCollection?.displayName ?? lhs.sourceItem.sourceCollectionKey
        let rhsCollectionName = rhs.sourceCollection?.displayName ?? rhs.sourceItem.sourceCollectionKey
        let collectionComparison = lhsCollectionName.localizedCaseInsensitiveCompare(rhsCollectionName)
        if collectionComparison != .orderedSame {
            return collectionComparison == .orderedAscending
        }

        switch (lhs.sourceItem.position, rhs.sourceItem.position) {
        case let (lhsPosition?, rhsPosition?) where lhsPosition != rhsPosition:
            return lhsPosition < rhsPosition
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.sourceItem.title.localizedCaseInsensitiveCompare(rhs.sourceItem.title) == .orderedAscending
        }
    }
}

struct FetcherSongSourceEvidence: Identifiable, Hashable, Sendable {
    let sourceCollection: FetcherSourceCollection?
    let sourceItem: FetcherSourceItem
    let evidenceRows: [FetcherSourceEvidence]
    let identityRows: [FetcherIdentityBridgeRow]
    let candidates: [FetcherCandidateImport]

    var id: String { sourceItem.sourceItemKey }

    var collectionDisplayName: String {
        sourceCollection?.displayName ?? sourceItem.sourceCollectionKey
    }

    var sourceKindDisplayName: String? {
        guard let sourceKind = sourceCollection?.sourceKind else { return nil }
        return sourceKind.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var mappingSummary: String {
        if let identityRow = identityRows.first {
            return "\(identityRow.mappingStatus.fetcherTitleized) / \(identityRow.mappingConfidence.fetcherTitleized)"
        }

        if let candidate = candidates.first {
            return "Candidate: \(candidate.candidateState.fetcherTitleized)"
        }

        return "Source observation"
    }
}

private extension String {
    var fetcherTitleized: String {
        replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct FetcherSourceContractDiagnosticsSummary: Equatable, Sendable {
    let sourceCollectionKey: String
    let identityBridgeRows: [FetcherIdentityBridgeRow]
    let generatedViewManifests: [FetcherGeneratedViewManifest]
    let activeGeneratedViewManifests: [FetcherGeneratedViewManifest]
    let inactiveGeneratedViewManifests: [FetcherGeneratedViewManifest]
    let warningHealthRows: [FetcherContractHealthRow]
    let candidateStageability: FetcherCandidateStageabilitySummary

    var generatedViewManifestCount: Int {
        activeGeneratedViewManifests.count + inactiveGeneratedViewManifests.count
    }

    static func empty(collectionKey: String) -> FetcherSourceContractDiagnosticsSummary {
        FetcherSourceContractDiagnosticsSummary(
            sourceCollectionKey: collectionKey,
            identityBridgeRows: [],
            generatedViewManifests: [],
            activeGeneratedViewManifests: [],
            inactiveGeneratedViewManifests: [],
            warningHealthRows: [],
            candidateStageability: .empty
        )
    }
}

struct FetcherCandidateStageabilitySummary: Equatable, Sendable {
    let totalCount: Int
    let stageableCount: Int
    let missingNavidromeIDCount: Int
    let unsupportedRouteCount: Int

    static let empty = FetcherCandidateStageabilitySummary(
        totalCount: 0,
        stageableCount: 0,
        missingNavidromeIDCount: 0,
        unsupportedRouteCount: 0
    )
}

private struct FetcherCandidateStageabilityBuilder {
    var totalCount = 0
    var stageableCount = 0
    var missingNavidromeIDCount = 0
    var unsupportedRouteCount = 0

    mutating func add(_ candidate: FetcherCandidateImport) {
        totalCount += 1

        guard FetcherCandidateRoute(rawContractValue: candidate.recommendedResonanceRoute) == .waitingRoom else {
            unsupportedRouteCount += 1
            return
        }

        if candidate.hasNavidromeSongId {
            stageableCount += 1
        } else {
            missingNavidromeIDCount += 1
        }
    }

    var summary: FetcherCandidateStageabilitySummary {
        FetcherCandidateStageabilitySummary(
            totalCount: totalCount,
            stageableCount: stageableCount,
            missingNavidromeIDCount: missingNavidromeIDCount,
            unsupportedRouteCount: unsupportedRouteCount
        )
    }
}

private struct FetcherSourceContractDiagnosticsBuilder {
    let sourceCollectionKey: String
    var identityBridgeRows: [FetcherIdentityBridgeRow] = []
    var generatedViewManifests: [FetcherGeneratedViewManifest] = []
    var activeGeneratedViewManifests: [FetcherGeneratedViewManifest] = []
    var inactiveGeneratedViewManifests: [FetcherGeneratedViewManifest] = []
    var warningHealthRows: [FetcherContractHealthRow] = []
    var candidateStageability = FetcherCandidateStageabilityBuilder()

    var summary: FetcherSourceContractDiagnosticsSummary {
        FetcherSourceContractDiagnosticsSummary(
            sourceCollectionKey: sourceCollectionKey,
            identityBridgeRows: identityBridgeRows.sorted { $0.bridgeKey < $1.bridgeKey },
            generatedViewManifests: generatedViewManifests.sortedByManifestDisplayKey,
            activeGeneratedViewManifests: activeGeneratedViewManifests.sortedByManifestDisplayKey,
            inactiveGeneratedViewManifests: inactiveGeneratedViewManifests.sortedByManifestDisplayKey,
            warningHealthRows: warningHealthRows.sorted { $0.healthKey < $1.healthKey },
            candidateStageability: candidateStageability.summary
        )
    }
}

private extension Array where Element == FetcherGeneratedViewManifest {
    var sortedByManifestDisplayKey: [FetcherGeneratedViewManifest] {
        sorted { lhs, rhs in
            lhs.displayKey < rhs.displayKey
        }
    }
}

enum FetcherSourceItemMode: String, CaseIterable, Identifiable, Sendable {
    case current = "Current"
    case allSeen = "All Seen"
    case removed = "Removed"

    var id: String { rawValue }
}

struct FetcherContractMetadata: Codable, Sendable {
    let exportSchemaVersion: Int
    let generatedAt: String
    let fetcherContractVersion: Int
    let sourceDatabase: FetcherContractSourceDatabase
    let rowCounts: [String: Int]
    let contentHash: String
    let files: [FetcherContractFileSummary]
    let redactedPaths: Bool

    /// Identity of one export generation. Changes whenever Fetcher re-exports
    /// with different content, so it can gate work that only needs to happen
    /// once per export (the GRDB attribution upsert and project automake).
    var exportIdentityMarker: String {
        "v\(exportSchemaVersion).c\(fetcherContractVersion)|\(generatedAt)|\(contentHash)"
    }

    enum CodingKeys: String, CodingKey {
        case exportSchemaVersion = "export_schema_version"
        case generatedAt = "generated_at"
        case fetcherContractVersion = "fetcher_contract_version"
        case sourceDatabase = "source_database"
        case rowCounts = "row_counts"
        case contentHash = "content_hash"
        case files
        case redactedPaths = "redacted_paths"
    }
}

struct FetcherContractSourceDatabase: Codable, Sendable {
    let label: String
}

struct FetcherContractFileSummary: Codable, Identifiable, Sendable {
    let path: String
    let view: String
    let rowCount: Int
    let sortKeys: [String]
    let contentHash: String

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path
        case view
        case rowCount = "row_count"
        case sortKeys = "sort_keys"
        case contentHash = "content_hash"
    }
}

struct FetcherSourceCollection: Codable, Identifiable, Hashable, Sendable {
    let sourceCollectionKey: String
    let sourceKind: String
    let domain: String
    let displayName: String
    let externalUrl: String?
    let externalId: String?
    let lastObservedAt: String?
    let lastSuccessfulObservedAt: String?
    let staleState: String
    let currentItemCount: Int
    let allSeenItemCount: Int
    let removedItemCount: Int
    let lastChangeAt: String?
    let sourceSpecificJson: String?
    let contractVersion: Int

    var id: String { sourceCollectionKey }

    enum CodingKeys: String, CodingKey {
        case sourceCollectionKey = "source_collection_key"
        case sourceKind = "source_kind"
        case domain
        case displayName = "display_name"
        case externalUrl = "external_url"
        case externalId = "external_id"
        case lastObservedAt = "last_observed_at"
        case lastSuccessfulObservedAt = "last_successful_observed_at"
        case staleState = "stale_state"
        case currentItemCount = "current_item_count"
        case allSeenItemCount = "all_seen_item_count"
        case removedItemCount = "removed_item_count"
        case lastChangeAt = "last_change_at"
        case sourceSpecificJson = "source_specific_json"
        case contractVersion = "contract_version"
    }
}

struct FetcherSourceItem: Codable, Identifiable, Hashable, Sendable {
    let sourceCollectionKey: String
    let sourceItemKey: String
    let sourceItemKind: String
    let title: String
    let artistDisplay: String?
    let albumOrRelease: String?
    let durationMs: Int?
    let externalUrl: String?
    let externalId: String?
    let position: Int?
    let isCurrentValue: Int
    let firstSeenAt: String?
    let lastSeenAt: String?
    let removedAt: String?
    let latestObservationKey: String?
    let membershipFactKey: String?
    let metadataJson: String?

    var id: String { sourceItemKey }
    var isCurrent: Bool { isCurrentValue != 0 }

    enum CodingKeys: String, CodingKey {
        case sourceCollectionKey = "source_collection_key"
        case sourceItemKey = "source_item_key"
        case sourceItemKind = "source_item_kind"
        case title
        case artistDisplay = "artist_display"
        case albumOrRelease = "album_or_release"
        case durationMs = "duration_ms"
        case externalUrl = "external_url"
        case externalId = "external_id"
        case position
        case isCurrentValue = "is_current"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case removedAt = "removed_at"
        case latestObservationKey = "latest_observation_key"
        case membershipFactKey = "membership_fact_key"
        case metadataJson = "metadata_json"
    }
}

struct FetcherSourceEvidence: Codable, Identifiable, Hashable, Sendable {
    let evidenceKey: String
    let sourceCollectionKey: String
    let sourceItemKey: String
    let localAssetKey: String?
    let fetcherCanonicalItemKey: String?
    let evidenceKind: String
    let evidenceLabel: String
    let firstSeenAt: String?
    let lastSeenAt: String?
    let removedAt: String?
    let position: Int?
    let confidence: String
    let detailsJson: String?

    var id: String { evidenceKey }

    enum CodingKeys: String, CodingKey {
        case evidenceKey = "evidence_key"
        case sourceCollectionKey = "source_collection_key"
        case sourceItemKey = "source_item_key"
        case localAssetKey = "local_asset_key"
        case fetcherCanonicalItemKey = "fetcher_canonical_item_key"
        case evidenceKind = "evidence_kind"
        case evidenceLabel = "evidence_label"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case removedAt = "removed_at"
        case position
        case confidence
        case detailsJson = "details_json"
    }
}

struct FetcherCandidateImport: Codable, Identifiable, Hashable, Sendable {
    let candidateKey: String
    let sourceCollectionKey: String?
    let sourceItemKey: String?
    let fetcherCanonicalItemKey: String?
    let localAssetKey: String?
    let navidromeSongId: String?
    let title: String
    let artistDisplay: String?
    let albumOrRelease: String?
    let candidateState: String
    let recommendedResonanceRoute: String
    let recommendationReason: String?
    let firstSeenAt: String?
    let updatedAt: String?
    let errorSummary: String?
    let detailsJson: String?

    var id: String { candidateKey }
    var hasNavidromeSongId: Bool {
        guard let navidromeSongId else { return false }
        return !navidromeSongId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case candidateKey = "candidate_key"
        case sourceCollectionKey = "source_collection_key"
        case sourceItemKey = "source_item_key"
        case fetcherCanonicalItemKey = "fetcher_canonical_item_key"
        case localAssetKey = "local_asset_key"
        case navidromeSongId = "navidrome_song_id"
        case title
        case artistDisplay = "artist_display"
        case albumOrRelease = "album_or_release"
        case candidateState = "candidate_state"
        case recommendedResonanceRoute = "recommended_resonance_route"
        case recommendationReason = "recommendation_reason"
        case firstSeenAt = "first_seen_at"
        case updatedAt = "updated_at"
        case errorSummary = "error_summary"
        case detailsJson = "details_json"
    }
}

struct FetcherIdentityBridgeRow: Codable, Identifiable, Hashable, Sendable {
    let bridgeKey: String
    let sourceItemKey: String?
    let sourceCollectionKey: String?
    let fetcherCanonicalItemKey: String?
    let downloadJobKey: String?
    let localAssetKey: String?
    let localFileRelativePath: String?
    let contentFingerprint: String?
    let navidromeSongId: String?
    let navidromeAlbumId: String?
    let navidromeArtistId: String?
    let resonanceImportKey: String
    let mappingConfidence: String
    let mappingStatus: String
    let updatedAt: String?
    let notesJson: String?

    var id: String { bridgeKey }

    enum CodingKeys: String, CodingKey {
        case bridgeKey = "bridge_key"
        case sourceItemKey = "source_item_key"
        case sourceCollectionKey = "source_collection_key"
        case fetcherCanonicalItemKey = "fetcher_canonical_item_key"
        case downloadJobKey = "download_job_key"
        case localAssetKey = "local_asset_key"
        case localFileRelativePath = "local_file_relative_path"
        case contentFingerprint = "content_fingerprint"
        case navidromeSongId = "navidrome_song_id"
        case navidromeAlbumId = "navidrome_album_id"
        case navidromeArtistId = "navidrome_artist_id"
        case resonanceImportKey = "resonance_import_key"
        case mappingConfidence = "mapping_confidence"
        case mappingStatus = "mapping_status"
        case updatedAt = "updated_at"
        case notesJson = "notes_json"
    }
}

struct FetcherGeneratedViewManifest: Codable, Identifiable, Hashable, Sendable {
    let manifestKey: String?
    let manifestKind: String?
    let sourceCollectionKey: String?
    let resonanceScope: String?
    let outputRelativePath: String?
    let itemCount: Int?
    let generatedAt: String?
    let contractHash: String?
    let isActiveValue: Int?
    let detailsJson: String?

    var id: String { manifestKey ?? "empty-generated-view-manifest" }
    var isActive: Bool { activeState == .active }
    var displayKey: String { manifestKey ?? outputRelativePath ?? resonanceScope ?? "missing-manifest-key" }
    var activeState: FetcherGeneratedViewManifestActiveState {
        guard let isActiveValue else { return .unknown(nil) }
        switch isActiveValue {
        case 0:
            return .inactive
        case 1:
            return .active
        default:
            return .unknown(isActiveValue)
        }
    }
    var activeStateLabel: String {
        switch activeState {
        case .active:
            return "Active"
        case .inactive:
            return "Inactive"
        case let .unknown(value?):
            return "Unknown (\(value))"
        case .unknown(nil):
            return "Unknown"
        }
    }

    enum CodingKeys: String, CodingKey {
        case manifestKey = "manifest_key"
        case manifestKind = "manifest_kind"
        case sourceCollectionKey = "source_collection_key"
        case resonanceScope = "resonance_scope"
        case outputRelativePath = "output_relative_path"
        case itemCount = "item_count"
        case generatedAt = "generated_at"
        case contractHash = "contract_hash"
        case isActiveValue = "is_active"
        case detailsJson = "details_json"
    }
}

enum FetcherGeneratedViewManifestActiveState: Equatable, Hashable, Sendable {
    case active
    case inactive
    case unknown(Int?)
}

struct FetcherContractHealthRow: Codable, Identifiable, Hashable, Sendable {
    let healthKey: String
    let sourceCollectionKey: String?
    let status: String
    let summary: String
    let lastCheckedAt: String?
    let detailsJson: String?

    var id: String { healthKey }
    var isWarning: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "ok"
    }

    enum CodingKeys: String, CodingKey {
        case healthKey = "health_key"
        case sourceCollectionKey = "source_collection_key"
        case status
        case summary
        case lastCheckedAt = "last_checked_at"
        case detailsJson = "details_json"
    }
}

/// One provenance row from the optional source-attribution export. Fetcher is
/// the authoritative writer; v2 resolves the exact Navidrome song identity.
/// Every v2 addition is optional so the v1 export remains decodable.
struct FetcherSourceAttribution: Codable, Identifiable, Hashable, Sendable {
    let attributionKey: String
    let localPath: String
    let sourceCollectionKey: String
    let sourceKind: String
    let sourceDisplayName: String
    let downloadSource: String?
    let queryContext: String?
    let acquiredAt: String?
    let contractVersion: Int
    let navidromeSongId: String?
    let resolutionMethod: String?
    let title: String?
    let artist: String?
    let album: String?
    let durationMs: Int?
    let isrc: String?

    var id: String { attributionKey }

    init(
        attributionKey: String,
        localPath: String,
        sourceCollectionKey: String,
        sourceKind: String,
        sourceDisplayName: String,
        downloadSource: String?,
        queryContext: String?,
        acquiredAt: String?,
        contractVersion: Int,
        navidromeSongId: String? = nil,
        resolutionMethod: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        durationMs: Int? = nil,
        isrc: String? = nil
    ) {
        self.attributionKey = attributionKey
        self.localPath = localPath
        self.sourceCollectionKey = sourceCollectionKey
        self.sourceKind = sourceKind
        self.sourceDisplayName = sourceDisplayName
        self.downloadSource = downloadSource
        self.queryContext = queryContext
        self.acquiredAt = acquiredAt
        self.contractVersion = contractVersion
        self.navidromeSongId = navidromeSongId
        self.resolutionMethod = resolutionMethod
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.isrc = isrc
    }

    enum CodingKeys: String, CodingKey {
        case attributionKey = "attribution_key"
        case localPath = "local_path"
        case sourceCollectionKey = "source_collection_key"
        case sourceKind = "source_kind"
        case sourceDisplayName = "source_display_name"
        case downloadSource = "download_source"
        case queryContext = "query_context"
        case acquiredAt = "acquired_at"
        case contractVersion = "contract_version"
        case navidromeSongId = "navidrome_song_id"
        case resolutionMethod = "resolution_method"
        case title
        case artist
        case album
        case durationMs = "duration_ms"
        case isrc
    }
}
