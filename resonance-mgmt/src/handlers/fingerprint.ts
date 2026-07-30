import { getDb } from "../db";
import {
  parseFingerprintPayload,
  type FingerprintFileTarget,
  type StructuredJobError,
} from "../job-payload";

export interface FingerprintPayload {
  file_paths: string[];
  scan_all?: boolean;
}

export interface FingerprintResult {
  fingerprints: Array<{
    path: string;
    fingerprint?: string;
    duration?: number;
    error?: string;
    stored?: boolean;
    warning?: string;
  }>;
  error?: StructuredJobError;
}

/**
 * Compute acoustic fingerprints using Chromaprint's fpcalc.
 * Looks for fpcalc in:
 * 1. Same directory as this binary (bundled in .app)
 * 2. /opt/homebrew/bin/fpcalc (Homebrew)
 * 3. /usr/local/bin/fpcalc
 */
async function findFpcalc(): Promise<string | null> {
  const candidates = [
    `${import.meta.dir}/fpcalc`,
    `${import.meta.dir}/../fpcalc`,
    "/opt/homebrew/bin/fpcalc",
    "/usr/local/bin/fpcalc",
  ];

  for (const path of candidates) {
    try {
      const file = Bun.file(path);
      if (await file.exists()) return path;
    } catch {
      continue;
    }
  }
  return null;
}

function shouldPersistFingerprint(target: FingerprintFileTarget): target is Required<FingerprintFileTarget> {
  return typeof target.song_id === "string" && typeof target.server_id === "string";
}

function persistFingerprint(
  target: Required<FingerprintFileTarget>,
  fingerprint: string,
  duration: number
): void {
  const db = getDb();
  const update = db.prepare(
    `UPDATE fingerprints
     SET fingerprint = ?, duration = ?, computed_at = datetime('now')
     WHERE song_id = ? AND server_id = ?`
  );
  const insert = db.prepare(
    `INSERT INTO fingerprints (song_id, server_id, fingerprint, duration, computed_at)
     VALUES (?, ?, ?, ?, datetime('now'))`
  );

  const updated = update.run(fingerprint, duration, target.song_id, target.server_id);
  if (updated.changes === 0) {
    insert.run(target.song_id, target.server_id, fingerprint, duration);
  }
}

export async function handleFingerprint(payload: unknown): Promise<FingerprintResult> {
  const parsedPayload = parseFingerprintPayload(payload);
  if (!parsedPayload.ok) {
    return {
      fingerprints: [],
      error: parsedPayload.error,
    };
  }

  const fpcalcPath = await findFpcalc();
  if (!fpcalcPath) {
    return {
      fingerprints: parsedPayload.value.map(({ file_path: filePath }) => ({
        path: filePath,
        error: "fpcalc not found — install Chromaprint or bundle fpcalc binary",
      })),
    };
  }

  const fingerprints: FingerprintResult["fingerprints"] = [];

  // Process in batches to limit concurrency
  const BATCH_SIZE = 3;
  for (let i = 0; i < parsedPayload.value.length; i += BATCH_SIZE) {
    const batch = parsedPayload.value.slice(i, i + BATCH_SIZE);
    const results = await Promise.allSettled(
      batch.map(async (target) => {
        const filePath = target.file_path;
        try {
          const proc = Bun.spawn([fpcalcPath, "-json", filePath], {
            stdout: "pipe",
            stderr: "pipe",
          });
          const output = await new Response(proc.stdout).text();
          const exitCode = await proc.exited;

          if (exitCode !== 0) {
            const stderr = await new Response(proc.stderr).text();
            return { path: filePath, error: `fpcalc exit ${exitCode}: ${stderr.trim()}` };
          }

          const parsed = JSON.parse(output) as { fingerprint: string; duration: number };

          if (shouldPersistFingerprint(target)) {
            persistFingerprint(target, parsed.fingerprint, parsed.duration);
            return {
              path: filePath,
              fingerprint: parsed.fingerprint,
              duration: parsed.duration,
              stored: true,
            };
          }

          return {
            path: filePath,
            fingerprint: parsed.fingerprint,
            duration: parsed.duration,
            stored: false,
            warning:
              "Fingerprint computed but not persisted because song_id/server_id were not both provided",
          };
        } catch (err) {
          return { path: filePath, error: err instanceof Error ? err.message : String(err) };
        }
      })
    );

    for (const result of results) {
      if (result.status === "fulfilled") {
        fingerprints.push(result.value);
      } else {
        fingerprints.push({ path: "unknown", error: String(result.reason) });
      }
    }
  }

  return { fingerprints };
}
