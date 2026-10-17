import { describe, expect, it } from "vitest";
import { maximumCandidates, navigated, newTab, observe, pickHeaders, withVideos } from "../src/tabs";
import { replay, seen, segments } from "./fixtures";

describe("tab state", () => {
  it("keeps only the headers a site needs to hand over the video", () => {
    expect(pickHeaders([
      { name: "cookie", value: "session=1" },
      { name: "Referer", value: "https://site.example/watch" },
      { name: "Origin", value: "https://site.example" },
      { name: "User-Agent", value: "Mozilla/5.0" },
      { name: "X-Client-Data", value: "abc" },
      { name: "Accept" },
    ])).toEqual({ Cookie: "session=1", Referer: "https://site.example/watch", Origin: "https://site.example", "User-Agent": "Mozilla/5.0" });
  });

  it("keeps a token-authed stream's Authorization, whatever its case, and still drops the rest", () => {
    expect(pickHeaders([
      { name: "authorization", value: "Bearer abc" },
      { name: "X-Client-Data", value: "abc" },
      { name: "Proxy-Authorization", value: "Basic xyz" },
      { name: "Authorization" },
    ])).toEqual({ Authorization: "Bearer abc" });
    expect(pickHeaders([{ name: "AUTHORIZATION", value: "Bearer abc" }])).toEqual({ Authorization: "Bearer abc" });
  });

  it("follows a playlist whose link changes, keeping the newest link and headers", () => {
    const tab = replay([
      seen("https://cdn.example/v/index.m3u8?token=old", 0, { headers: { Cookie: "a=1" } }),
      seen("https://cdn.example/v/index.m3u8?token=new", 6000, { headers: { Cookie: "a=2" } }),
    ]);
    expect(tab.candidates).toHaveLength(1);
    expect(tab.candidates[0]).toMatchObject({ url: "https://cdn.example/v/index.m3u8?token=new", headers: { Cookie: "a=2" }, lastActivity: 6000 });
  });

  it("keeps the headers it has when a repeat's weren't captured (the worker was restarted)", () => {
    const tab = replay([
      seen("https://cdn.example/v/index.m3u8", 0, { headers: { Cookie: "a=1" } }),
      seen("https://cdn.example/v/index.m3u8", 6000, { headers: {} }),
    ]);
    expect(tab.candidates[0]?.headers).toEqual({ Cookie: "a=1" });
  });

  it("credits a segment only to a stream on its own host", () => {
    const tab = replay([
      seen("https://a.example/v/index.m3u8", 0),
      seen("https://b.example/v/index.m3u8", 100),
      seen("https://b.example/v/s1.ts", 2000, { contentType: "video/mp2t" }),
    ]);
    expect(tab.candidates.map((c) => [c.url, c.lastActivity])).toEqual([
      ["https://a.example/v/index.m3u8", undefined],
      ["https://b.example/v/index.m3u8", 2000],
    ]);
  });

  it("keeps a candidate's headers, and nothing from requests that aren't video", () => {
    const tab = replay([
      seen("https://example.com/api/me", 0, { contentType: "application/json", headers: { Cookie: "secret=1" } }),
      seen("https://cdn.example/v/index.m3u8", 10, { headers: { Cookie: "cdn=1" } }),
    ]);
    expect(JSON.stringify(tab)).not.toContain("secret=1");
    expect(tab.candidates[0]?.headers).toEqual({ Cookie: "cdn=1" });
  });

  it("keeps the most recently active candidates when there are too many", () => {
    const film = [seen("https://film.example/v/master.m3u8", 0), ...segments("https://film.example/v/s", 500, 40)];
    const ads = Array.from({ length: maximumCandidates + 5 }, (_, index) =>
      seen(`https://cdn${index}.example/ad.mp4`, 1000 + index * 1000, { type: "media", contentType: "video/mp4" }));
    const tab = replay([...film.slice(0, 2), ...ads, ...film.slice(2)].sort((a, b) => a.timeStamp - b.timeStamp));
    expect(tab.candidates).toHaveLength(maximumCandidates);
    expect(tab.candidates.some((c) => c.url === "https://film.example/v/master.m3u8")).toBe(true); // it's playing
  });

  it("links a variant fetched long after its master (a change of quality) by its folder", () => {
    const tab = replay([
      seen("https://cdn.example/hls/film/master.m3u8", 0),
      seen("https://cdn.example/hls/film/360p/index.m3u8", 200),
      seen("https://cdn.example/hls/film/1080p/index.m3u8", 60000),
      seen("https://cdn.example/hls/other/master.m3u8", 61000),
    ]);
    expect(tab.candidates.filter((c) => c.variantOf === undefined).map((c) => c.url)).toEqual([
      "https://cdn.example/hls/film/master.m3u8",
      "https://cdn.example/hls/other/master.m3u8", // another video's: a folder of its own
    ]);
  });

  it("counts a stream's own .mp4 pieces as segments, even fetched by the video element (native HLS)", () => {
    const tab = replay([
      seen("https://cdn.example/v/master.m3u8", 0, { type: "media" }),
      seen("https://cdn.example/v/seg_001.mp4", 500, { type: "media", contentType: "video/mp4" }),
      seen("https://cdn.example/v/seg_002.mp4", 9000, { type: "media", contentType: "video/mp4" }),
    ]);
    expect(tab.candidates.map((c) => c.url)).toEqual(["https://cdn.example/v/master.m3u8"]);
    expect(tab.candidates[0]?.lastActivity).toBe(9000);
  });

  it("offers a sniffed DASH manifest as a candidate, like HLS", () => {
    const tab = replay([seen("https://dash.example/v/manifest.mpd", 0, { contentType: "application/dash+xml" })]);
    expect(tab.candidates.map((c) => [c.url, c.format])).toEqual([["https://dash.example/v/manifest.mpd", "dash"]]);
  });

  it("leaves the state as it was when nothing changed, so nothing is saved or redrawn", () => {
    const tab = replay([seen("https://cdn.example/v/index.m3u8", 0), seen("https://cdn.example/v/s1.ts", 1000)]);
    expect(observe(tab, seen("https://elsewhere.example/x.ts", 1500))).toBe(tab); // nobody's segment
    expect(observe(tab, seen("https://cdn.example/v/s2.ts", 3000))).toBe(tab); // active a moment ago
    expect(observe(tab, seen("https://cdn.example/v/s3.ts", 7000))).not.toBe(tab);
    const playing = withVideos(tab, 1, [{ src: "a", playing: true, currentTime: 1, duration: 10 }]);
    expect(withVideos(playing, 1, [{ src: "a", playing: true, currentTime: 5, duration: 10 }])).toBe(playing);
  });

  it("replaces one frame's videos and leaves the others", () => {
    let tab = withVideos(newTab(), 1, [{ src: "a", playing: true, currentTime: 1, duration: 10 }]);
    tab = withVideos(tab, 2, [{ src: "b", playing: false, currentTime: 0, duration: 20 }]);
    tab = withVideos(tab, 1, []);
    expect(tab.videos).toEqual([{ frameId: 2, src: "b", playing: false, currentTime: 0, duration: 20 }]);
  });

  it("forgets everything on a new page, and keeps a YouTube page's cookie for later", () => {
    const youtube = navigated("https://www.youtube.com/watch?v=abc", { Cookie: "SID=1", Referer: "https://google.com/", "User-Agent": "UA" });
    expect(youtube).toEqual({ candidates: [], videos: [], pageHeaders: { Cookie: "SID=1", "User-Agent": "UA" } });
    // YouTube's home page too: its videos open without loading a new page.
    expect(navigated("https://www.youtube.com/", { Cookie: "SID=1" }).pageHeaders).toEqual({ Cookie: "SID=1" });
    expect(navigated("https://news.example/story", { Cookie: "x=1" })).toEqual({ candidates: [], videos: [] });
  });

  it("ignores links it can't read", () => {
    expect(observe(newTab(), seen("not a url.m3u8", 0))).toEqual(newTab());
  });
});
