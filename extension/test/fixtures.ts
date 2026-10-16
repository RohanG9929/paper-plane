// Request sequences shaped like real sites' (spec §7): what webRequest reports as a page plays,
// and what the content scripts report about each frame's videos.
import type { FrameVideo } from "../src/detector";
import { newTab, observe, withVideos, type Response, type TabState } from "../src/tabs";

/** A response webRequest reported at `at` milliseconds. */
export function seen(url: string, at: number, options: Partial<Response> = {}): Response {
  return { url, frameId: 0, type: "xmlhttprequest", timeStamp: at, statusCode: 200, headers: {}, ...options };
}

/** `count` segments named `<prefix>1.ts`, `<prefix>2.ts`, … two seconds apart from `from`. */
export function segments(prefix: string, from: number, count: number, options: Partial<Response> = {}): Response[] {
  return Array.from({ length: count }, (_, index) =>
    seen(`${prefix}${index + 1}.ts`, from + index * 2000, { contentType: "video/mp2t", ...options }));
}

export type Videos = Record<number, Omit<FrameVideo, "frameId">[]>;

export function replay(responses: Response[], videos: Videos = {}): TabState {
  let tab = responses.reduce(observe, newTab());
  for (const [frame, list] of Object.entries(videos)) {
    tab = withVideos(tab, Number(frame), list);
  }
  return tab;
}

/** A news article: a 15-second preroll ad as a file in an ad frame, then the story's video as
 *  HLS (a master, two variants, segments) in the player's frame. */
export const newsSiteWithAnAd = {
  responses: [
    seen("https://ads.example/creative/preroll-15s.mp4", 1000, { type: "media", frameId: 7, contentType: "video/mp4" }),
    seen("https://ads.example/creative/preroll-15s.mp4", 1500, { type: "media", frameId: 7, contentType: "video/mp4", statusCode: 206 }),
    seen("https://video.news.example/hls/story/master.m3u8", 17000, { frameId: 3, contentType: "application/vnd.apple.mpegurl" }),
    seen("https://video.news.example/hls/story/720p/index.m3u8", 17200, { frameId: 3 }),
    seen("https://video.news.example/hls/story/360p/index.m3u8", 17250, { frameId: 3 }),
    ...segments("https://video.news.example/hls/story/720p/seg", 17500, 20, { frameId: 3 }),
  ],
  videos: {
    7: [{ src: "https://ads.example/creative/preroll-15s.mp4", playing: false, currentTime: 15, duration: 15 }],
    3: [{ src: "blob:https://www.news.example/1f2e", playing: true, currentTime: 40, duration: 184 }],
  } satisfies Videos,
  now: 60000,
};

/** A landing page: a muted 8-second background loop as a file in the top frame, and the main
 *  video as HLS in an embedded player, both playing. */
export const backgroundLoopAndAFilm = {
  responses: [
    seen("https://www.studio.example/media/hero-loop.mp4", 500, { type: "media", contentType: "video/mp4" }),
    seen("https://www.studio.example/media/hero-loop.mp4", 8500, { type: "media", contentType: "video/mp4", statusCode: 206 }),
    seen("https://player.example/v/9876/hls.m3u8", 20000, { frameId: 2 }),
    ...segments("https://player.example/v/9876/s", 20500, 10, { frameId: 2 }),
    seen("https://www.studio.example/media/hero-loop.mp4", 39000, { type: "media", contentType: "video/mp4", statusCode: 206 }),
  ],
  videos: {
    0: [{ src: "https://www.studio.example/media/hero-loop.mp4", playing: true, currentTime: 3, duration: 8 }],
    2: [{ src: "blob:https://player.example/77", playing: true, currentTime: 18, duration: 5400 }],
  } satisfies Videos,
  now: 40000,
};

/** A plain video file the page's own <video> plays, fetched in ranges. */
export const aVideoFile = {
  responses: [
    seen("https://media.example/talks/keynote.mp4", 1000, { type: "media", contentType: "video/mp4", statusCode: 206 }),
    seen("https://media.example/talks/keynote.mp4", 9000, { type: "media", contentType: "video/mp4", statusCode: 206 }),
  ],
  videos: { 0: [{ src: "https://media.example/talks/keynote.mp4", playing: true, currentTime: 61.5, duration: 3600 }] } satisfies Videos,
  now: 10000,
};

/** DASH: a manifest, then audio and video segments. */
export const aDashSite = {
  responses: [
    seen("https://dash.example/content/abc/manifest.mpd", 1000, { contentType: "application/dash+xml" }),
    seen("https://dash.example/content/abc/video/init.mp4", 1200, { contentType: "video/mp4" }),
    seen("https://dash.example/content/abc/video/seg-1.m4s", 1400),
    seen("https://dash.example/content/abc/audio/seg-1.m4s", 1450),
  ],
  videos: { 0: [{ src: "blob:https://dash.example/12", playing: true, currentTime: 2, duration: 1200 }] } satisfies Videos,
  now: 5000,
};

/** Two players on one page, both playing: Paper Plane can't know which one is meant. */
export const twoPlayers = {
  responses: [
    seen("https://a.example/one/index.m3u8", 1000, { frameId: 1 }),
    ...segments("https://a.example/one/s", 1500, 3, { frameId: 1 }),
    seen("https://b.example/two/index.m3u8", 1200, { frameId: 2 }),
    ...segments("https://b.example/two/s", 1700, 3, { frameId: 2 }),
  ],
  videos: {
    1: [{ src: "blob:https://a.example/1", playing: true, currentTime: 5, duration: 600 }],
    2: [{ src: "blob:https://b.example/2", playing: true, currentTime: 5, duration: 600 }],
  } satisfies Videos,
  now: 8000,
};
