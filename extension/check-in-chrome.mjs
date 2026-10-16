// Drives the built extension in a headless Chrome with a throwaway profile, over the DevTools
// pipe: loads it, opens a page whose <video> plays, and sends that video to Paper Plane the way
// the popup does. Run by scripts/check-extension.sh, which sets up the page, the profile and the app.
// Usage: node check-in-chrome.mjs <chrome binary> <profile folder> <page URL>
import { spawn } from "node:child_process";
import { resolve } from "node:path";

const [chromePath, profile, pageURL] = process.argv.slice(2);
const expectedID = "napcmmglefncoieikecpjmdopmagllcg";

const chrome = spawn(chromePath, [
  "--headless=new", "--remote-debugging-pipe", "--enable-unsafe-extension-debugging",
  `--user-data-dir=${profile}`, "--use-mock-keychain", "--no-first-run", "--no-default-browser-check",
  "--disable-component-update", "--disable-background-networking", "--autoplay-policy=no-user-gesture-required",
  "about:blank",
], { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });

let nextID = 0;
let buffer = "";
const waiting = new Map();
chrome.stdio[4].setEncoding("utf8");
chrome.stdio[4].on("data", (chunk) => {
  buffer += chunk;
  for (let end = buffer.indexOf("\0"); end >= 0; end = buffer.indexOf("\0")) {
    const message = JSON.parse(buffer.slice(0, end));
    buffer = buffer.slice(end + 1);
    const pending = waiting.get(message.id);
    if (pending) {
      waiting.delete(message.id);
      message.error ? pending.reject(new Error(JSON.stringify(message.error))) : pending.resolve(message.result);
    }
  }
});

function call(method, params = {}, sessionId) {
  const id = ++nextID;
  chrome.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + "\0");
  return new Promise((resolve, reject) => waiting.set(id, { resolve, reject }));
}

async function evaluate(targetId, expression) {
  const { sessionId } = await call("Target.attachToTarget", { targetId, flatten: true });
  const { result, exceptionDetails } = await call("Runtime.evaluate",
    { expression, awaitPromise: true, returnByValue: true }, sessionId);
  if (exceptionDetails) {
    throw new Error(JSON.stringify(exceptionDetails));
  }
  return result.value;
}

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
let failures = 0;
function expect(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  console.log(`${ok ? "ok" : "FAIL"}: ${name}${ok ? "" : ` — expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`}`);
  failures += ok ? 0 : 1;
}

try {
  const { id } = await call("Extensions.loadUnpacked", { path: resolve("dist") });
  expect("the extension's ID is the pinned one", id, expectedID);
  // A page loaded before the new worker has its listeners would go unseen.
  for (let tries = 0; tries < 50; tries += 1) {
    const { targetInfos } = await call("Target.getTargets");
    if (targetInfos.some((target) => target.type === "service_worker" && target.url.startsWith(`chrome-extension://${id}/`))) {
      break;
    }
    await sleep(100);
  }

  const { targetId: page } = await call("Target.createTarget", { url: pageURL });
  await sleep(4000); // the video loads and plays; its requests and reports reach the worker
  expect("the page's video plays", await evaluate(page, `(() => {
    const video = document.querySelector("video");
    return { paused: video.paused, time: video.currentTime > 0, error: video.error?.message ?? null };
  })()`), { paused: false, time: true, error: null });

  const { targetId: popup } = await call("Target.createTarget", { url: `chrome-extension://${id}/popup.html` });
  await sleep(500);
  const result = await evaluate(popup, `(async () => {
    const [tab] = await chrome.tabs.query({ url: "http://127.0.0.1/*" });
    const state = await chrome.runtime.sendMessage({ type: "state", tabId: tab.id });
    const sent = await chrome.runtime.sendMessage({ type: "send", tabId: tab.id });
    return { plan: state?.plan, label: state?.rows?.[0]?.label, sent };
  })()`);
  expect("one video is found", [result.plan, result.label], ["send", "Video file · 127.0.0.1"]);
  expect("Paper Plane takes it", result.sent, { ok: true });
  // Chrome rests a muted video in a background tab and resumes it in front, so look with the
  // page in front: only a video the extension paused stays paused.
  await call("Target.activateTarget", { targetId: page });
  await sleep(1500);
  expect("the page's video is paused", await evaluate(page, `document.querySelector("video").paused`), true);
} catch (error) {
  console.log(`FAIL: ${error.message}`);
  failures += 1;
} finally {
  chrome.kill();
}
process.exit(failures === 0 ? 0 : 1);
