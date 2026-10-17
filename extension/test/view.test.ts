import { describe, expect, it } from "vitest";
import { newTab } from "../src/tabs";
import { button, plan, popupState, rows, sendTarget } from "../src/view";
import { aDashSite, newsSiteWithAnAd, replay, twoPlayers } from "./fixtures";

describe("the toolbar button", () => {
  it("stays grey with nothing found, and only its popup offers to try the page", () => {
    const empty = plan(newTab(), "https://news.example/", 0);
    expect(empty).toEqual({ kind: "offer-page" });
    const view = button(newTab(), empty, false);
    expect(view).toEqual({ icon: "idle", badge: "", popup: true, title: "Paper Plane: no video found — try this page?" });
    expect(view.icon).not.toBe("ready"); // lit only for a video that was found, never for a guess
    expect(popupState(newTab(), empty)).toEqual({
      plan: "offer-page", rows: [{ label: "Try this page", detail: "Paper Plane will ask the site for a video" }],
    });
  });

  it.each([
    "about:blank", "chrome://extensions/", "chrome-extension://abcdefgh/popup.html", "file:///Users/me/film.mp4",
    "ftp://files.example/film.mp4", "not a url", "",
  ])("has nothing to offer on %s, which isn't on the web", (address) => {
    const empty = plan(newTab(), address, 0);
    expect(empty).toEqual({ kind: "none" });
    expect(button(newTab(), empty, false)).toEqual({ icon: "idle", badge: "", popup: true, title: "Paper Plane: no video found yet" });
    expect(popupState(newTab(), empty)).toEqual({ plan: "none", rows: [] });
  });

  it("has nothing to offer on a tab with no address", () => {
    expect(plan(newTab(), undefined, 0)).toEqual({ kind: "none" });
  });

  it("keeps its offer of the page after a failed try, with the reason", () => {
    const failed = { ...newTab(), error: "Paper Plane didn't find a video at this link." };
    const offer = plan(failed, "http://news.example/", 0);
    expect(offer).toEqual({ kind: "offer-page" });
    expect(button(failed, offer, false)).toEqual({
      icon: "idle", badge: "!", popup: true, title: "Paper Plane: Paper Plane didn't find a video at this link.",
    });
    expect(popupState(failed, offer)).toMatchObject({ plan: "offer-page", error: "Paper Plane didn't find a video at this link." });
  });

  it("sends at a click when one video is the clear choice", () => {
    const tab = replay(newsSiteWithAnAd.responses, newsSiteWithAnAd.videos);
    const sure = plan(tab, "https://www.news.example/story", newsSiteWithAnAd.now);
    expect(sure.kind).toBe("send");
    expect(button(tab, sure, false)).toEqual({ icon: "ready", badge: "", popup: false, title: "Send this video to your TV with Paper Plane" });
  });

  it("counts the choices and offers them in the popup when unsure", () => {
    const tab = replay(twoPlayers.responses, twoPlayers.videos);
    const unsure = plan(tab, "https://two.example/", twoPlayers.now);
    expect(unsure.kind).toBe("choose");
    expect(button(tab, unsure, false)).toEqual({ icon: "ready", badge: "2", popup: true, title: "Paper Plane: choose a video" });
  });

  it("sends a YouTube video's page even before anything else is found", () => {
    expect(plan(newTab(), "https://www.youtube.com/watch?v=abc", 0)).toEqual({ kind: "send", target: { kind: "page" } });
  });

  it("sends a sniffed DASH stream at a click, like HLS", () => {
    const tab = replay(aDashSite.responses, aDashSite.videos);
    const sure = plan(tab, "https://dash.example/watch", aDashSite.now);
    expect(sure.kind).toBe("send");
    expect(sure.kind === "send" && sure.target.kind === "stream" && sure.target.candidate.format).toBe("dash");
    expect(button(tab, sure, false)).toEqual({ icon: "ready", badge: "", popup: false, title: "Send this video to your TV with Paper Plane" });
    expect(popupState(tab, sure).rows).toEqual([{
      key: "https://dash.example/content/abc/manifest.mpd", label: "DASH stream · dash.example", detail: "manifest.mpd · Playing · 20:00",
    }]);
  });

  it("shows sending, and a failure until the next try", () => {
    const tab = replay(newsSiteWithAnAd.responses, newsSiteWithAnAd.videos);
    const sure = plan(tab, "https://www.news.example/story", newsSiteWithAnAd.now);
    expect(button(tab, sure, true)).toMatchObject({ badge: "…", popup: false });
    expect(button({ ...tab, error: "Couldn't reach Paper Plane. Try again." }, sure, false))
      .toEqual({ icon: "ready", badge: "!", popup: true, title: "Paper Plane: Couldn't reach Paper Plane. Try again." });
  });
});

describe("the popup's choices", () => {
  it("say what each one is and where it comes from", () => {
    const tab = replay(newsSiteWithAnAd.responses, newsSiteWithAnAd.videos);
    const ranked = plan(tab, "https://www.news.example/story", newsSiteWithAnAd.now);
    expect(ranked.kind).toBe("send");
    expect(rows(tab.candidates.filter((c) => !c.variantOf), tab.videos)).toEqual([
      { key: "https://ads.example/creative/preroll-15s.mp4", label: "Video file · ads.example",
        detail: "preroll-15s.mp4 · 0:15" },
      { key: "https://video.news.example/hls/story/master.m3u8", label: "HLS stream · video.news.example",
        detail: "master.m3u8 · Playing · 3:04" },
    ]);
  });

  it("offer a YouTube video as itself", () => {
    const youtube = plan(newTab(), "https://www.youtube.com/watch?v=abc", 0);
    expect(popupState(newTab(), youtube)).toEqual({
      plan: "send", rows: [{ label: "This YouTube video", detail: "Paper Plane gets it from YouTube" }],
    });
    const failed = { ...newTab(), error: "Couldn't reach Paper Plane. Try again." };
    expect(popupState(failed, { kind: "none" })).toEqual({ plan: "none", rows: [], error: "Couldn't reach Paper Plane. Try again." });
  });
});

describe("what the popup sends", () => {
  const stream = replay(newsSiteWithAnAd.responses, newsSiteWithAnAd.videos);
  const streamKey = "https://video.news.example/hls/story/master.m3u8";

  it("is the page itself for the row that has no key, on any web page with nothing found", () => {
    expect(sendTarget(newTab(), plan(newTab(), "https://news.example/", 0), undefined)).toEqual({ kind: "page" });
    expect(sendTarget(newTab(), plan(newTab(), "http://videos.example/watch?id=1", 0), undefined)).toEqual({ kind: "page" });
    expect(sendTarget(newTab(), plan(newTab(), "https://www.youtube.com/watch?v=abc", 0), undefined)).toEqual({ kind: "page" });
  });

  it("is nothing on a page that isn't on the web", () => {
    expect(sendTarget(newTab(), plan(newTab(), "about:blank", 0), undefined)).toBeUndefined();
    expect(sendTarget(newTab(), plan(newTab(), undefined, 0), undefined)).toBeUndefined();
  });

  it("is the stream a row's key names", () => {
    const target = sendTarget(stream, plan(stream, "https://www.news.example/story", newsSiteWithAnAd.now), streamKey);
    expect(target).toMatchObject({ kind: "stream", candidate: { key: streamKey } });
  });

  it("doesn't turn a stale choice into sending the page", () => {
    // The popup showed a stream that the tab has since forgotten: say so, rather than try the page.
    expect(sendTarget(newTab(), plan(newTab(), "https://news.example/", 0), streamKey)).toBeUndefined();
  });
});
