// What the toolbar button and its popup show (spec §5.1): grey with nothing found, a click to
// send when one video is the clear choice, a count and a chooser when it isn't.
import { choose, type Candidate, type FrameVideo } from "./detector";
import { isYouTubeVideo } from "./message";
import type { TabState } from "./tabs";

export type Target = { kind: "page" } | { kind: "stream"; candidate: Candidate };

export type Plan =
  | { kind: "none" }
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
  key: string;
  label: string;
  detail: string;
}

/** What the popup asks the service worker for when it opens. */
export interface PopupState {
  plan: Plan["kind"];
  /** A YouTube page, sent as the page. */
  youtube: boolean;
  error?: string;
  rows: Row[];
}

export function plan(tab: TabState, pageUrl: string | undefined, now: number): Plan {
  if (pageUrl && isYouTubeVideo(pageUrl)) {
    return { kind: "send", target: { kind: "page" } };
  }
  const choice = choose(tab.candidates, tab.videos, now);
  switch (choice.kind) {
    case "none": return { kind: "none" };
    case "one": return { kind: "send", target: { kind: "stream", candidate: choice.candidate } };
    case "several": return { kind: "choose", ranked: choice.ranked };
  }
}

export function button(tab: TabState, plan: Plan, sending: boolean): ButtonView {
  const icon = plan.kind === "none" ? "idle" : "ready";
  if (sending) {
    return { icon, badge: "…", popup: false, title: "Sending to Paper Plane…" };
  }
  if (tab.error) {
    return { icon, badge: "!", popup: true, title: `Paper Plane: ${tab.error}` };
  }
  switch (plan.kind) {
    case "none": return { icon, badge: "", popup: true, title: "Paper Plane: no video found yet" };
    case "send": return { icon, badge: "", popup: false, title: "Send this video to your TV with Paper Plane" };
    case "choose": return { icon, badge: String(plan.ranked.length), popup: true, title: "Paper Plane: choose a video" };
  }
}

const formatNames = { hls: "HLS stream", dash: "DASH stream", progressive: "Video file" } as const;

/** The popup's choices: what each is, where it's from, and whether it's playing and how long. */
export function rows(candidates: Candidate[], videos: FrameVideo[]): Row[] {
  return candidates.map((candidate) => {
    const own = videos.filter((video) => video.src.startsWith("http") && video.src.split(/[?#]/)[0] === candidate.key);
    const related = own.length > 0 ? own : videos.filter((video) => candidate.frameId < 0 || video.frameId === candidate.frameId);
    const parts: string[] = [];
    if (related.some((video) => video.playing)) {
      parts.push("Playing");
    }
    const duration = Math.max(0, ...related.map((video) => video.duration));
    if (duration > 0) {
      parts.push(clock(duration));
    }
    return {
      key: candidate.key,
      label: `${formatNames[candidate.format]} · ${new URL(candidate.url).hostname}`,
      detail: parts.join(" · ") || "Found on this page",
    };
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
