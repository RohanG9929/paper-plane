// StreamDetector (spec §5.1): ranks a tab's streams to find the one the user is watching.
import type { Format } from "./classify";

/** A stream found in a tab. */
export interface Candidate {
  /** Origin and path: the same stream when its link's token changes. */
  key: string;
  /** The newest link to it. */
  url: string;
  format: Format;
  /** The frame that fetched it; -1 for a worker's request. */
  frameId: number;
  /** Cookie, Referer, Origin, User-Agent and Authorization from its request, for Paper Plane to send too. */
  headers: Record<string, string>;
  firstSeen: number;
  lastSeen: number;
  /** When a segment, or a repeat of its own request, last showed it playing. */
  lastActivity?: number;
  /** A variant playlist's master, which is offered in its place. */
  variantOf?: string;
}

/** A <video> element, as the content script reports it. */
export interface FrameVideo {
  frameId: number;
  /** Its src: http(s) for a file, blob: for a player's stream. */
  src: string;
  playing: boolean;
  currentTime: number;
  /** Seconds; 0 when unknown. */
  duration: number;
}

/** The ranking criteria in the spec's order, each outweighing all those after it together. */
export const weights = { playing: 16, activity: 8, master: 4, videoSrc: 2, long: 1 } as const;
/** Segments within this long count as ongoing activity. */
export const activityWindow = 15_000;
/** Shorter videos are more likely ads. */
export const longVideo = 60;

export function keyOf(url: string): string {
  const parsed = new URL(url);
  return parsed.origin + parsed.pathname;
}

/** An HLS playlist that isn't one of another's variants: the master, which lists them all. */
export function isMaster(candidate: Candidate): boolean {
  return candidate.format === "hls" && candidate.variantOf === undefined;
}

/** The videos of a frame; any frame's for -1, a worker's request. */
export function videosInFrame<V extends { frameId: number }>(videos: V[], frameId: number): V[] {
  return videos.filter((video) => frameId < 0 || video.frameId === frameId);
}

function isPlayedBy(candidate: Candidate, video: FrameVideo): boolean {
  if (!video.src.startsWith("http")) {
    return false;
  }
  try {
    return keyOf(video.src) === candidate.key;
  } catch {
    return false;
  }
}

/** The videos that are the candidate's: the one playing its file, else those of its frame. */
export function videosOf(candidate: Candidate, videos: FrameVideo[]): FrameVideo[] {
  const playing = videos.filter((video) => isPlayedBy(candidate, video));
  return playing.length > 0 ? playing : videosInFrame(videos, candidate.frameId);
}

export function score(candidate: Candidate, videos: FrameVideo[], now: number): number {
  let total = 0;
  if (videosInFrame(videos, candidate.frameId).some((video) => video.playing)) {
    total += weights.playing;
  }
  if (candidate.lastActivity !== undefined && now - candidate.lastActivity <= activityWindow) {
    total += weights.activity;
  }
  if (isMaster(candidate)) {
    total += weights.master;
  }
  if (videos.some((video) => isPlayedBy(candidate, video))) {
    total += weights.videoSrc;
  }
  if (videosOf(candidate, videos).some((video) => video.duration >= longVideo)) {
    total += weights.long;
  }
  return total;
}

/** The streams worth offering with their scores, best first; the most recently seen first
 *  among equals. */
function scored(candidates: Candidate[], videos: FrameVideo[], now: number) {
  return candidates
    .filter((candidate) => candidate.variantOf === undefined)
    .map((candidate) => ({ candidate, score: score(candidate, videos, now) }))
    .sort((a, b) => b.score - a.score || b.candidate.lastSeen - a.candidate.lastSeen);
}

export function rank(candidates: Candidate[], videos: FrameVideo[], now: number): Candidate[] {
  return scored(candidates, videos, now).map(({ candidate }) => candidate);
}

export type Choice =
  | { kind: "none" }
  | { kind: "one"; candidate: Candidate }
  | { kind: "several"; ranked: Candidate[] };

/** One stream when the best beats the next by at least one criterion; otherwise the user picks. */
export function choose(candidates: Candidate[], videos: FrameVideo[], now: number): Choice {
  const list = scored(candidates, videos, now);
  const [best, next] = list;
  if (!best) {
    return { kind: "none" };
  }
  if (!next || best.score > next.score) {
    return { kind: "one", candidate: best.candidate };
  }
  return { kind: "several", ranked: list.map(({ candidate }) => candidate) };
}
