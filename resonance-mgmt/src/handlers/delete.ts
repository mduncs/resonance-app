import { resolve } from "node:path";

export interface DeletePayload {
  file_paths: string[];
  music_dir: string; // Allowed root directory — paths must be under this
}

export interface DeleteResult {
  results: Array<{
    path: string;
    deleted: boolean;
    trash_path?: string;
    error?: string;
  }>;
}

/**
 * Delete files by moving to Trash (not hard rm).
 * Validates all paths are under the allowed music directory to prevent path traversal.
 */
export async function handleDelete(payload: DeletePayload): Promise<DeleteResult> {
  const results: DeleteResult["results"] = [];
  const musicDir = resolve(payload.music_dir);

  for (const filePath of payload.file_paths) {
    try {
      // Canonicalize and validate path is under music directory
      const resolved = resolve(filePath);
      if (!resolved.startsWith(musicDir + "/")) {
        results.push({
          path: filePath,
          deleted: false,
          error: `Path traversal blocked — ${resolved} is outside ${musicDir}`,
        });
        continue;
      }

      // Check file exists
      const file = Bun.file(resolved);
      if (!(await file.exists())) {
        results.push({ path: filePath, deleted: false, error: "File not found" });
        continue;
      }

      // Move to Trash using macOS `mv` to ~/.Trash (preserving original name)
      const fileName = resolved.split("/").pop()!;
      const trashPath = `${process.env.HOME}/.Trash/${fileName}`;

      // Handle name collision in Trash
      let finalTrashPath = trashPath;
      let counter = 1;
      while (await Bun.file(finalTrashPath).exists()) {
        const ext = fileName.includes(".") ? "." + fileName.split(".").pop() : "";
        const base = fileName.includes(".")
          ? fileName.slice(0, fileName.lastIndexOf("."))
          : fileName;
        finalTrashPath = `${process.env.HOME}/.Trash/${base} ${counter}${ext}`;
        counter++;
      }

      const proc = Bun.spawn(["mv", resolved, finalTrashPath], {
        stdout: "pipe",
        stderr: "pipe",
      });
      const exitCode = await proc.exited;

      if (exitCode !== 0) {
        const stderr = await new Response(proc.stderr).text();
        results.push({ path: filePath, deleted: false, error: `mv failed: ${stderr.trim()}` });
      } else {
        results.push({ path: filePath, deleted: true, trash_path: finalTrashPath });
      }
    } catch (err) {
      results.push({
        path: filePath,
        deleted: false,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  return { results };
}
