// What the extension knows about a tab (spec §5.1), as pure functions of what Chrome reports.
// The service worker keeps it in chrome.storage.session, so it survives the worker being
// suspended, and starts afresh when the tab loads a new page. A function that changes nothing
// returns the state it was given, so the worker can skip saving and redrawing.
import { classify } from "./classify";
import { isMaster, keyOf, type Candidate, type FrameVideo } from "./detector";
import { isYouTube } from "./message";
import type { Video } from "./videos";

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
/** Activity is noted at most this often: the ranking only asks whether it's recent. */
export const activityResolution = 5_000;

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

/** A new page in the tab: nothing found yet. On YouTube, whose videos open without loading a
 *  new page, the cookie and user agent are kept for the page request. */
export function navigated(url: string, headers: Record<string, string>): TabState {
  if (!isYouTube(url)) {
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

/** A frame's videos as just reported. Only the time having moved on isn't a change. */
export function withVideos(tab: TabState, frameId: number, videos: Video[]): TabState {
  const before = tab.videos.filter((video) => video.frameId === frameId);
  const same = before.length === videos.length && before.every((video, index) =>
    video.src === videos[index]?.src && video.playing === videos[index]?.playing && video.duration === videos[index]?.duration);
  if (same) {
    return tab;
  }
  return {
    ...tab,
    videos: [...tab.videos.filter((video) => video.frameId !== frameId), ...videos.map((video) => ({ frameId, ...video }))],
  };
}

/** Takes a response into account: a new stream, a repeat of one, or a piece of one. */
export function observe(tab: TabState, response: Response): TabState {
  if (response.statusCode < 200 || response.statusCode >= 300) {
    return tab;
  }
  const kind = classify(response.url, response.contentType, response.type);
  // DASH isn't offered: Paper Plane's ffmpeg is built without the DASH reader (decision 10).
  if (!kind || kind === "dash") {
    return tab;
  }
  let key: string;
  try {
    key = keyOf(response.url);
  } catch {
    return tab;
  }
  const now = response.timeStamp;
  // A segment, or a video file a stream's own player fetched (Chrome playing HLS itself).
  const stream = kind === "segment" || kind === "progressive"
    ? ownerOf(tab.candidates, response.url, kind === "progressive")
    : undefined;
  if (kind === "segment" || stream) {
    return stream ? touch(tab, stream, now) : tab;
  }

  const known = tab.candidates.find((candidate) => candidate.key === key);
  if (known) {
    // A live playlist reloading, or a video fetching its next range: still playing.
    const headers = Object.keys(response.headers).length > 0 ? response.headers : known.headers;
    if (known.url === response.url && now - known.lastSeen < activityResolution
        && JSON.stringify(headers) === JSON.stringify(known.headers)) {
      return tab;
    }
    const updated = { ...known, url: response.url, lastSeen: now, lastActivity: now, headers };
    return touch({ ...tab, candidates: tab.candidates.map((candidate) => candidate === known ? updated : candidate) },
      updated, now, true);
  }

  const master = kind === "hls" ? masterOf(tab.candidates, response, now) : undefined;
  const added: Candidate = {
    key, url: response.url, format: kind, frameId: response.frameId, headers: response.headers,
    firstSeen: now, lastSeen: now, ...(master ? { variantOf: master.key } : {}),
  };
  const recency = (candidate: Candidate) => Math.max(candidate.lastSeen, candidate.lastActivity ?? 0);
  const candidates = [...tab.candidates, added].sort((a, b) => recency(a) - recency(b));
  return { ...tab, candidates: candidates.slice(-maximumCandidates) };
}

function folderOf(url: URL): string {
  return url.pathname.slice(0, url.pathname.lastIndexOf("/") + 1);
}

/** The stream a piece belongs to: the one on its host whose playlist's folder holds it, the
 *  deepest such folder winning. `streamsOnly` leaves out plain video files. */
function ownerOf(candidates: Candidate[], url: string, streamsOnly: boolean): Candidate | undefined {
  const piece = new URL(url);
  let owner: Candidate | undefined;
  let depth = -1;
  for (const candidate of candidates) {
    if (streamsOnly && candidate.format === "progressive") {
      continue;
    }
    const playlist = new URL(candidate.url);
    const folder = folderOf(playlist);
    if (playlist.host === piece.host && piece.pathname.startsWith(folder) && folder.length > depth) {
      owner = candidate;
      depth = folder.length;
    }
  }
  return owner;
}

/** The master a new HLS playlist is a variant of: one from its frame and host whose folder holds
 *  it in a subfolder (`720p/index.m3u8`), or failing that one fetched moments before it. */
function masterOf(candidates: Candidate[], response: Response, now: number): Candidate | undefined {
  const url = new URL(response.url);
  const masters = candidates.filter((candidate) =>
    isMaster(candidate) && candidate.frameId === response.frameId && new URL(candidate.url).host === url.host);
  const byFolder = masters
    .map((master) => ({ master, folder: folderOf(new URL(master.url)) }))
    .filter(({ folder }) => url.pathname.startsWith(folder) && url.pathname.slice(folder.length).includes("/"))
    .sort((a, b) => b.folder.length - a.folder.length)[0]?.master;
  return byFolder ?? masters.filter((master) => now - master.firstSeen <= burstWindow)
    .sort((a, b) => b.firstSeen - a.firstSeen)[0];
}

/** Notes `candidate` as active at `now`, with its master, unless that was noted a moment ago
 *  (`force` when the candidate has already been updated). */
function touch(tab: TabState, candidate: Candidate, now: number, force = false): TabState {
  if (!force && candidate.lastActivity !== undefined && now - candidate.lastActivity < activityResolution) {
    return tab;
  }
  return {
    ...tab,
    candidates: tab.candidates.map((other) =>
      other.key === candidate.key || other.key === candidate.variantOf ? { ...other, lastActivity: now } : other),
  };
}
