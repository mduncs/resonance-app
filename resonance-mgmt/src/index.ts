#!/usr/bin/env bun
/**
 * resonance-mgmt — Companion service for Resonance music player.
 *
 * Communicates with the Swift app via shared SQLite database.
 * Polls for pending requests, processes them, writes results back.
 *
 * Usage:
 *   resonance-mgmt --db /path/to/resonance.db                # daemon mode
 *   resonance-mgmt --db /path/to/resonance.db --process-pending  # single pass
 */

import { parseArgs } from "node:util";
import { initDb, closeDb, fetchPendingRequests, updateRequestStatus } from "./db";
import { handleTagRead } from "./handlers/tag-read";
import { handleTagWrite } from "./handlers/tag-write";
import { handleFingerprint } from "./handlers/fingerprint";
import { handleValidate } from "./handlers/validate";
import { handleDelete } from "./handlers/delete";

const { values } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    db: { type: "string" },
    "process-pending": { type: "boolean", default: false },
    help: { type: "boolean", default: false },
  },
});

if (values.help || !values.db) {
  console.log(`resonance-mgmt — Companion service for Resonance

Usage:
  resonance-mgmt --db <path>                  Daemon mode (poll for requests)
  resonance-mgmt --db <path> --process-pending  Single pass (process pending, exit)

Options:
  --db <path>          Path to resonance.db (required)
  --process-pending    Process pending requests and exit
  --help               Show this help`);
  process.exit(values.help ? 0 : 1);
}

// Initialize database
const db = initDb(values.db);
console.log(`[resonance-mgmt] Connected to ${values.db}`);

// Write heartbeat
db.prepare(
  `INSERT INTO sync_metadata (key, value, updated_at) VALUES ('mgmt.heartbeat', datetime('now'), datetime('now'))
   ON CONFLICT(key) DO UPDATE SET value = datetime('now'), updated_at = datetime('now')`
).run();

async function processRequest(request: { id: string; type: string; payload_json: string }) {
  console.log(`[resonance-mgmt] Processing ${request.type} (${request.id})`);
  updateRequestStatus(request.id, "processing");

  try {
    const payload = JSON.parse(request.payload_json);
    let result: unknown;

    switch (request.type) {
      case "tag_read":
        result = await handleTagRead(payload);
        break;
      case "tag_write":
        result = await handleTagWrite(payload);
        break;
      case "fingerprint":
        result = await handleFingerprint(payload);
        break;
      case "validate":
        result = await handleValidate(payload);
        break;
      case "delete":
        result = await handleDelete(payload);
        break;
      default:
        throw new Error(`Unknown request type: ${request.type}`);
    }

    updateRequestStatus(request.id, "completed", JSON.stringify(result));
    console.log(`[resonance-mgmt] Completed ${request.type} (${request.id})`);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    updateRequestStatus(request.id, "failed", undefined, message);
    console.error(`[resonance-mgmt] Failed ${request.type} (${request.id}): ${message}`);
  }
}

async function processPending() {
  const requests = fetchPendingRequests();
  if (requests.length === 0) return 0;

  console.log(`[resonance-mgmt] Found ${requests.length} pending request(s)`);
  for (const request of requests) {
    await processRequest(request);
  }
  return requests.length;
}

// Single pass mode
if (values["process-pending"]) {
  const count = await processPending();
  console.log(`[resonance-mgmt] Processed ${count} request(s), exiting.`);
  closeDb();
  process.exit(0);
}

// Daemon mode — poll every second
console.log("[resonance-mgmt] Daemon mode — polling for requests...");

let running = true;
process.on("SIGTERM", () => {
  console.log("[resonance-mgmt] Received SIGTERM, shutting down...");
  running = false;
});
process.on("SIGINT", () => {
  console.log("[resonance-mgmt] Received SIGINT, shutting down...");
  running = false;
});

while (running) {
  try {
    await processPending();

    // Update heartbeat
    db.prepare(
      `UPDATE sync_metadata SET value = datetime('now'), updated_at = datetime('now') WHERE key = 'mgmt.heartbeat'`
    ).run();
  } catch (err) {
    console.error(`[resonance-mgmt] Poll error: ${err}`);
  }

  await Bun.sleep(1000);
}

closeDb();
console.log("[resonance-mgmt] Shut down cleanly.");
