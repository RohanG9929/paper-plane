// The service worker (spec §5.1): watches each tab's requests for streams, keeps what it finds in
// chrome.storage.session, sets the toolbar button, and sends the chosen video to Paper Plane.
import { classify } from "./classify";
import { failureText, hostName, pageMessage, startTime, streamMessage } from "./message";
import { navigated, newTab, observe, pickHeaders, withVideos, type TabState } from "./tabs";
import { videosFrom } from "./videos";
import { button, plan, rows, type PopupState, type Target } from "./view";

const filter: chrome.webRequest.RequestFilter = {
  urls: ["<all_urls>"],
  types: ["main_frame", "xmlhttprequest", "media", "other"],
};

/** Each request's kept headers, by request ID, only until its response shows whether it's video. */
const pending = new Map<string, Record<string, string>>();
const maximumPending = 500;
/** Tabs with a send under way. */
const sending = new Set<number>();

// MARK: - Tab state, one change at a time per tab

const changes = new Map<number, Promise<unknown>>();

function storageKey(tabId: number): string {
  return `tab:${tabId}`;
}

async function load(tabId: number): Promise<TabState> {
  const stored = await chrome.storage.session.get(storageKey(tabId));
  return (stored[storageKey(tabId)] as TabState | undefined) ?? newTab();
}

function update(tabId: number, change: (tab: TabState) => TabState): Promise<TabState> {
  const next = (changes.get(tabId) ?? Promise.resolve()).then(async () => {
    const tab = change(await load(tabId));
    await chrome.storage.session.set({ [storageKey(tabId)]: tab });
    return tab;
  });
  changes.set(tabId, next.catch(() => undefined));
  return next;
}

function icons(kind: "idle" | "ready"): Record<number, string> {
  const name = kind === "idle" ? "idle" : "icon";
  return Object.fromEntries([16, 32, 48, 128].map((size) => [size, `icons/${name}-${size}.png`]));
}

/** Sets the tab's button from what's known about it. */
async function refresh(tabId: number, known?: TabState): Promise<void> {
  const page = await chrome.tabs.get(tabId).catch(() => undefined);
  if (!page) {
    return; // closed meanwhile
  }
  const tab = known ?? await load(tabId);
  const view = button(tab, plan(tab, page.url, Date.now()), sending.has(tabId));
  await Promise.all([
    chrome.action.setIcon({ tabId, path: icons(view.icon) }),
    chrome.action.setBadgeText({ tabId, text: view.badge }),
    chrome.action.setPopup({ tabId, popup: view.popup ? "popup.html" : "" }),
    chrome.action.setTitle({ tabId, title: view.title }),
  ]).catch(() => undefined);
}

// MARK: - Watching requests

chrome.webRequest.onSendHeaders.addListener((details) => {
  if (details.tabId < 0) {
    return;
  }
  const headers = pickHeaders(details.requestHeaders);
  if (details.type === "main_frame") {
    void update(details.tabId, () => navigated(details.url, headers)).then((tab) => refresh(details.tabId, tab));
    return;
  }
  if (pending.size >= maximumPending) {
    pending.delete(pending.keys().next().value!);
  }
  pending.set(details.requestId, headers);
}, filter, ["requestHeaders", "extraHeaders"]);

chrome.webRequest.onHeadersReceived.addListener((details) => {
  const headers = pending.get(details.requestId) ?? {};
  pending.delete(details.requestId);
  if (details.tabId < 0 || details.type === "main_frame") {
    return;
  }
  const contentType = details.responseHeaders?.find((header) => header.name.toLowerCase() === "content-type")?.value;
  if (!classify(details.url, contentType, details.type)) {
    return; // most requests: nothing to keep
  }
  const response = {
    url: details.url, frameId: details.frameId, type: details.type, timeStamp: details.timeStamp,
    statusCode: details.statusCode, contentType, headers,
  };
  void update(details.tabId, (tab) => observe(tab, response)).then((tab) => refresh(details.tabId, tab));
}, filter, ["responseHeaders"]);

chrome.webRequest.onErrorOccurred.addListener((details) => {
  pending.delete(details.requestId);
}, filter);

chrome.tabs.onRemoved.addListener((tabId) => {
  changes.delete(tabId);
  void chrome.storage.session.remove(storageKey(tabId));
});

// MARK: - Sending

/** Where the video is now: asked of its frame, else the last report. */
async function currentTime(tabId: number, frameId: number, tab: TabState): Promise<number> {
  if (frameId >= 0) {
    const reported: unknown = await chrome.tabs.sendMessage(tabId, { type: "time" }, { frameId }).catch(() => undefined);
    if (typeof reported === "number" && Number.isFinite(reported) && reported >= 0) {
      return reported;
    }
  }
  return startTime(tab.videos, frameId);
}

/** Sends `target` to Paper Plane; once it has the video, pauses the tab's videos (spec §5.1). */
async function send(tabId: number, target: Target): Promise<{ ok: true } | { error: string }> {
  if (sending.has(tabId)) {
    return { error: "Already sending this tab's video." };
  }
  sending.add(tabId);
  await update(tabId, ({ error: _, ...tab }) => tab);
  await refresh(tabId);
  let result: { ok: true } | { error: string };
  try {
    const [tab, page] = await Promise.all([load(tabId), chrome.tabs.get(tabId)]);
    const info = { url: page.url ?? "", title: page.title ?? "" };
    const frameId = target.kind === "stream" ? target.candidate.frameId : 0;
    const startAt = await currentTime(tabId, frameId, tab);
    const message = target.kind === "stream"
      ? streamMessage(target.candidate, info, startAt)
      : pageMessage(info, tab.pageHeaders ?? {}, startAt);
    const reply: unknown = await chrome.runtime.sendNativeMessage(hostName, message);
    if (typeof reply === "object" && reply !== null && "ok" in reply && reply.ok === true) {
      await chrome.tabs.sendMessage(tabId, { type: "pause" }).catch(() => undefined);
      result = { ok: true };
    } else {
      result = { error: failureText(reply) };
    }
  } catch (failure) {
    result = { error: failureText(failure) };
  }
  if ("error" in result) {
    const error = result.error;
    await update(tabId, (tab) => ({ ...tab, error }));
  }
  sending.delete(tabId);
  await refresh(tabId);
  return result;
}

chrome.action.onClicked.addListener(async (page) => {
  if (page.id === undefined) {
    return;
  }
  const tab = await load(page.id);
  const current = plan(tab, page.url, Date.now());
  if (current.kind === "send") {
    await send(page.id, current.target);
    return;
  }
  // What was found changed since the button was set: show the choices instead.
  await refresh(page.id, tab);
  await chrome.action.openPopup().catch(() => undefined);
});

// MARK: - Messages from content scripts and the popup

async function answerPopup(message: Record<string, unknown>): Promise<unknown> {
  const tabId = message.tabId;
  if (typeof tabId !== "number") {
    return undefined;
  }
  const [tab, page] = await Promise.all([load(tabId), chrome.tabs.get(tabId)]);
  const current = plan(tab, page.url, Date.now());
  if (message.type === "state") {
    const offered = current.kind === "choose" ? current.ranked
      : current.kind === "send" && current.target.kind === "stream" ? [current.target.candidate] : [];
    const state: PopupState = {
      plan: current.kind,
      youtube: current.kind === "send" && current.target.kind === "page",
      rows: rows(offered, tab.videos),
      ...(tab.error ? { error: tab.error } : {}),
    };
    return state;
  }
  if (message.type === "send") {
    const candidate = typeof message.key === "string"
      ? tab.candidates.find((found) => found.key === message.key && found.variantOf === undefined)
      : undefined;
    const target: Target | undefined = candidate ? { kind: "stream", candidate }
      : current.kind === "send" ? current.target : undefined;
    return target ? send(tabId, target) : { error: "That video isn't on this page any more." };
  }
  return undefined;
}

chrome.runtime.onMessage.addListener((message: unknown, sender, reply) => {
  if (sender.id !== chrome.runtime.id || typeof message !== "object" || message === null) {
    return false;
  }
  const request = message as Record<string, unknown>;
  // The popup is known by its address; a content script's is the page's own.
  if (sender.url?.startsWith(chrome.runtime.getURL("popup.html"))) {
    answerPopup(request).then(reply, () => reply(undefined));
    return true; // answers later
  }
  const tabId = sender.tab?.id;
  if (tabId !== undefined && sender.frameId !== undefined && request.type === "videos") {
    const frameId = sender.frameId;
    void update(tabId, (tab) => withVideos(tab, frameId, videosFrom(request.videos))).then((tab) => refresh(tabId, tab));
  }
  return false;
});

// Pages open before the extension was installed or updated get the content script too.
chrome.runtime.onInstalled.addListener(async () => {
  const tabs = await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] });
  for (const tab of tabs) {
    if (tab.id !== undefined) {
      chrome.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, files: ["content.js"] })
        .catch(() => undefined);
    }
  }
});
