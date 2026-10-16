import { describe, expect, it } from "vitest";
import { classify } from "../src/classify";

describe("classify", () => {
  it.each([
    ["https://cdn.example/v/master.m3u8?token=1", undefined, "xmlhttprequest", "hls"],
    ["https://cdn.example/v/playlist", "application/vnd.apple.mpegURL", "xmlhttprequest", "hls"],
    ["https://cdn.example/v/playlist", "application/x-mpegurl; charset=utf-8", "xmlhttprequest", "hls"],
    ["https://cdn.example/v/index.m3u8", "text/plain", "media", "hls"],
    ["https://cdn.example/v/manifest.mpd", undefined, "xmlhttprequest", "dash"],
    ["https://cdn.example/v/manifest", "application/dash+xml", "other", "dash"],
    ["https://media.example/film.mp4", "video/mp4", "media", "progressive"],
    ["https://media.example/film.webm", undefined, "media", "progressive"],
    ["https://media.example/clip.MOV", "application/octet-stream", "media", "progressive"],
    ["https://cdn.example/v/seg-001.ts", "video/mp2t", "xmlhttprequest", "segment"],
    ["https://cdn.example/v/chunk-5.m4s", undefined, "xmlhttprequest", "segment"],
    // A player fetching pieces of a video itself: a segment, not a video to send.
    ["https://cdn.example/v/video-720p-12.mp4", "video/mp4", "xmlhttprequest", "segment"],
    ["https://example.com/api/next", "application/json", "xmlhttprequest", undefined],
    ["https://example.com/logo.png", "image/png", "other", undefined],
    ["https://example.com/watch?file=film.mp4", "text/html", "xmlhttprequest", undefined],
  ] as const)("%s (%s, %s) is %s", (url, type, request, kind) => {
    expect(classify(url, type, request)).toBe(kind);
  });
});
