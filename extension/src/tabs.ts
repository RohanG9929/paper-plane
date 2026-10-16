// What the extension knows about a tab (spec §5.1), as pure functions of what Chrome reports.
// The service worker keeps it in chrome.storage.session, so it survives the worker being
// suspended, and starts afresh when the tab loads a new page.
import { classify } from "./classify";
import { isYouTubeVideo } from "./message";
import { keyOf, type Candidate, type FrameVideo } from "./detector";

export interface TabState {
  candidates: Candidate[];
  videos: FrameVideo[];
  /** A YouTube page's cookie and user agent, for yt-dlp (spec §5.1). */
  pageHeaders?: Record<string, string>;
  /** Why the last send failed, until the next try. */
  error?: string;
}

/** A response, with the headers of its request if they were captured. */
export interface Response {
  url: string;
  frameId: number;
  /** Chrome's request type: "media", "xmlhttprequest", "other"… */
  type: string;
  timeStamp: number;
  statusCode: number;
  contentType?: string;
  headers: Record<string, string>;
}

export const maximumCandidates = 20;
/** HLS playlists fetched this soon after a master, from its frame and host, are its variants. */
export const burstWindow = 10_000;

const headerNames: Record<string, string> = {
  cookie: "Cookie",
  referer: "Referer",
  origin: "Origin",
  "user-agent": "User-Agent",
};

export function newTab(): TabState {
  return { candidates: [], videos: [] };
}

/** The headers a site needs to hand over its video, and nothing else (spec §5.1). */
export function pickHeaders(raw: { name: string; value?: string }[] | undefined): Record<string, string> {
  const kept: Record<string, string> = {};
  for (const header of raw ?? []) {
    const name = headerNames[header.name.toLowerCase()];
    if (name && header.value !== undefined) {
      kept[name] = header.value;
    }
  }
  return kept;
}

/** A new page in the tab: nothing found yet. A YouTube video page keeps its cookie. */
export function navigated(url: string, headers: Record<string, string>): TabState {
  if (!isYouTubeVideo(url)) {
    return newTab();
  }
  const pageHeaders: Record<string, string> = {};
  for (const name of ["Cookie", "User-Agent"]) {
    if (headers[name] !== undefined) {
      pageHeaders[name] = headers[name];
    }
  }
  return { ...newTab(), pageHeaders };
}

export function withVideos(tab: TabState, frameId: number, videos: Omit<FrameVideo, "frameId">[]): TabState {
  return {
    ...tab,
    videos: [...tab.videos.filter((video) => video.frameId !== frameId), ...videos.map((video) => ({ frameId, ...video }))],
  };
}

/** Takes a response into account: a new stream, a repeat of one, or a segment of one. */
export function observe(tab: TabState, response: Response): TabState {
  if (response.statusCode < 200 || response.statusCode >= 300) {
    return tab;
  }
  const kind = classify(response.url, response.contentType, response.type);
  let key: string;
  try {
    key = keyOf(response.url);
  } catch {
    return tab;
  }
  if (!kind) {
    return tab;
  }
  const candidates = tab.candidates.map((candidate) => ({ ...candidate }));
  const now = response.timeStamp;
  if (kind === "segment") {
    credit(candidates, response.url, now);
    return { ...tab, candidates };
  }
  const known = candidates.find((candidate) => candidate.key === key);
  if (known) {
    // A live playlist reloading, or a video fetching its next range: still playing.
    known.url = response.url;
    known.lastSeen = now;
    known.lastActivity = now;
    if (Object.keys(response.headers).length > 0) {
      known.headers = response.headers;
    }
    const master = candidates.find((candidate) => candidate.key === known.variantOf);
    if (master) {
      master.lastActivity = now;
    }
    return { ...tab, candidates };
  }
  const host = new URL(response.url).host;
  const master = kind === "hls"
    ? candidates.find((candidate) => candidate.format === "hls" && candidate.variantOf === undefined
        && candidate.frameId === response.frameId && new URL(candidate.url).host === host
        && now - candidate.firstSeen <= burstWindow)
    : undefined;
  candidates.push({
    key, url: response.url, format: kind, frameId: response.frameId, headers: response.headers,
    firstSeen: now, lastSeen: now, isMaster: kind === "hls" && master === undefined,
    ...(master ? { variantOf: master.key } : {}),
  });
  candidates.sort((a, b) => a.lastSeen - b.lastSeen);
  return { ...tab, candidates: candidates.slice(-maximumCandidates) };
}

/** Marks the stream a segment belongs to as active: the one on the same host whose playlist's
 *  folder holds the segment, the deepest such folder winning; a variant's master with it. */
function credit(candidates: Candidate[], url: string, now: number): void {
  const segment = new URL(url);
  let owner: Candidate | undefined;
  let depth = -1;
  for (const candidate of candidates) {
    const playlist = new URL(candidate.url);
    const folder = playlist.pathname.slice(0, playlist.pathname.lastIndexOf("/") + 1);
    if (playlist.host === segment.host && segment.pathname.startsWith(folder) && folder.length > depth) {
      owner = candidate;
      depth = folder.length;
    }
  }
  if (!owner) {
    return;
  }
  owner.lastActivity = now;
  const master = candidates.find((candidate) => candidate.key === owner.variantOf);
  if (master) {
    master.lastActivity = now;
  }
}
