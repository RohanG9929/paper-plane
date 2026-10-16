import { describe, expect, it } from "vitest";
import { choose, rank, score, weights } from "../src/detector";
import { aDashSite, aVideoFile, backgroundLoopAndAFilm, newsSiteWithAnAd, replay, seen, segments, twoPlayers } from "./fixtures";

function chosen(fixture: { responses: Parameters<typeof replay>[0]; videos: Parameters<typeof replay>[1]; now: number }) {
  const tab = replay(fixture.responses, fixture.videos);
  return choose(tab.candidates, tab.videos, fixture.now);
}

describe("StreamDetector", () => {
  it("prefers the story's stream over the ad that played before it", () => {
    const choice = chosen(newsSiteWithAnAd);
    expect(choice.kind).toBe("one");
    expect(choice.kind === "one" && choice.candidate.url).toBe("https://video.news.example/hls/story/master.m3u8");
  });

  it("offers the master playlist, not its variants", () => {
    const tab = replay(newsSiteWithAnAd.responses, newsSiteWithAnAd.videos);
    expect(rank(tab.candidates, tab.videos, newsSiteWithAnAd.now).map((c) => c.url)).toEqual([
      "https://video.news.example/hls/story/master.m3u8",
      "https://ads.example/creative/preroll-15s.mp4",
    ]);
  });

  it("prefers the film over a short background loop", () => {
    const choice = chosen(backgroundLoopAndAFilm);
    expect(choice.kind === "one" && choice.candidate.url).toBe("https://player.example/v/9876/hls.m3u8");
  });

  it("finds a plain video file", () => {
    const choice = chosen(aVideoFile);
    expect(choice.kind === "one" && choice.candidate.format).toBe("progressive");
  });

  it("finds DASH, with its segments counting as activity", () => {
    const choice = chosen(aDashSite);
    expect(choice.kind === "one" && choice.candidate.format).toBe("dash");
    const tab = replay(aDashSite.responses, aDashSite.videos);
    expect(tab.candidates).toHaveLength(1);
  });

  it("asks when two players are equally likely", () => {
    const choice = chosen(twoPlayers);
    expect(choice.kind).toBe("several");
    expect(choice.kind === "several" && choice.ranked).toHaveLength(2);
  });

  it("finds nothing among API calls, images and refused requests", () => {
    const tab = replay([
      seen("https://example.com/api/feed", 100, { contentType: "application/json" }),
      seen("https://example.com/img/logo.png", 120, { type: "other", contentType: "image/png" }),
      seen("https://cdn.example/v/master.m3u8", 140, { statusCode: 403 }),
    ]);
    expect(choose(tab.candidates, tab.videos, 1000)).toEqual({ kind: "none" });
  });

  it("weighs the criteria in the spec's order, each above all those after it", () => {
    const ordered = [weights.playing, weights.activity, weights.master, weights.videoSrc, weights.long];
    ordered.forEach((weight, index) => {
      const rest = ordered.slice(index + 1).reduce((sum, next) => sum + next, 0);
      expect(weight).toBeGreaterThan(rest);
    });
  });

  it("stops counting activity that has gone quiet", () => {
    const tab = replay([seen("https://cdn.example/v/index.m3u8", 0), ...segments("https://cdn.example/v/s", 500, 2)]);
    const candidate = tab.candidates[0]!;
    expect(score(candidate, [], 3000)).toBe(weights.activity + weights.master);
    expect(score(candidate, [], 60000)).toBe(weights.master);
  });

  it("credits a worker's requests (no frame) to whichever frame is playing", () => {
    const tab = replay([seen("https://cdn.example/v/index.m3u8", 0, { frameId: -1 })],
      { 4: [{ src: "blob:https://site.example/1", playing: true, currentTime: 1, duration: 90 }] });
    expect(score(tab.candidates[0]!, tab.videos, 1000)).toBe(weights.playing + weights.master + weights.long);
  });
});
