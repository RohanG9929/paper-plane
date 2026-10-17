// What the toolbar button and its popup show (spec §5.1): grey with nothing found, a click to
// send when one video is the clear choice, a count and a chooser when it isn't. With nothing
// found on a web page the button stays grey, but its popup offers to try the page itself.
import { choose, videosOf, type Candidate, type FrameVideo } from "./detector";
import { isWebPage, isYouTubeVideo } from "./message";
import type { TabState } from "./tabs";

export type Target = { kind: "page" } | { kind: "stream"; candidate: Candidate };

export type Plan =
  | { kind: "none" }
  /** Nothing was found on this web page, but the popup can ask Paper Plane to try the page. */
  | { kind: "offer-page" }
  | { kind: "send"; target: Target }
  | { kind: "choose"; ranked: Candidate[] };

export interface ButtonView {
  icon: "idle" | "ready";
  badge: string;
  /** Whether a click opens the popup; otherwise it sends. */
  popup: boolean;
  title: string;
}

export interface Row {
  /** The stream's key; none for the page itself (a YouTube video's, or one to try). */
  key?: string;
  label: string;
  detail: string;
}

/** What the popup shows: why sending failed, if it did, and the choices. */
export interface PopupState {
  plan: Plan["kind"];
  error?: string;
  rows: Row[];
}

/** The worker's answer to the popup's request to send. */
export type SendResult = { ok: true } | { error: string };

export function plan(tab: TabState, pageUrl: string | undefined, now: number): Plan {
  if (pageUrl && isYouTubeVideo(pageUrl)) {
    return { kind: "send", target: { kind: "page" } };
  }
  const choice = choose(tab.candidates, tab.videos, now);
  switch (choice.kind) {
    case "none": return isWebPage(pageUrl ?? "") ? { kind: "offer-page" } : { kind: "none" };
    case "one": return { kind: "send", target: { kind: "stream", candidate: choice.candidate } };
    case "several": return { kind: "choose", ranked: choice.ranked };
  }
}

export function button(tab: TabState, plan: Plan, sending: boolean): ButtonView {
  // Lit only for a video that was found: offering to try a page is no promise it has one.
  const icon = plan.kind === "none" || plan.kind === "offer-page" ? "idle" : "ready";
  if (sending) {
    return { icon, badge: "…", popup: false, title: "Sending to Paper Plane…" };
  }
  if (tab.error) {
    return { icon, badge: "!", popup: true, title: `Paper Plane: ${tab.error}` };
  }
  switch (plan.kind) {
    case "none": return { icon, badge: "", popup: true, title: "Paper Plane: no video found yet" };
    case "offer-page": return { icon, badge: "", popup: true, title: "Paper Plane: no video found — try this page?" };
    case "send": return { icon, badge: "", popup: false, title: "Send this video to your TV with Paper Plane" };
    case "choose": return { icon, badge: String(plan.ranked.length), popup: true, title: "Paper Plane: choose a video" };
  }
}

export function popupState(tab: TabState, plan: Plan): PopupState {
  let offered: Row[] = [];
  if (plan.kind === "choose") {
    offered = rows(plan.ranked, tab.videos);
  } else if (plan.kind === "offer-page") {
    offered = [{ label: "Try this page", detail: "Paper Plane will ask the site for a video" }];
  } else if (plan.kind === "send") {
    offered = plan.target.kind === "page"
      ? [{ label: "This YouTube video", detail: "Paper Plane gets it from YouTube" }]
      : rows([plan.target.candidate], tab.videos);
  }
  return { plan: plan.kind, rows: offered, ...(tab.error ? { error: tab.error } : {}) };
}

/** What a popup send is for: the stream a row's `key` names, else what the plan sends, else, for
 *  the row with no key, the page itself, which a page offered to try is. A stale key (the tab has
 *  moved on) never turns into sending the page the popup merely offered to try. */
export function sendTarget(tab: TabState, plan: Plan, key: unknown): Target | undefined {
  if (typeof key === "string") {
    const candidate = tab.candidates.find((found) => found.key === key && found.variantOf === undefined);
    if (candidate) {
      return { kind: "stream", candidate };
    }
  }
  if (plan.kind === "send") {
    return plan.target;
  }
  return plan.kind === "offer-page" && typeof key !== "string" ? { kind: "page" } : undefined;
}

const formatNames = { hls: "HLS stream", dash: "DASH stream", progressive: "Video file" } as const;

/** The popup's choices: what each is, where it's from, its file's name, and whether it's
 *  playing and how long. */
export function rows(candidates: Candidate[], videos: FrameVideo[]): Row[] {
  return candidates.map((candidate) => {
    const url = new URL(candidate.url);
    const related = videosOf(candidate, videos);
    const parts = [url.pathname.slice(url.pathname.lastIndexOf("/") + 1) || url.hostname];
    if (related.some((video) => video.playing)) {
      parts.push("Playing");
    }
    const duration = Math.max(0, ...related.map((video) => video.duration));
    if (duration > 0) {
      parts.push(clock(duration));
    }
    return { key: candidate.key, label: `${formatNames[candidate.format]} · ${url.hostname}`, detail: parts.join(" · ") };
  });
}

/** "0:15", "3:04", "1:52:10". */
export function clock(seconds: number): string {
  const total = Math.floor(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor(total / 60) % 60;
  const secs = String(total % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${secs}` : `${minutes}:${secs}`;
}
