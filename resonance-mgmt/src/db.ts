import { Database } from "bun:sqlite";

let db: Database | null = null;

export function getDb(): Database {
  if (!db) throw new Error("Database not initialized. Call initDb() first.");
  return db;
}

export function initDb(dbPath: string): Database {
  db = new Database(dbPath);
  db.exec("PRAGMA journal_mode = WAL");
  db.exec("PRAGMA busy_timeout = 5000");
  return db;
}

export function closeDb(): void {
  db?.close();
  db = null;
}

// MARK: - Request types

export interface MgmtRequest {
  id: string;
  type: string;
  payload_json: string;
  status: string;
  result_json: string | null;
  error_message: string | null;
  created_at: string;
  completed_at: string | null;
}

export function fetchPendingRequests(): MgmtRequest[] {
  const db = getDb();
  return db
    .prepare("SELECT * FROM mgmt_requests WHERE status = 'pending' ORDER BY created_at ASC")
    .all() as MgmtRequest[];
}

export function updateRequestStatus(
  id: string,
  status: "processing" | "completed" | "failed",
  result?: string,
  error?: string
): void {
  const db = getDb();
  db.prepare(
    `UPDATE mgmt_requests SET status = ?, result_json = ?, error_message = ?, completed_at = datetime('now')
     WHERE id = ?`
  ).run(status, result ?? null, error ?? null, id);
}
