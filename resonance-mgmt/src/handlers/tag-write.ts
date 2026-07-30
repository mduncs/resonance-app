// Tag writing requires a different library than music-metadata (which is read-only).
// Using direct file manipulation via Bun's fs for common tag formats,
// or shelling out to an external tool. For now, placeholder that reports
// the operation for the Swift side to handle via a future implementation.
import {
  makeUnsupportedOperationError,
  type StructuredJobError,
} from "../job-payload";

export interface TagWritePayload {
  edits: Array<{
    file_path: string;
    fields: Record<string, string | number | null>;
  }>;
}

export interface TagWriteResult {
  results: Array<{
    path: string;
    success: boolean;
    error?: {
      code: string;
      message: string;
    };
  }>;
  error?: StructuredJobError;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export async function handleTagWrite(payload: unknown): Promise<TagWriteResult> {
  if (!isRecord(payload)) {
    return {
      results: [],
      error: {
        code: "invalid_payload",
        message: "tag_write payload must be a JSON object",
        details: { request_type: "tag_write" },
      },
    };
  }

  if (!Array.isArray(payload.edits)) {
    return {
      results: [],
      error: {
        code: "invalid_payload",
        message: "tag_write requires an edits array",
        details: { request_type: "tag_write" },
      },
    };
  }

  const unsupportedError = makeUnsupportedOperationError(
    "tag_write",
    "tag_write is not supported by resonance-mgmt v1"
  );
  const results: TagWriteResult["results"] = [];

  for (const edit of payload.edits) {
    if (
      !isRecord(edit) ||
      typeof edit.file_path !== "string" ||
      !isRecord(edit.fields)
    ) {
      results.push({
        path: isRecord(edit) && typeof edit.file_path === "string" ? edit.file_path : "",
        success: false,
        error: {
          code: "invalid_payload",
          message: "each tag_write edit must include file_path and fields",
        },
      });
      continue;
    }

    results.push({
      path: edit.file_path,
      success: false,
      error: {
        code: unsupportedError.code,
        message: unsupportedError.message,
      },
    });
  }

  return { results, error: unsupportedError };
}
