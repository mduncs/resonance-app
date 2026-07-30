import { parseFile } from "music-metadata";

export interface TagReadPayload {
  file_paths: string[];
}

export interface TagReadResult {
  tags: Array<{
    path: string;
    title?: string;
    artist?: string;
    album?: string;
    year?: number;
    genre?: string;
    track?: number;
    disc?: number;
    duration?: number;
    bitrate?: number;
    format?: string;
    error?: string;
  }>;
}

export async function handleTagRead(payload: TagReadPayload): Promise<TagReadResult> {
  const tags: TagReadResult["tags"] = [];

  for (const filePath of payload.file_paths) {
    try {
      const metadata = await parseFile(filePath);
      const common = metadata.common;
      const format = metadata.format;

      tags.push({
        path: filePath,
        title: common.title,
        artist: common.artist,
        album: common.album,
        year: common.year,
        genre: common.genre?.[0],
        track: common.track?.no ?? undefined,
        disc: common.disk?.no ?? undefined,
        duration: format.duration,
        bitrate: format.bitrate,
        format: format.container,
      });
    } catch (err) {
      tags.push({
        path: filePath,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  return { tags };
}
