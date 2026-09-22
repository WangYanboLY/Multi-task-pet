"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const contentScript = fs.readFileSync(path.join(__dirname, "content.js"), "utf8");

function tabHarness(initialWorking) {
  let now = 1_700_000_000_000;
  let mutationCallback;
  let heartbeat;
  let nextTimer = 0;
  const timers = new Map();
  const listeners = new Map();
  const sent = [];
  const page = { working: initialWorking };

  class Element {
    closest(selector) { return selector === 'button, [role="button"]' ? this : null; }
  }
  class HTMLElement extends Element {
    getAttribute(name) { return name === "aria-label" ? "Stop generating" : null; }
    getBoundingClientRect() { return { width: 24, height: 24 }; }
  }
  const stopButton = new HTMLElement();
  stopButton.textContent = "";

  const context = {
    URL,
    Element,
    HTMLElement,
    Date: class extends Date { static now() { return now; } },
    location: { href: "https://chatgpt.com/c/abcdef" },
    document: {
      title: "A task - ChatGPT",
      documentElement: {},
      querySelectorAll(selector) {
        return selector === 'button, [role="button"]' && page.working ? [stopButton] : [];
      }
    },
    getComputedStyle() { return { display: "block", visibility: "visible" }; },
    MutationObserver: class {
      constructor(callback) { mutationCallback = callback; }
      observe() {}
    },
    addEventListener(name, callback) { listeners.set(name, callback); },
    setInterval(callback) { heartbeat = callback; },
    setTimeout(callback, delay) {
      const id = ++nextTimer;
      timers.set(id, { at: now + delay, callback });
      return id;
    },
    clearTimeout(id) { timers.delete(id); },
    chrome: { runtime: { sendMessage(message) { sent.push(message.event); } } }
  };
  vm.runInNewContext(contentScript, context, { filename: "content.js" });

  function advance(milliseconds) {
    const target = now + milliseconds;
    while (true) {
      const due = [...timers].sort((a, b) => a[1].at - b[1].at)[0];
      if (!due || due[1].at > target) break;
      now = due[1].at;
      timers.delete(due[0]);
      due[1].callback();
    }
    now = target;
  }

  return {
    page,
    sent,
    stopButton,
    advance,
    mutate() { mutationCallback(); },
    heartbeat() { heartbeat(); },
    clickStop() { listeners.get("click")({ target: stopButton }); }
  };
}

function latest(tab) { return tab.sent.at(-1); }

const existing = tabHarness(false);
assert.equal(latest(existing).status, "unknown");
assert.equal(latest(existing).answer_revision, undefined);
existing.heartbeat();
assert.equal(latest(existing).answer_revision, undefined);

const tab = tabHarness(true);
assert.equal(latest(tab).status, "working");
tab.page.working = false;
tab.mutate();
tab.advance(2_000);
assert.equal(latest(tab).status, "idle");
assert.equal(latest(tab).answer_revision, undefined);
tab.advance(1_999);
assert.equal(latest(tab).answer_revision, undefined);
tab.advance(1);
const firstRevision = latest(tab).answer_revision;
assert.match(firstRevision, /^[0-9]+$/);
tab.heartbeat();
assert.equal(latest(tab).answer_revision, firstRevision);

tab.page.working = true;
tab.mutate();
tab.advance(2_000);
assert.equal(latest(tab).status, "working");
tab.page.working = false;
tab.mutate();
tab.advance(2_000);
tab.advance(2_000);
const secondRevision = latest(tab).answer_revision;
assert.notEqual(secondRevision, firstRevision);

// A transient disappearance of the stop button must not announce completion.
tab.page.working = true;
tab.mutate();
tab.advance(2_000);
tab.page.working = false;
tab.mutate();
tab.advance(2_000);
tab.page.working = true;
tab.advance(2_000);
assert.equal(latest(tab).status, "working");
assert.equal(latest(tab).answer_revision, secondRevision);

// A deliberate stop click is an interruption, not a finished answer.
tab.clickStop();
tab.page.working = false;
tab.mutate();
tab.advance(2_000);
tab.advance(2_500);
assert.equal(latest(tab).answer_revision, secondRevision);

console.log("content observer completion revision tests passed");
