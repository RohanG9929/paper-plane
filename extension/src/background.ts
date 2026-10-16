// The service worker (spec §5.1): watches each tab's requests for streams, keeps what it finds in
// chrome.storage.session, sets the toolbar button, and sends the chosen video to Paper Plane.
import { classify } from "./classify";
import { failureText, hostName, pageMessage, startTime, streamMessage } from "./message";
import { navigated, newTab, observe, pickHeaders, withVideos, type TabState } from "./tabs";
import { videosFrom } from "./videos";
import { button, plan, popupState, type SendResult, type Target } from "./view";

const filter: chrome.webRequest.RequestFilter = {
  urls: ["<all_urls>"],
  types: ["main_frame", "xmlhttprequest", "media", "other"],
};

type RawHeaders = chrome.webRequest.HttpHeader[] | undefined;
/** Each request's headers, by request ID, only until its response shows whether it's video. */
const pending = new Map<string, RawHeaders>();
const maximumPending = 500;
/** Tabs with a send under way. */
const sending = new Set<number>();
/** The button each tab was last given, so an unchanged one isn't set again. */
const shown = new Map<number, string>();

const icons = {
  idle: { 16: "icons/idle-16.png", 32: "icons/idle-32.png", 48: "icons/idle-48.png", 128: "icons/idle-128.png" },
  ready: { 16: "icons/icon-16.png", 32: "icons/icon-32.png", 48: "icons/icon-48.png", 128: "icons/icon-128.png" },
};

// MARK: - Tab state, one change at a time per tab

const changes = new Map<number, Promise<unknown>>();

function storageKey(tabId: number): string {
  return `tab:${tabId}`;
}

async function load(tabId: number): Promise<TabState> {
  const stored = await chrome.storage.session.get(storageKey(tabId));
  return (stored[storageKey(tabId)] as TabState | undefined) ?? newTab();
}

/** Applies `change`, saving only what changed, and returns the state after it. */
function update(tabId: number, change: (tab: TabState) => TabState): Promise<{ tab: TabState; changed: boolean }> {
  const next = (changes.get(tabId) ?? Promise.resolve()).then(async () => {
    const before = await load(tabId);
    const tab = change(before);
    if (tab !== before) {
      await chrome.storage.session.set({ [storageKey(tabId)]: tab });
    }
    return { tab, changed: tab !== before };
  });
  changes.set(tabId, next.catch(() => undefined));
  return next;
}

/** Updates a tab's state and, if it changed, its button. Failures (say, storage full) are
 *  dropped: the next event tries again. */
function change(tabId: number, transform: (tab: TabState) => TabState): void {
  update(tabId, transform)
    .then(({ tab, changed }) => changed ? refresh(tabId, tab) : undefined)
    .catch(() => undefined);
}

/** Sets the tab's button from what's known about it. */
async function refresh(tabId: number, known?: TabState): Promise<void> {
  const page = await chrome.tabs.get(tabId).catch(() => undefined);
  if (!page) {
    return; // closed meanwhile
  }
  const tab = known ?? await load(tabId);
  const view = button(tab, plan(tab, page.url, Date.now()), sending.has(tabId));
  const summary = JSON.stringify(view);
  if (shown.get(tabId) === summary) {
    return;
  }
  shown.set(tabId, summary);
  await Promise.all([
    chrome.action.setIcon({ tabId, path: icons[view.icon] }),
    chrome.action.setBadgeText({ tabId, text: view.badge }),
    chrome.action.setPopup({ tabId, popup: view.popup ? "popup.html" : "" }),
    chrome.action.setTitle({ tabId, title: view.title }),
  ]).catch(() => shown.delete(tabId));
}

// MARK: - Watching requests

chrome.webRequest.onSendHeaders.addListener((details) => {
  if (details.tabId < 0) {
    return;
  }
  if (details.type === "main_frame") {
    // A page loading in the tab itself, not one prerendered in the background.
    const lifecycle = (details as { documentLifecycle?: string }).documentLifecycle;
    if (lifecycle === "prerender") {
      return;
    }
    shown.delete(details.tabId); // Chrome resets the button for a new page
    change(details.tabId, () => navigated(details.url, pickHeaders(details.requestHeaders)));
    return;
  }
  if (pending.size >= maximumPending) {
    pending.delete(pending.keys().next().value!);
  }
  pending.set(details.requestId, details.requestHeaders);
}, filter, ["requestHeaders", "extraHeaders"]);

chrome.webRequest.onHeadersReceived.addListener((details) => {
  const headers = pending.get(details.requestId);
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
    statusCode: details.statusCode, contentType, headers: pickHeaders(headers),
  };
  change(details.tabId, (tab) => observe(tab, response));
}, filter, ["responseHeaders"]);

chrome.webRequest.onErrorOccurred.addListener((details) => {
  pending.delete(details.requestId);
}, filter);

chrome.tabs.onRemoved.addListener((tabId) => {
  changes.delete(tabId);
  shown.delete(tabId);
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
async function send(tabId: number, target: Target): Promise<SendResult> {
  if (sending.has(tabId)) {
    return { error: "Already sending this tab's video." };
  }
  sending.add(tabId);
  let result: SendResult;
  try {
    const { tab } = await update(tabId, ({ error: _, ...rest }) => rest);
    void refresh(tabId, tab);
    const page = await chrome.tabs.get(tabId);
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
  } finally {
    sending.delete(tabId);
  }
  if ("error" in result) {
    const error = result.error;
    await update(tabId, (tab) => ({ ...tab, error })).catch(() => undefined);
  }
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
  shown.delete(page.id);
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
    return popupState(tab, current);
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
    change(tabId, (tab) => withVideos(tab, frameId, videosFrom(request.videos)));
  }
  return false;
});

// Pages already open when the extension is installed or updated get the content script too.
chrome.runtime.onInstalled.addListener(async (details) => {
  if (details.reason !== "install" && details.reason !== "update") {
    return;
  }
  const tabs = await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] });
  for (const tab of tabs) {
    if (tab.id !== undefined) {
      chrome.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, files: ["content.js"] })
        .catch(() => undefined);
    }
  }
});
