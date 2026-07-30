import { stat } from "node:fs/promises";
import { parseFile } from "music-metadata";
import { parseFilePathsPayload, type StructuredJobError } from "../job-payload";

export interface ValidatePayload {
  file_paths: string[];
  scan_all?: boolean;
}

export interface ValidateResult {
  results: Array<{
    path: string;
    valid: boolean;
    issues: string[];
  }>;
  error?: StructuredJobError;
}

export async function handleValidate(payload: unknown): Promise<ValidateResult> {
  const parsedPayload = parseFilePathsPayload(payload, "validate");
  if (!parsedPayload.ok) {
    return {
      results: [],
      error: parsedPayload.error,
    };
  }

  const results: ValidateResult["results"] = [];

  for (const filePath of parsedPayload.value) {
    const issues: string[] = [];

    try {
      // Check file exists
      const fileStat = await stat(filePath);

      // Check zero-byte
      if (fileStat.size === 0) {
        issues.push("zero_byte");
        results.push({ path: filePath, valid: false, issues });
        continue;
      }

      // Try to parse metadata
      try {
        const metadata = await parseFile(filePath);
        const format = metadata.format;

        // Check for audio stream
        if (!format.duration || format.duration === 0) {
          issues.push("no_audio_stream");
        }

        // Check for basic metadata
        if (!metadata.common.title && !metadata.common.artist) {
          issues.push("missing_metadata");
        }
      } catch {
        issues.push("corrupt_header");
      }
    } catch {
      issues.push("file_not_found");
    }

    results.push({
      path: filePath,
      valid: issues.length === 0,
      issues,
    });
  }

  return { results };
}
