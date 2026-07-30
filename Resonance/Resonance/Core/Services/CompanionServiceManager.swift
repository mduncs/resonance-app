import Foundation
import GRDB

/// Manages the resonance-mgmt companion service lifecycle.
/// Feature-gated: if the binary isn't bundled, all management features are disabled.
@MainActor
final class CompanionServiceManager: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isRunning = false

    private let databaseManager: DatabaseManager
    private var process: Process?
    private var healthTimer: Timer?

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
        self.isAvailable = mgmtURL != nil
    }

    // MARK: - Binary location

    /// Look for resonance-mgmt in the app bundle, or fall back to the repo build
    private var mgmtURL: URL? {
        // 1. Bundled in .app
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "resonance-mgmt") {
            return bundled
        }

        // 2. Development fallback: check repo-relative path
        #if DEBUG
        let repoPath = Bundle.main.bundleURL
            .deletingLastPathComponent() // Debug/
            .deletingLastPathComponent() // Products/
            .deletingLastPathComponent() // Build/
            .deletingLastPathComponent() // DerivedData/Resonance-xxx/
            .deletingLastPathComponent() // DerivedData/
            .deletingLastPathComponent() // Xcode/
            .deletingLastPathComponent() // Developer/
            .deletingLastPathComponent() // Library/
        // Actually, for dev, check a known path
        let devPath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("code/music-player/resonance-mgmt/resonance-mgmt")
        if FileManager.default.fileExists(atPath: devPath.path) {
            return devPath
        }
        #endif

        return nil
    }

    // MARK: - Lifecycle

    /// Start the companion service in daemon mode
    func start() {
        guard let url = mgmtURL, !isRunning else { return }

        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["--db", databaseManager.dbPath]

        // Redirect output for debugging
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.process = nil
            }
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            startHealthCheck()
            print("[CompanionServiceManager] Started resonance-mgmt (PID \(proc.processIdentifier))")
        } catch {
            print("[CompanionServiceManager] Failed to start: \(error)")
        }
    }

    /// Stop the companion service
    func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        process = nil
        isRunning = false
        healthTimer?.invalidate()
        healthTimer = nil
    }

    /// Run a single pass (process pending requests and exit)
    func processPending() {
        guard let url = mgmtURL else { return }

        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["--db", databaseManager.dbPath, "--process-pending"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            print("[CompanionServiceManager] Failed to run single pass: \(error)")
        }
    }

    // MARK: - Request Creation

    /// Create a management request and optionally trigger processing
    func createRequest(type: String, payload: [String: Any]) throws -> String {
        let requestId = UUID().uuidString
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"

        try databaseManager.write { db in
            try db.execute(
                sql: """
                    INSERT INTO mgmt_requests (id, type, payload_json, status, created_at)
                    VALUES (?, ?, ?, 'pending', datetime('now'))
                    """,
                arguments: [requestId, type, payloadString]
            )
        }

        // If daemon isn't running, do a single-pass to process
        if !isRunning {
            processPending()
        }

        return requestId
    }

    /// Check the result of a request (poll-based)
    func checkResult(requestId: String) throws -> (status: String, result: String?, error: String?) {
        try databaseManager.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT status, result_json, error_message FROM mgmt_requests WHERE id = ?",
                arguments: [requestId]
            ) else {
                return (status: "not_found", result: nil, error: nil)
            }
            return (
                status: row["status"] as String,
                result: row["result_json"] as String?,
                error: row["error_message"] as String?
            )
        }
    }

    // MARK: - Health Check

    private func startHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkHealth()
            }
        }
    }

    private func checkHealth() {
        // Check if process is still running
        if let proc = process, !proc.isRunning {
            isRunning = false
            process = nil
            healthTimer?.invalidate()
            healthTimer = nil
        }
    }

    func cleanup() {
        stop()
    }
}
