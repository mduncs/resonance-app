import Foundation

/// Serializes durable Fetcher imports off the UI path.  It intentionally reads
/// only contract metadata, source collections, and attribution facts; the much
/// larger inspector export is never decoded by a library refresh.
actor FetcherProvenanceImporter {
    static let shared = FetcherProvenanceImporter()

    enum Outcome: Sendable, Equatable {
        case imported
        case current
        case awaitingSongCache(count: Int, bySourceKind: [String: Int])
        case unavailable
        case failed(String)
    }

    private struct JobKey: Hashable {
        let databasePath: String
        let serverId: String
        let directoryPath: String
    }

    private var activeJobs = Set<JobKey>()
    private var waitingJobs: [JobKey: [CheckedContinuation<Outcome, Never>]] = [:]

    func importIfNeeded(directory: URL, serverId: String, database: DatabaseManager) async -> Outcome {
        guard !Task.isCancelled else { return .failed("Fetcher import cancelled") }
        let key = JobKey(
            databasePath: URL(fileURLWithPath: database.dbPath).standardizedFileURL.path,
            serverId: serverId,
            directoryPath: directory.standardizedFileURL.path
        )
        if activeJobs.contains(key) {
            return await withCheckedContinuation { continuation in
                waitingJobs[key, default: []].append(continuation)
            }
        }
        activeJobs.insert(key)
        let outcome = await performImport(directory: directory, serverId: serverId, database: database)
        let waiters = waitingJobs.removeValue(forKey: key) ?? []
        activeJobs.remove(key)
        waiters.forEach { $0.resume(returning: outcome) }
        return outcome
    }

    private func performImport(directory: URL, serverId: String, database: DatabaseManager) async -> Outcome {
        do {
            try Task.checkCancellation()
            let metadata = try await Task.detached(priority: .utility) {
                try FetcherContractLoader().loadMetadata(from: directory)
            }.value
            let marker = metadata.exportIdentityMarker
            let syncGeneration = try database.getSyncMetadata(key: "lastSync.\(serverId)")
            let cacheGeneration: String
            if let syncGeneration {
                cacheGeneration = syncGeneration
            } else {
                cacheGeneration = "songs:\(try database.cachedSongCount(serverId: serverId))"
            }
            let state = try database.fetcherImportState(serverId: serverId)
            let factCount = try database.fetcherAttributionFactCount(serverId: serverId)
            let linkCount = try database.fetcherAttributionLinkCount(serverId: serverId)
            let factsAreCurrent = state?.factsMarker == marker && state?.factsCount == factCount
                && state?.factsLinkCount == linkCount

            let collections: [FetcherSourceCollection]
            if factsAreCurrent {
                collections = try await Task.detached(priority: .utility) {
                    try FetcherContractLoader().loadValidatedSourceCollections(from: directory, metadata: metadata)
                }.value
            } else {
                let bundle = try await Task.detached(priority: .utility) {
                    try FetcherContractLoader().loadProvenanceBundle(from: directory)
                }.value
                guard !bundle.attribution.isEmpty else { return .unavailable }
                guard bundle.metadata.exportIdentityMarker == marker else {
                    try database.recordFetcherImport(serverId: serverId, marker: nil, error: "Fetcher export changed before import")
                    return .failed("Fetcher export changed before import")
                }
                try Task.checkCancellation()
                try database.upsertFetcherAttributionFacts(bundle.attribution, serverId: serverId)
                try Task.checkCancellation()
                let endMarker = try await Task.detached(priority: .utility) {
                    try FetcherContractLoader().loadMetadata(from: directory).exportIdentityMarker
                }.value
                guard marker == endMarker else {
                    try database.recordFetcherImport(serverId: serverId, marker: nil, error: "Fetcher export changed during import")
                    return .failed("Fetcher export changed during import")
                }
                let persistedCount = try database.fetcherAttributionFactCount(serverId: serverId)
                try database.recordFetcherFacts(serverId: serverId, marker: marker, count: persistedCount, error: nil)
                collections = bundle.collections
            }

            let refreshedState = try database.fetcherImportState(serverId: serverId)
            if factsAreCurrent, refreshedState?.projectionMarker == marker,
               refreshedState?.projectionCacheGeneration == cacheGeneration {
                if let count = refreshedState?.projectionUnresolvedCount, count > 0 {
                    return .awaitingSongCache(
                        count: count,
                        bySourceKind: refreshedState?.projectionUnresolvedKinds ?? [:]
                    )
                }
                return .current
            }
            let summary = try FetcherProjectAutomake.run(collections: collections, serverId: serverId, database: database)
            try Task.checkCancellation()
            if summary.unresolvedCollectionCount > 0 {
                let detail = Self.unresolvedDetail(
                    count: summary.unresolvedCollectionCount,
                    bySourceKind: summary.unresolvedCollectionCountsBySourceKind
                )
                try database.recordFetcherProjection(
                    serverId: serverId,
                    marker: marker,
                    cacheGeneration: cacheGeneration,
                    unresolvedCount: summary.unresolvedCollectionCount,
                    unresolvedKinds: summary.unresolvedCollectionCountsBySourceKind,
                    error: detail
                )
                return .awaitingSongCache(
                    count: summary.unresolvedCollectionCount,
                    bySourceKind: summary.unresolvedCollectionCountsBySourceKind
                )
            }
            try database.recordFetcherProjection(serverId: serverId, marker: marker, cacheGeneration: cacheGeneration, error: nil)
            return .imported
        } catch is CancellationError {
            return .failed("Fetcher import cancelled")
        } catch {
            try? database.recordFetcherImport(serverId: serverId, marker: nil, error: error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    private static func unresolvedDetail(count: Int, bySourceKind: [String: Int]) -> String {
        let kinds = bySourceKind
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        return kinds.isEmpty
            ? "Awaiting \(count) source mappings"
            : "Awaiting \(count) source mappings (\(kinds))"
    }
}
