import { describe, expect, it } from "vitest";
import { maximumCandidates, navigated, newTab, observe, pickHeaders, withVideos } from "../src/tabs";
import { replay, seen } from "./fixtures";

describe("tab state", () => {
  it("keeps only the headers a site needs to hand over the video", () => {
    expect(pickHeaders([
      { name: "cookie", value: "session=1" },
      { name: "Referer", value: "https://site.example/watch" },
      { name: "Origin", value: "https://site.example" },
      { name: "User-Agent", value: "Mozilla/5.0" },
      { name: "Authorization", value: "Bearer secret" },
      { name: "X-Client-Data", value: "abc" },
      { name: "Accept" },
    ])).toEqual({ Cookie: "session=1", Referer: "https://site.example/watch", Origin: "https://site.example", "User-Agent": "Mozilla/5.0" });
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

  it("keeps the newest candidates when there are too many", () => {
    const tab = replay(Array.from({ length: maximumCandidates + 5 }, (_, index) =>
      seen(`https://cdn${index}.example/v.mp4`, index * 1000, { type: "media", contentType: "video/mp4" })));
    expect(tab.candidates).toHaveLength(maximumCandidates);
    expect(tab.candidates.some((c) => c.url === "https://cdn0.example/v.mp4")).toBe(false);
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
    expect(navigated("https://news.example/story", { Cookie: "x=1" })).toEqual({ candidates: [], videos: [] });
  });

  it("ignores links it can't read", () => {
    expect(observe(newTab(), seen("not a url.m3u8", 0))).toEqual(newTab());
  });
});
