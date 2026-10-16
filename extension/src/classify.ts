// What a request is to Paper Plane (spec §5.1): a stream to offer, a piece of one, or nothing.

export type Format = "hls" | "dash" | "progressive";
export type Kind = Format | "segment";

const manifestTypes: Record<string, Format> = {
  "application/vnd.apple.mpegurl": "hls",
  "application/x-mpegurl": "hls",
  "audio/mpegurl": "hls",
  "audio/x-mpegurl": "hls",
  "application/dash+xml": "dash",
};
const manifestExtensions: Record<string, Format> = { m3u8: "hls", mpd: "dash" };
const segmentTypes = new Set(["video/mp2t", "video/iso.segment", "audio/mp4", "audio/aac", "audio/mpeg", "audio/webm"]);
const segmentExtensions = new Set(["ts", "m4s", "m4a", "aac", "cmfv", "cmfa"]);
const fileTypes = new Set(["video/mp4", "video/webm", "video/quicktime", "video/x-m4v"]);
const fileExtensions = new Set(["mp4", "m4v", "webm", "mov"]);

/** The lower-case extension of the URL's last path component, if it has one. */
export function extensionOf(url: string): string {
  let path = url;
  try {
    path = new URL(url).pathname;
  } catch {
    path = url.split(/[?#]/)[0] ?? "";
  }
  const name = path.slice(path.lastIndexOf("/") + 1);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
}

/**
 * Classifies a response by its content type and URL. `requestType` is Chrome's: "media" for a
 * <video> element's own requests, "xmlhttprequest" or "other" for a player's fetches. A video
 * file a player fetches piece by piece is a segment of a stream, not a video to send.
 */
export function classify(url: string, contentType: string | undefined, requestType: string): Kind | undefined {
  const type = (contentType ?? "").split(";")[0]!.trim().toLowerCase();
  const extension = extensionOf(url);
  const manifest = manifestTypes[type] ?? manifestExtensions[extension];
  if (manifest) {
    return manifest;
  }
  if (segmentTypes.has(type) || segmentExtensions.has(extension)) {
    return "segment";
  }
  if (fileTypes.has(type) || fileExtensions.has(extension)) {
    return requestType === "media" ? "progressive" : "segment";
  }
  return undefined;
}
