import { describe, expect, it } from "vitest";
import type { Candidate } from "../src/detector";
import { failureText, isWebPage, isYouTubeVideo, pageMessage, startTime, streamMessage, tidyTitle } from "../src/message";

const candidate: Candidate = {
  key: "https://cdn.example/v/master.m3u8", url: "https://cdn.example/v/master.m3u8?token=abc", format: "hls", frameId: 3,
  headers: { Cookie: "a=1", Referer: "https://site.example/watch" }, firstSeen: 0, lastSeen: 0,
};

describe("messages to Paper Plane", () => {
  it("are the spec's v1 play request for a stream", () => {
    expect(streamMessage(candidate, { url: "https://site.example/watch", title: "A film" }, 12.5)).toEqual({
      type: "play", v: 1,
      source: { kind: "stream", url: "https://cdn.example/v/master.m3u8?token=abc", format: "hls",
                headers: { Cookie: "a=1", Referer: "https://site.example/watch" } },
      pageUrl: "https://site.example/watch", title: "A film", startAt: 12.5,
    });
  });

  it("send a YouTube page as the page, with its cookie", () => {
    expect(pageMessage({ url: "https://www.youtube.com/watch?v=x", title: "Clip - YouTube" }, { Cookie: "SID=1" }, 3)).toEqual({
      type: "play", v: 1, source: { kind: "page", url: "https://www.youtube.com/watch?v=x", headers: { Cookie: "SID=1" } },
      pageUrl: "https://www.youtube.com/watch?v=x", title: "Clip", startAt: 3,
    });
  });

  it("send any other web page the same way, with no cookie unless it has one", () => {
    expect(pageMessage({ url: "https://videos.example/watch?id=7", title: "  A  film \n" }, {}, 0)).toEqual({
      type: "play", v: 1, source: { kind: "page", url: "https://videos.example/watch?id=7", headers: {} },
      pageUrl: "https://videos.example/watch?id=7", title: "A film", startAt: 0,
    });
  });

  it.each([
    ["https://news.example/story", true],
    ["http://videos.example/watch?id=7", true],
    ["HTTPS://VIDEOS.EXAMPLE/", true],
    ["about:blank", false],
    ["chrome://extensions/", false],
    ["chrome-extension://abcdefgh/popup.html", false],
    ["file:///Users/me/film.mp4", false],
    ["ftp://files.example/film.mp4", false],
    ["javascript:alert(1)", false],
    ["not a url", false],
    ["", false],
  ])("knows %s is on the web: %s", (url, expected) => {
    expect(isWebPage(url)).toBe(expected);
  });

  it.each([
    ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", true],
    ["https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=10", true],
    ["https://music.youtube.com/watch?v=abc", true],
    ["https://youtu.be/dQw4w9WgXcQ", true],
    ["https://www.youtube.com/shorts/abc123", true],
    ["https://www.youtube.com/live/abc123", true],
    ["https://www.youtube.com/", false],
    ["https://www.youtube.com/feed/subscriptions", false],
    ["https://www.youtube.com/watch", false],
    ["https://youtube.com.evil.example/watch?v=abc", false],
    ["https://notyoutube.com/watch?v=abc", false],
    ["not a url", false],
  ])("know %s is a YouTube video: %s", (url, expected) => {
    expect(isYouTubeVideo(url)).toBe(expected);
  });

  it("start where the browser's video is", () => {
    const videos = [
      { frameId: 3, src: "blob:x", playing: false, currentTime: 2, duration: 90 },
      { frameId: 3, src: "blob:y", playing: true, currentTime: 41.25, duration: 5400 },
      { frameId: 5, src: "blob:z", playing: true, currentTime: 900, duration: 5400 },
    ];
    expect(startTime(videos, 3)).toBe(41.25);
    expect(startTime(videos, -1)).toBe(41.25); // a worker's stream: the first playing video
    expect(startTime([{ frameId: 0, src: "", playing: true, currentTime: Number.NaN, duration: 0 }], 0)).toBe(0);
    expect(startTime([], 0)).toBe(0);
  });

  it("tidy titles", () => {
    expect(tidyTitle("  Clip\n name - YouTube ")).toBe("Clip name");
    expect(tidyTitle(undefined)).toBe("");
  });

  it("explain failures in plain words", () => {
    expect(failureText(new Error("Specified native messaging host not found.")))
      .toBe("Paper Plane isn't set up for this browser yet. Open Paper Plane once, then try again.");
    // The app was moved or deleted since it registered the helper.
    expect(failureText(new Error("Failed to start native messaging host.")))
      .toBe("Paper Plane isn't set up for this browser yet. Open Paper Plane once, then try again.");
    expect(failureText(new Error("Error when communicating with the native messaging host.")))
      .toBe("Couldn't reach Paper Plane. Try again.");
    expect(failureText({ ok: false, error: "The site stopped the stream — reload the page, then click Paper Plane again." }))
      .toBe("The site stopped the stream — reload the page, then click Paper Plane again.");
    expect(failureText(undefined)).toBe("Couldn't reach Paper Plane. Try again.");
  });
});
