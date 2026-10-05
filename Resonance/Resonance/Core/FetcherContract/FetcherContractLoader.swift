import CryptoKit
import Foundation

enum FetcherContractLoaderError: LocalizedError, Equatable {
    case missingFile(String)
    case unsupportedExportSchemaVersion(Int)
    case unsupportedContractVersion(Int)
    case unreadableDirectory(String)
    case inconsistentExport(String)

    var errorDescription: String? {
        switch self {
        case let .missingFile(filename):
            return "Missing Fetcher contract file: \(filename)"
        case let .unsupportedExportSchemaVersion(version):
            return "Unsupported Fetcher export schema version: \(version)"
        case let .unsupportedContractVersion(version):
            return "Unsupported Fetcher contract version: \(version)"
        case let .unreadableDirectory(path):
            return "Fetcher contract directory is not readable: \(path)"
        case let .inconsistentExport(message):
            return "Fetcher contract export failed integrity validation: \(message)"
        }
    }
}

enum FetcherGeneratedViewManifestPreviewStatus: Error, Equatable, Sendable {
    case available
    case noOutputPath
    case missingFile
    case rejectedAbsolutePath
    case rejectedPathTraversal
    case rejectedOutsideFixtureDirectory
    case unreadableFile

    var displayLabel: String {
        switch self {
        case .available:
            return "Preview available"
        case .noOutputPath:
            return "No output path"
        case .missingFile:
            return "Missing output file"
        case .rejectedAbsolutePath:
            return "Rejected absolute path"
        case .rejectedPathTraversal:
            return "Rejected path traversal"
        case .rejectedOutsideFixtureDirectory:
            return "Rejected outside fixture"
        case .unreadableFile:
            return "Unreadable output file"
        }
    }

    var detail: String {
        switch self {
        case .available:
            return "Output file was read from the local fixture directory."
        case .noOutputPath:
            return "The manifest did not provide an output_relative_path."
        case .missingFile:
            return "The output file is not present in the fixture directory."
        case .rejectedAbsolutePath:
            return "Absolute output paths are not read by the fixture inspector."
        case .rejectedPathTraversal:
            return "Paths containing '..' are not read by the fixture inspector."
        case .rejectedOutsideFixtureDirectory:
            return "The resolved output path is outside the fixture directory."
        case .unreadableFile:
            return "The output path could not be read as a regular file."
        }
    }
}

struct FetcherGeneratedViewManifestOutputPreview: Equatable, Sendable {
    let outputRelativePath: String?
    let status: FetcherGeneratedViewManifestPreviewStatus
    let resolvedPath: String?
    let text: String?
    let byteLimit: Int
    let isTruncated: Bool
}

struct FetcherContractLoader {
    static let requiredFiles = [
        "contract-version.json",
        "source-collections.json",
        "source-items.json",
        "source-evidence.json",
        "candidate-imports.json",
        "identity-bridge.json",
        "generated-view-manifests.json",
        "contract-health.json"
    ]

    /// Optional, backward-compatible provenance exports. Prefer v2's exact
    /// Navidrome song identity; retain v1 as a decode fallback.
    static let sourceAttributionFilename = "source-attribution.json"
    static let sourceAttributionV2Filename = "source-attribution-v2.json"
    static let sourceAttributionV3Filename = "source-attribution-v3.json"

    struct ProvenanceBundle: Sendable {
        let metadata: FetcherContractMetadata
        let collections: [FetcherSourceCollection]
        let attribution: [FetcherSourceAttribution]
    }

    var fileManager: FileManager = .default

    func previewGeneratedViewManifestOutput(
        for manifest: FetcherGeneratedViewManifest,
        fixtureDirectory: URL,
        byteLimit: Int = 16_384
    ) -> FetcherGeneratedViewManifestOutputPreview {
        previewGeneratedViewManifestOutput(
            relativePath: manifest.outputRelativePath,
            fixtureDirectory: fixtureDirectory,
            byteLimit: byteLimit
        )
    }

    func previewGeneratedViewManifestOutput(
        relativePath: String?,
        fixtureDirectory: URL,
        byteLimit: Int = 16_384
    ) -> FetcherGeneratedViewManifestOutputPreview {
        let sanitizedLimit = max(byteLimit, 0)

        guard let relativePath,
              !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FetcherGeneratedViewManifestOutputPreview(
                outputRelativePath: relativePath,
                status: .noOutputPath,
                resolvedPath: nil,
                text: nil,
                byteLimit: sanitizedLimit,
                isTruncated: false
            )
        }

        switch resolveFixtureRelativePath(relativePath, fixtureDirectory: fixtureDirectory) {
        case let .success(outputURL):
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: outputURL.path, isDirectory: &isDirectory) else {
                return FetcherGeneratedViewManifestOutputPreview(
                    outputRelativePath: relativePath,
                    status: .missingFile,
                    resolvedPath: outputURL.path,
                    text: nil,
                    byteLimit: sanitizedLimit,
                    isTruncated: false
                )
            }

            guard !isDirectory.boolValue, fileManager.isReadableFile(atPath: outputURL.path) else {
                return FetcherGeneratedViewManifestOutputPreview(
                    outputRelativePath: relativePath,
                    status: .unreadableFile,
                    resolvedPath: outputURL.path,
                    text: nil,
                    byteLimit: sanitizedLimit,
                    isTruncated: false
                )
            }

            do {
                let handle = try FileHandle(forReadingFrom: outputURL)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: sanitizedLimit + 1) ?? Data()
                let isTruncated = data.count > sanitizedLimit
                let previewData = isTruncated ? data.prefix(sanitizedLimit) : data
                return FetcherGeneratedViewManifestOutputPreview(
                    outputRelativePath: relativePath,
                    status: .available,
                    resolvedPath: outputURL.path,
                    text: String(decoding: previewData, as: UTF8.self),
                    byteLimit: sanitizedLimit,
                    isTruncated: isTruncated
                )
            } catch {
                return FetcherGeneratedViewManifestOutputPreview(
                    outputRelativePath: relativePath,
                    status: .unreadableFile,
                    resolvedPath: outputURL.path,
                    text: nil,
                    byteLimit: sanitizedLimit,
                    isTruncated: false
                )
            }

        case let .failure(status):
            return FetcherGeneratedViewManifestOutputPreview(
                outputRelativePath: relativePath,
                status: status,
                resolvedPath: nil,
                text: nil,
                byteLimit: sanitizedLimit,
                isTruncated: false
            )
        }
    }

    func loadSnapshot(from directory: URL) throws -> FetcherContractSnapshot {
        guard isReadableDirectory(directory) else {
            throw FetcherContractLoaderError.unreadableDirectory(directory.path)
        }

        for filename in Self.requiredFiles {
            guard fileManager.fileExists(atPath: directory.appendingPathComponent(filename).path) else {
                throw FetcherContractLoaderError.missingFile(filename)
            }
        }

        let metadata = try decode(FetcherContractMetadata.self, filename: "contract-version.json", directory: directory)
        guard metadata.exportSchemaVersion == 1 else {
            throw FetcherContractLoaderError.unsupportedExportSchemaVersion(metadata.exportSchemaVersion)
        }
        guard (1...2).contains(metadata.fetcherContractVersion) else {
            throw FetcherContractLoaderError.unsupportedContractVersion(metadata.fetcherContractVersion)
        }

        return FetcherContractSnapshot(
            metadata: metadata,
            sourceCollections: try decode([FetcherSourceCollection].self, filename: "source-collections.json", directory: directory),
            sourceItems: try decode([FetcherSourceItem].self, filename: "source-items.json", directory: directory),
            sourceEvidence: try decode([FetcherSourceEvidence].self, filename: "source-evidence.json", directory: directory),
            candidateImports: try decode([FetcherCandidateImport].self, filename: "candidate-imports.json", directory: directory),
            identityBridge: try decode([FetcherIdentityBridgeRow].self, filename: "identity-bridge.json", directory: directory),
            generatedViewManifests: try decode([FetcherGeneratedViewManifest].self, filename: "generated-view-manifests.json", directory: directory),
            contractHealth: try decode([FetcherContractHealthRow].self, filename: "contract-health.json", directory: directory),
            sourceAttribution: try decodeOptional(
                [FetcherSourceAttribution].self,
                filename: Self.sourceAttributionV3Filename,
                directory: directory
            ) ?? decodeOptional(
                [FetcherSourceAttribution].self,
                filename: Self.sourceAttributionV2Filename,
                directory: directory
            ) ?? decodeOptional(
                [FetcherSourceAttribution].self,
                filename: Self.sourceAttributionFilename,
                directory: directory
            ) ?? []
        )
    }

    /// Minimal read for durable background provenance import.  The Sources UI
    /// still loads its full inspector snapshot separately.
    func loadProvenanceBundle(from directory: URL) throws -> ProvenanceBundle {
        guard isReadableDirectory(directory) else { throw FetcherContractLoaderError.unreadableDirectory(directory.path) }
        let metadata = try decode(FetcherContractMetadata.self, filename: "contract-version.json", directory: directory)
        guard metadata.exportSchemaVersion == 1 else { throw FetcherContractLoaderError.unsupportedExportSchemaVersion(metadata.exportSchemaVersion) }
        guard (1...2).contains(metadata.fetcherContractVersion) else { throw FetcherContractLoaderError.unsupportedContractVersion(metadata.fetcherContractVersion) }
        let verified = try validatePublishedFiles(
            metadata: metadata,
            filenames: ["source-collections.json", Self.sourceAttributionV3Filename, Self.sourceAttributionV2Filename, Self.sourceAttributionFilename],
            directory: directory
        )
        let verifiedSnapshot: [String: Data]? = metadata.files.isEmpty ? nil : verified
        let attribution = try decodeOptional([FetcherSourceAttribution].self, filename: Self.sourceAttributionV3Filename, directory: directory, verifiedData: verifiedSnapshot)
            ?? decodeOptional([FetcherSourceAttribution].self, filename: Self.sourceAttributionV2Filename, directory: directory, verifiedData: verifiedSnapshot)
            ?? decodeOptional([FetcherSourceAttribution].self, filename: Self.sourceAttributionFilename, directory: directory, verifiedData: verifiedSnapshot)
            ?? []
        if !metadata.files.isEmpty, verified["source-collections.json"] == nil {
            throw FetcherContractLoaderError.missingFile("source-collections.json")
        }
        return ProvenanceBundle(
            metadata: metadata,
            collections: try decode([FetcherSourceCollection].self, data: verified["source-collections.json"] ?? Data(contentsOf: directory.appendingPathComponent("source-collections.json"))),
            attribution: attribution
        )
    }

    func loadMetadata(from directory: URL) throws -> FetcherContractMetadata {
        guard isReadableDirectory(directory) else { throw FetcherContractLoaderError.unreadableDirectory(directory.path) }
        let metadata = try decode(FetcherContractMetadata.self, filename: "contract-version.json", directory: directory)
        guard metadata.exportSchemaVersion == 1 else { throw FetcherContractLoaderError.unsupportedExportSchemaVersion(metadata.exportSchemaVersion) }
        guard (1...2).contains(metadata.fetcherContractVersion) else { throw FetcherContractLoaderError.unsupportedContractVersion(metadata.fetcherContractVersion) }
        return metadata
    }

    func loadSourceCollections(from directory: URL) throws -> [FetcherSourceCollection] {
        try decode([FetcherSourceCollection].self, filename: "source-collections.json", directory: directory)
    }

    /// The importer uses this lightweight path after facts are known-current.
    /// It still verifies the publication hash before project writes.
    func loadValidatedSourceCollections(from directory: URL, metadata: FetcherContractMetadata) throws -> [FetcherSourceCollection] {
        let verified = try validatePublishedFiles(metadata: metadata, filenames: ["source-collections.json"], directory: directory)
        if !metadata.files.isEmpty, verified["source-collections.json"] == nil {
            throw FetcherContractLoaderError.missingFile("source-collections.json")
        }
        return try decode([FetcherSourceCollection].self, data: verified["source-collections.json"] ?? Data(contentsOf: directory.appendingPathComponent("source-collections.json")))
    }

    /// Read an owned snapshot and verify it before any importer writes. A file
    /// declared in the publication cannot disappear into a silent legacy fallback.
    private func validatePublishedFiles(metadata: FetcherContractMetadata, filenames: [String], directory: URL) throws -> [String: Data] {
        guard !metadata.files.isEmpty else { return [:] }
        var summaries: [String: String] = [:]
        for summary in metadata.files {
            guard summaries[summary.path] == nil else {
                throw FetcherContractLoaderError.inconsistentExport("duplicate metadata entry for \(summary.path)")
            }
            summaries[summary.path] = summary.contentHash
        }
        var verified: [String: Data] = [:]
        for filename in filenames {
            let url = directory.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: url.path) else {
                if summaries[filename] != nil { throw FetcherContractLoaderError.missingFile(filename) }
                continue
            }
            guard let expected = summaries[filename] else {
                throw FetcherContractLoaderError.inconsistentExport("metadata has no hash for \(filename)")
            }
            // Do not memory-map: an in-place publisher write must not alter
            // bytes between checksum verification and JSON decoding.
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            guard expected == "sha256:\(digest)" else {
                throw FetcherContractLoaderError.inconsistentExport("hash mismatch for \(filename)")
            }
            verified[filename] = data
        }
        return verified
    }

    func configuredDirectory(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let envPath = environment["RESONANCE_FETCHER_CONTRACT_FIXTURE_DIR"],
           !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: envPath)
        }

        let storedPath = defaults.string(forKey: FetcherContractSettings.fixtureDirectoryKey) ?? ""
        let trimmedPath = storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmedPath)
    }

    private func decode<T: Decodable>(_ type: T.Type, filename: String, directory: URL) throws -> T {
        let url = directory.appendingPathComponent(filename)
        // A live export is tens of MB per file; mapping avoids copying the whole
        // payload into anonymous memory just to hand it to the decoder.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try JSONDecoder().decode(type, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// Decodes an optional export file, returning `nil` when the file is absent.
    /// A present-but-malformed file still throws (a broken export should surface).
    private func decodeOptional<T: Decodable>(_ type: T.Type, filename: String, directory: URL, verifiedData: [String: Data]? = nil) throws -> T? {
        if let verifiedData {
            guard let data = verifiedData[filename] else { return nil }
            return try JSONDecoder().decode(type, from: data)
        }
        let url = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try JSONDecoder().decode(type, from: data)
    }

    private func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue && fileManager.isReadableFile(atPath: url.path)
    }

    private func resolveFixtureRelativePath(
        _ relativePath: String,
        fixtureDirectory: URL
    ) -> Result<URL, FetcherGeneratedViewManifestPreviewStatus> {
        let trimmedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !NSString(string: trimmedPath).isAbsolutePath else {
            return .failure(.rejectedAbsolutePath)
        }

        let pathComponents = trimmedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !pathComponents.contains("..") else {
            return .failure(.rejectedPathTraversal)
        }

        let fixtureRoot = fixtureDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let outputURL = fixtureRoot
            .appendingPathComponent(trimmedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard outputURL.isContained(in: fixtureRoot) else {
            return .failure(.rejectedOutsideFixtureDirectory)
        }

        return .success(outputURL)
    }
}

private extension URL {
    func isContained(in directory: URL) -> Bool {
        let rootPath = directory.standardizedFileURL.path
        let childPath = standardizedFileURL.path
        guard childPath != rootPath else { return true }
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        return childPath.hasPrefix(rootPrefix)
    }
}

enum FetcherContractSettings {
    static let isEnabledKey = "enableFetcherSourceBrowser"
    static let fixtureDirectoryKey = "fetcherContractFixtureDirectory"

    /// The showcase build ships without the Sources browser, so the app
    /// never reads a Fetcher export at runtime.
    static var isEnabled: Bool { false }
}

enum FetcherCandidateRoute: String, Sendable {
    case waitingRoom = "waiting_room"
    case unclassified
    case projectOnly = "project_only"
    case autoAdmitByPolicy = "auto_admit_by_policy"
    case ignore
    case needsPolicy = "needs_policy"
    case unknown

    init(rawContractValue: String) {
        self = Self(rawValue: rawContractValue) ?? .unknown
    }

    var displayLabel: String {
        switch self {
        case .waitingRoom:
            return "Waiting Room"
        case .unclassified:
            return "Unclassified"
        case .projectOnly:
            return "Project Only"
        case .autoAdmitByPolicy:
            return "Auto-Admit by Policy"
        case .ignore:
            return "Ignore"
        case .needsPolicy:
            return "Needs Policy"
        case .unknown:
            return "Unknown"
        }
    }

    var isActionableWithoutPolicy: Bool {
        switch self {
        case .waitingRoom, .unclassified, .projectOnly, .ignore:
            return true
        case .autoAdmitByPolicy, .needsPolicy, .unknown:
            return false
        }
    }
}
