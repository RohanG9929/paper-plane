// A frame's <video> elements, as the content script reports them to the service worker.
import type { FrameVideo } from "./detector";

export type Video = Omit<FrameVideo, "frameId">;

/** The parts of an HTMLVideoElement the report needs. */
export interface VideoElement {
  currentSrc: string;
  src: string;
  paused: boolean;
  ended: boolean;
  currentTime: number;
  duration: number;
}

const maximumVideos = 20;
const maximumSource = 2048;

function seconds(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0;
}

export function describeVideo(video: VideoElement): Video {
  return {
    src: (video.currentSrc || video.src).slice(0, maximumSource),
    playing: !video.paused && !video.ended,
    currentTime: seconds(video.currentTime),
    duration: seconds(video.duration),
  };
}

/** What a content script sent, kept only if it has the right shape, within limits. */
export function videosFrom(raw: unknown): Video[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw
    .filter((item): item is Record<string, unknown> =>
      typeof item === "object" && item !== null && typeof item.src === "string" && typeof item.playing === "boolean")
    .slice(0, maximumVideos)
    .map((item) => ({
      src: (item.src as string).slice(0, maximumSource),
      playing: item.playing as boolean,
      currentTime: seconds(item.currentTime),
      duration: seconds(item.duration),
    }));
}
