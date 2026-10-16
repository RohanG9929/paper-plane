// The play request sent to Paper Plane through its helper (spec §5.2, message v1).
import type { Candidate, FrameVideo } from "./detector";
import type { Format } from "./classify";

/** The native messaging host the app installs for Chrome and Brave. */
export const hostName = "dev.paperplane.host";

export interface PlayMessage {
  type: "play";
  v: 1;
  source:
    | { kind: "stream"; url: string; format: Format; headers: Record<string, string> }
    | { kind: "page"; url: string; headers: Record<string, string> };
  pageUrl: string;
  title: string;
  startAt: number;
}

export interface Page {
  url: string;
  title: string;
}

export function streamMessage(candidate: Candidate, page: Page, startAt: number): PlayMessage {
  return {
    type: "play", v: 1,
    source: { kind: "stream", url: candidate.url, format: candidate.format, headers: candidate.headers },
    pageUrl: page.url, title: tidyTitle(page.title), startAt,
  };
}

/** YouTube: the page itself, for yt-dlp in the app, with the site's cookie (spec §5.1). */
export function pageMessage(page: Page, headers: Record<string, string>, startAt: number): PlayMessage {
  return {
    type: "play", v: 1,
    source: { kind: "page", url: page.url, headers },
    pageUrl: page.url, title: tidyTitle(page.title), startAt,
  };
}

/** A YouTube video's page: a watch, Shorts or live page, or a youtu.be link. */
export function isYouTubeVideo(url: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  const host = parsed.hostname;
  if (host === "youtu.be") {
    return parsed.pathname.length > 1;
  }
  if (host !== "youtube.com" && !host.endsWith(".youtube.com")) {
    return false;
  }
  return (parsed.pathname === "/watch" && parsed.searchParams.has("v"))
    || /^\/(shorts|live)\/[^/]+/.test(parsed.pathname);
}

/** Where the browser's video is: the playing one in `frameId` (any frame for -1), else its
 *  first video, in seconds. */
export function startTime(videos: FrameVideo[], frameId: number): number {
  const inFrame = videos.filter((video) => frameId < 0 || video.frameId === frameId);
  const video = inFrame.find((candidate) => candidate.playing) ?? inFrame[0];
  const time = video?.currentTime ?? 0;
  return Number.isFinite(time) && time > 0 ? time : 0;
}

/** One line, without YouTube's " - YouTube". */
export function tidyTitle(title: string | undefined): string {
  return (title ?? "").replace(/\s+/g, " ").trim().replace(/ - YouTube$/, "");
}

/** What to tell the user when sending failed: the app's own words, or plain ones for Chrome's. */
export function failureText(failure: unknown): string {
  if (typeof failure === "object" && failure !== null && "error" in failure && typeof failure.error === "string") {
    return failure.error;
  }
  const message = failure instanceof Error ? failure.message : "";
  if (/native messaging host not found|forbidden/i.test(message)) {
    return "Paper Plane isn't set up for this browser yet. Open Paper Plane once, then try again.";
  }
  return "Couldn't reach Paper Plane. Try again.";
}
