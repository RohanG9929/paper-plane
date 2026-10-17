// The play request sent to Paper Plane through its helper (spec §5.2, message v1).
import { videosInFrame, type Candidate, type FrameVideo } from "./detector";
import type { Format } from "./classify";
import { primaryVideo, seconds } from "./videos";

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

function playMessage(source: PlayMessage["source"], page: Page, startAt: number): PlayMessage {
  return { type: "play", v: 1, source, pageUrl: page.url, title: tidyTitle(page.title), startAt };
}

export function streamMessage(candidate: Candidate, page: Page, startAt: number): PlayMessage {
  return playMessage({ kind: "stream", url: candidate.url, format: candidate.format, headers: candidate.headers }, page, startAt);
}

/** The page itself, for yt-dlp in the app: a YouTube video's, with the site's cookie (spec §5.1),
 *  or any other web page the user asked to try, which sends none. */
export function pageMessage(page: Page, headers: Record<string, string>, startAt: number): PlayMessage {
  return playMessage({ kind: "page", url: page.url, headers }, page, startAt);
}

function parse(url: string): URL | undefined {
  try {
    return new URL(url);
  } catch {
    return undefined;
  }
}

/** A page on the web: `http` or `https`, the only kinds a site can be asked about. */
export function isWebPage(url: string): boolean {
  const protocol = parse(url)?.protocol;
  return protocol === "http:" || protocol === "https:";
}

/** Any page on YouTube. */
export function isYouTube(url: string): boolean {
  const host = parse(url)?.hostname;
  return host === "youtu.be" || host === "youtube.com" || host?.endsWith(".youtube.com") === true;
}

/** A YouTube video's page: a watch, Shorts or live page, or a youtu.be link. */
export function isYouTubeVideo(url: string): boolean {
  const parsed = parse(url);
  if (!parsed || !isYouTube(url)) {
    return false;
  }
  if (parsed.hostname === "youtu.be") {
    return parsed.pathname.length > 1;
  }
  return (parsed.pathname === "/watch" && parsed.searchParams.has("v")) || /^\/(shorts|live)\/[^/]+/.test(parsed.pathname);
}

/** Where the browser's video is: the playing one in `frameId` (any frame for -1), else its
 *  first video, in seconds. */
export function startTime(videos: FrameVideo[], frameId: number): number {
  return seconds(primaryVideo(videosInFrame(videos, frameId))?.currentTime);
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
  // Not installed, forbidden, or installed where the app no longer is.
  if (/native messaging host not found|forbidden|failed to start native messaging host/i.test(message)) {
    return "Paper Plane isn't set up for this browser yet. Open Paper Plane once, then try again.";
  }
  return "Couldn't reach Paper Plane. Try again.";
}
