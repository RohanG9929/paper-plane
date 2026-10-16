import { describe, expect, it } from "vitest";
import { describeVideo, videosFrom } from "../src/videos";

describe("videos", () => {
  it("are described by their source, whether they play, and their times", () => {
    expect(describeVideo({ currentSrc: "blob:https://site.example/1", src: "", paused: false, ended: false, currentTime: 12.5, duration: Number.POSITIVE_INFINITY }))
      .toEqual({ src: "blob:https://site.example/1", playing: true, currentTime: 12.5, duration: 0 });
    expect(describeVideo({ currentSrc: "", src: "https://media.example/a.mp4", paused: true, ended: false, currentTime: Number.NaN, duration: 30 }))
      .toEqual({ src: "https://media.example/a.mp4", playing: false, currentTime: 0, duration: 30 });
  });

  it("from a content script are checked, never trusted beyond their shape", () => {
    const good = { src: "https://media.example/a.mp4", playing: true, currentTime: 3, duration: 30 };
    expect(videosFrom([good, { src: 1 }, null, "x", { ...good, currentTime: -5, duration: "long" }])).toEqual([
      good,
      { src: "https://media.example/a.mp4", playing: true, currentTime: 0, duration: 0 },
    ]);
    expect(videosFrom("nonsense")).toEqual([]);
    expect(videosFrom(Array.from({ length: 50 }, () => good))).toHaveLength(20);
    expect(videosFrom([{ ...good, src: "x".repeat(5000) }])[0]?.src).toHaveLength(2048);
  });
});
