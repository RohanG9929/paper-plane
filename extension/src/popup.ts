// The toolbar popup (spec §5.1): what was found when there's a choice to make, why nothing was,
// or why sending failed. Everything it shows goes in as text, never as HTML.
import type { PopupState, Row, SendResult } from "./view";

const main = document.querySelector("main")!;

function element<K extends keyof HTMLElementTagNameMap>(tag: K, className: string, text?: string): HTMLElementTagNameMap[K] {
  const made = document.createElement(tag);
  made.className = className;
  if (text !== undefined) {
    made.textContent = text;
  }
  return made;
}

function choice(row: Row, onPick: () => void): HTMLButtonElement {
  const button = element("button", "row");
  button.type = "button";
  button.append(element("span", "label", row.label), element("span", "detail", row.detail));
  button.addEventListener("click", onPick);
  return button;
}

function render(tabId: number, state: PopupState | undefined): void {
  main.replaceChildren();
  if (state?.error) {
    main.append(element("p", "note", state.error));
  }
  if (!state || state.plan === "none") {
    main.append(element("h1", "heading", "No video found yet"),
      element("p", "hint", "Start the video on this page, then click Paper Plane again."));
    return;
  }
  main.append(element("h1", "heading", state.plan === "choose" ? "Which video?" : "Send to your TV"));
  const list = element("div", "rows");
  for (const row of state.rows) {
    list.append(choice(row, () => void send(tabId, row.key)));
  }
  main.append(list);
  list.querySelector("button")?.focus();
}

async function send(tabId: number, key: string | undefined): Promise<void> {
  main.replaceChildren(element("p", "status", "Sending to Paper Plane…"));
  const result = await (chrome.runtime.sendMessage({ type: "send", tabId, key }) as Promise<SendResult | undefined>)
    .catch((): SendResult => ({ error: "Couldn't reach Paper Plane. Try again." }));
  if (result && "ok" in result) {
    main.replaceChildren(element("h1", "heading", "Sent"), element("p", "hint", "Choose your TV in Paper Plane."));
    setTimeout(() => window.close(), 1500);
  } else {
    render(tabId, await state(tabId));
  }
}

function state(tabId: number): Promise<PopupState | undefined> {
  return (chrome.runtime.sendMessage({ type: "state", tabId }) as Promise<PopupState | undefined>).catch(() => undefined);
}

const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
if (active?.id !== undefined) {
  render(active.id, await state(active.id));
}
