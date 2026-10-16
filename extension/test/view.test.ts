import { describe, expect, it } from "vitest";
import { newTab } from "../src/tabs";
import { button, plan, popupState, rows } from "../src/view";
import { newsSiteWithAnAd, replay, twoPlayers } from "./fixtures";

describe("the toolbar button", () => {
  it("is grey with nothing found, and its popup says what to do", () => {
    const empty = plan(newTab(), "https://news.example/", 0);
    expect(empty).toEqual({ kind: "none" });
    expect(button(newTab(), empty, false)).toEqual({ icon: "idle", badge: "", popup: true, title: "Paper Plane: no video found yet" });
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
