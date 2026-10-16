// Runs in every frame (spec §5.1): reports the frame's <video> elements to the service worker, and
// pauses them once Paper Plane has the video. It takes orders only from the extension, never from
// the page.
import { describeVideo, maximumVideos, primaryVideo } from "./videos";

declare global {
  var paperPlaneReporting: boolean | undefined;
}

// Installing the extension adds this script to open tabs, where it may already be running.
if (!globalThis.paperPlaneReporting) {
  globalThis.paperPlaneReporting = true;

  const videos = () => Array.from(document.querySelectorAll("video"), describeVideo).slice(0, maximumVideos);
  let reported = false;
  const send = (list: ReturnType<typeof videos>) => {
    try {
      chrome.runtime.sendMessage({ type: "videos", videos: list }).catch(() => undefined);
      reported = true;
    } catch {
      // The extension was updated or removed: this copy of the script has nobody to report to.
    }
  };
  let pending: ReturnType<typeof setTimeout> | undefined;
  const report = (event: Event) => {
    if (!(event.target instanceof HTMLVideoElement)) {
      return; // <audio> too fires media events
    }
    clearTimeout(pending);
    pending = setTimeout(() => send(videos()), 300);
  };
  // Media events don't bubble, but they do pass through the document on the way down, so frames
  // without a video never report at all.
  for (const event of ["play", "playing", "pause", "ended", "loadedmetadata", "durationchange", "emptied"]) {
    document.addEventListener(event, report, true);
  }
  if (document.querySelector("video")) {
    send(videos());
  }
  // A frame leaving with its video: say so, so it isn't counted as playing.
  addEventListener("pagehide", () => {
    if (reported) {
      send([]);
    }
  });

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
      reply(primaryVideo(videos())?.currentTime);
    }
    return false;
  });
}
