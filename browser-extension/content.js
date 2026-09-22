"use strict";

// executeScript also runs this file in tabs that were open before installation.
// Keep one observer and timer per tab when that happens.
if (!globalThis.__agentPetTabObserverV1) {
  globalThis.__agentPetTabObserverV1 = true;

  const HEARTBEAT_MS = 10_000;
  const MIN_SCAN_GAP_MS = 2_000;
  const STOP_LABEL = /^(?:stop(?: generating| response| thinking| streaming)?|停止(?:生成|回答|回复|响应))$/i;
  const APPROVE_LABEL = /^(?:allow|approve|grant|允许|批准)$/i;
  const REJECT_LABEL = /^(?:deny|reject|decline|拒绝)$/i;
  const STOP_TEST_IDS = new Set([
    "stop-button",
    "stop-response-button",
    "composer-abort-button"
  ]);

  let currentKey = "";
  let sawWorking = false;
  let lastSignature = "";
  let lastSentAt = 0;
  let lastScanAt = 0;
  let scanTimer = null;

  function conversation() {
    const url = new URL(location.href);
    let match;
    let source;

    if (url.hostname === "chatgpt.com") {
      source = "ChatGPT";
      match = url.pathname.match(/(?:^|\/)c\/([A-Za-z0-9_-]{6,200})(?:\/|$)/);
    } else if (url.hostname === "claude.ai") {
      source = "Claude";
      match = url.pathname.match(/^\/chat\/([A-Za-z0-9_-]{6,200})(?:\/|$)/);
    } else {
      return null;
    }

    if (!match) return null;
    // The conversation path is enough to reopen the tab. Drop query and hash
    // parameters, which can contain unrelated or sensitive information.
    return { source, id: match[1], url: `${url.origin}${url.pathname}` };
  }

  function visible(element) {
    if (!(element instanceof HTMLElement)) return false;
    if (element.closest('[aria-hidden="true"], [hidden]')) return false;
    const style = getComputedStyle(element);
    if (style.display === "none" || style.visibility !== "visible") return false;
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }

  function buttonLabel(button) {
    return (
      button.getAttribute("aria-label") ||
      button.getAttribute("title") ||
      button.textContent ||
      ""
    )
      .replace(/\s+/g, " ")
      .trim();
  }

  function hasVisibleStopButton() {
    const buttons = document.querySelectorAll('button, [role="button"]');
    for (const button of buttons) {
      if (!visible(button)) continue;
      if (STOP_TEST_IDS.has(button.getAttribute("data-testid"))) return true;
      if (STOP_LABEL.test(buttonLabel(button))) return true;
    }
    return false;
  }

  function hasExplicitDecisionDialog() {
    const dialogs = document.querySelectorAll('[role="dialog"], [role="alertdialog"]');
    for (const dialog of dialogs) {
      if (!visible(dialog)) continue;
      let approve = false;
      let reject = false;
      for (const button of dialog.querySelectorAll('button, [role="button"]')) {
        if (!visible(button)) continue;
        const label = buttonLabel(button);
        approve ||= APPROVE_LABEL.test(label);
        reject ||= REJECT_LABEL.test(label);
      }
      if (approve && reject) return true;
    }
    return false;
  }

  function selectedSidebarTitle(url) {
    const currentPath = new URL(url).pathname;
    const links = document.querySelectorAll(
      'nav a[aria-current="page"], aside a[aria-current="page"]'
    );
    for (const link of links) {
      try {
        if (new URL(link.href).pathname !== currentPath) continue;
      } catch {
        continue;
      }
      const title = (link.textContent || "").replace(/\s+/g, " ").trim();
      if (title) return title.slice(0, 160);
    }
    return "";
  }

  function conversationTitle(info) {
    const pageTitle = document.title
      .replace(/\s*[|—–-]\s*(?:ChatGPT|Claude)\s*$/i, "")
      .trim();
    if (pageTitle && pageTitle !== "ChatGPT" && pageTitle !== "Claude") {
      return pageTitle.slice(0, 160);
    }
    return selectedSidebarTitle(info.url) || `${info.source} conversation`;
  }

  function observedStatus() {
    if (hasExplicitDecisionDialog()) return "waiting";
    if (hasVisibleStopButton()) {
      sawWorking = true;
      return "working";
    }
    // A finished response is an idle conversation, not a completed user task.
    return sawWorking ? "idle" : "unknown";
  }

  function observe(force = false) {
    lastScanAt = Date.now();
    const info = conversation();
    if (!info) {
      currentKey = "";
      sawWorking = false;
      lastSignature = "";
      return;
    }

    const key = `${info.source}:${info.id}`;
    if (key !== currentKey) {
      currentKey = key;
      sawWorking = false;
      lastSignature = "";
    }

    const event = {
      ...info,
      title: conversationTitle(info),
      status: observedStatus(),
      observed_at: Date.now()
    };
    const signature = JSON.stringify([event.url, event.title, event.status]);
    if (!force && signature === lastSignature && Date.now() - lastSentAt < HEARTBEAT_MS) {
      return;
    }

    lastSignature = signature;
    lastSentAt = event.observed_at;
    try {
      const delivery = chrome.runtime.sendMessage({
        type: "agent-pet-observation",
        event
      });
      if (delivery && typeof delivery.catch === "function") {
        delivery.catch(() => {});
      }
    } catch {
      // A browser may invalidate the extension context during an update.
    }
  }

  function scheduleObserve() {
    if (scanTimer !== null) return;
    const wait = Math.max(350, MIN_SCAN_GAP_MS - (Date.now() - lastScanAt));
    scanTimer = setTimeout(() => {
      scanTimer = null;
      observe();
    }, wait);
  }

  new MutationObserver(scheduleObserve).observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["aria-label", "aria-current", "data-testid", "hidden", "title"]
  });
  addEventListener("popstate", scheduleObserve);
  addEventListener("hashchange", scheduleObserve);
  addEventListener("pageshow", () => observe(true));
  setInterval(() => observe(true), HEARTBEAT_MS);
  observe(true);
}
