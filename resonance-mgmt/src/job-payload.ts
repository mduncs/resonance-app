export interface StructuredJobError {
  code:
    | "invalid_payload"
    | "missing_file_paths"
    | "unsupported_scan_all"
    | "unsupported_operation";
  message: string;
  details?: Record<string, unknown>;
}

export interface FilePathsPayload {
  file_paths: string[];
  scan_all?: boolean;
}

export interface FingerprintFileTarget {
  file_path: string;
  song_id?: string;
  server_id?: string;
}

export interface FingerprintPayloadV1 extends FilePathsPayload {
  files?: FingerprintFileTarget[];
}

type ParseResult<T> = { ok: true; value: T } | { ok: false; error: StructuredJobError };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function makeError(
  code: StructuredJobError["code"],
  requestType: string,
  message: string,
  details: Record<string, unknown> = {}
): StructuredJobError {
  return {
    code,
    message,
    details: {
      request_type: requestType,
      ...details,
    },
  };
}

export function parseFilePathsPayload(
  payload: unknown,
  requestType: string
): ParseResult<string[]> {
  if (!isRecord(payload)) {
    return {
      ok: false,
      error: makeError(
        "invalid_payload",
        requestType,
        `${requestType} payload must be a JSON object`
      ),
    };
  }

  if (payload.scan_all === true) {
    return {
      ok: false,
      error: makeError(
        "unsupported_scan_all",
        requestType,
        `${requestType} requires explicit file_paths; scan_all is not supported by resonance-mgmt v1`,
        { scan_all: true }
      ),
    };
  }

  if (!("file_paths" in payload)) {
    return {
      ok: false,
      error: makeError(
        "missing_file_paths",
        requestType,
        `${requestType} requires a file_paths array`
      ),
    };
  }

  const { file_paths: filePaths } = payload;
  if (!Array.isArray(filePaths) || !filePaths.every((value) => typeof value === "string")) {
    return {
      ok: false,
      error: makeError(
        "invalid_payload",
        requestType,
        `${requestType} file_paths must be an array of strings`
      ),
    };
  }

  return { ok: true, value: filePaths };
}

export function parseFingerprintPayload(
  payload: unknown
): ParseResult<FingerprintFileTarget[]> {
  if (!isRecord(payload)) {
    return {
      ok: false,
      error: makeError(
        "invalid_payload",
        "fingerprint",
        "fingerprint payload must be a JSON object"
      ),
    };
  }

  if (payload.scan_all === true) {
    return {
      ok: false,
      error: makeError(
        "unsupported_scan_all",
        "fingerprint",
        "fingerprint requires explicit file_paths; scan_all is not supported by resonance-mgmt v1",
        { scan_all: true }
      ),
    };
  }

  if ("files" in payload) {
    const { files } = payload;
    if (!Array.isArray(files)) {
      return {
        ok: false,
        error: makeError(
          "invalid_payload",
          "fingerprint",
          "fingerprint files must be an array"
        ),
      };
    }

    const parsed: FingerprintFileTarget[] = [];
    for (const item of files) {
      if (!isRecord(item) || typeof item.file_path !== "string") {
        return {
          ok: false,
          error: makeError(
            "invalid_payload",
            "fingerprint",
            "each fingerprint file entry must include a string file_path"
          ),
        };
      }

      if ("song_id" in item && item.song_id !== undefined && typeof item.song_id !== "string") {
        return {
          ok: false,
          error: makeError(
            "invalid_payload",
            "fingerprint",
            "fingerprint song_id must be a string when provided"
          ),
        };
      }

      if (
        "server_id" in item &&
        item.server_id !== undefined &&
        typeof item.server_id !== "string"
      ) {
        return {
          ok: false,
          error: makeError(
            "invalid_payload",
            "fingerprint",
            "fingerprint server_id must be a string when provided"
          ),
        };
      }

      parsed.push({
        file_path: item.file_path,
        song_id: item.song_id as string | undefined,
        server_id: item.server_id as string | undefined,
      });
    }

    return { ok: true, value: parsed };
  }

  const filePaths = parseFilePathsPayload(payload, "fingerprint");
  if (!filePaths.ok) return filePaths;

  return {
    ok: true,
    value: filePaths.value.map((filePath) => ({ file_path: filePath })),
  };
}

export function makeUnsupportedOperationError(
  requestType: string,
  message: string
): StructuredJobError {
  return makeError("unsupported_operation", requestType, message);
}
