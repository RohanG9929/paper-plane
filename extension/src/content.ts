// Runs in every frame (spec §5.1): reports the frame's <video> elements to the service worker, and
// pauses them once Paper Plane has the video. It takes orders only from the extension, never from
// the page.
import { describeVideo } from "./videos";

declare global {
  var paperPlaneReporting: boolean | undefined;
}

// Installing the extension adds this script to open tabs, where it may already be running.
if (!globalThis.paperPlaneReporting) {
  globalThis.paperPlaneReporting = true;

  const videos = () => Array.from(document.querySelectorAll("video"), describeVideo);
  let pending: ReturnType<typeof setTimeout> | undefined;
  const report = () => {
    clearTimeout(pending);
    pending = setTimeout(() => {
      chrome.runtime.sendMessage({ type: "videos", videos: videos() }).catch(() => undefined);
    }, 300);
  };
  // Media events don't bubble, but they do pass through the document on the way down, so frames
  // without a video never report at all.
  for (const event of ["play", "playing", "pause", "ended", "loadedmetadata", "durationchange", "emptied"]) {
    document.addEventListener(event, report, true);
  }
  if (document.querySelector("video")) {
    report();
  }

  chrome.runtime.onMessage.addListener((message: unknown, sender, reply) => {
    if (sender.id !== chrome.runtime.id || typeof message !== "object" || message === null || !("type" in message)) {
      return false;
    }
    if (message.type === "pause") {
      for (const video of document.querySelectorAll("video")) {
        video.pause();
      }
      reply(true);
    } else if (message.type === "time") {
      const list = videos();
      reply((list.find((video) => video.playing) ?? list[0])?.currentTime);
    }
    return false;
  });
}
