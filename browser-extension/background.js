"use strict";

const COLLECTOR_URL = "http://127.0.0.1:56987/event";
const TAB_PATTERNS = ["https://chatgpt.com/*", "https://claude.ai/*"];
const STATUSES = new Set(["working", "waiting", "idle", "unknown"]);

function sourceForHost(hostname) {
  if (hostname === "chatgpt.com") return "ChatGPT";
  if (hostname === "claude.ai") return "Claude";
  return null;
}

function validObservation(raw, sender) {
  if (!raw || typeof raw !== "object" || !sender.tab || !sender.tab.url) {
    return null;
  }

  let observedUrl;
  let tabUrl;
  try {
    observedUrl = new URL(raw.url);
    tabUrl = new URL(sender.tab.url);
  } catch {
    return null;
  }

  const source = sourceForHost(observedUrl.hostname);
  if (
    observedUrl.protocol !== "https:" ||
    observedUrl.origin !== tabUrl.origin ||
    source !== raw.source ||
    !STATUSES.has(raw.status) ||
    typeof raw.id !== "string" ||
    !/^[A-Za-z0-9_-]{6,200}$/.test(raw.id) ||
    typeof raw.title !== "string" ||
    !Number.isFinite(raw.observed_at)
  ) {
    return null;
  }

  return {
    source,
    id: raw.id,
    url: observedUrl.href,
    title: raw.title.trim().slice(0, 160),
    status: raw.status,
    observed_at: raw.observed_at
  };
}

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.type !== "agent-pet-observation") return;
  const event = validObservation(message.event, sender);
  if (!event) return;

  // The service worker has localhost host permission. Page scripts never make
  // collector requests, and the request carries no browser credentials.
  fetch(COLLECTOR_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(event),
    cache: "no-store",
    credentials: "omit"
  }).catch(() => {
    // The collector may be closed while the browser is running.
  });
});

async function injectIntoOpenTabs() {
  const tabs = await chrome.tabs.query({ url: TAB_PATTERNS });
  await Promise.allSettled(
    tabs
      .filter((tab) => Number.isInteger(tab.id))
      .map((tab) =>
        chrome.scripting.executeScript({
          target: { tabId: tab.id },
          files: ["content.js"]
        })
      )
  );
}

chrome.runtime.onInstalled.addListener(() => {
  void injectIntoOpenTabs().catch(() => {});
});

chrome.runtime.onStartup.addListener(() => {
  void injectIntoOpenTabs().catch(() => {});
});
