"""Asynchronous, local-only topic labels for the task snapshot.

Raw conversation excerpts stay in memory and go only to the bundled macOS
labeler over stdin. The on-disk cache contains hashes and short labels.
"""

import hashlib
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import tempfile
import threading
import time


GENERIC_TITLES = {"Codex 任务", "ChatGPT 对话", "Claude 对话", "未命名对话"}
PROMPT_VERSION = 2


def _atomic_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".topic-labels-", suffix=".json", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(value, output, ensure_ascii=False, separators=(",", ":"))
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _read_cache(path):
    try:
        with path.open("r", encoding="utf-8") as source:
            saved = json.load(source)
    except (OSError, ValueError, UnicodeError):
        return {}
    if not isinstance(saved, dict) or saved.get("version") != 1:
        return {}
    entries = saved.get("entries")
    if not isinstance(entries, dict):
        return {}
    result = {}
    for identifier, entry in entries.items():
        if (isinstance(identifier, str) and isinstance(entry, dict) and
                isinstance(entry.get("fingerprint"), str) and
                _clean_label(entry.get("label")) is not None and
                isinstance(entry.get("saved_at"), (int, float))):
            result[identifier] = entry
    return result


def _clean_label(value):
    if not isinstance(value, str):
        return None
    if "\n" in value or "\r" in value:
        return None
    label = " ".join(value.strip().strip('"“”「」').split())
    if not 2 <= len(label) <= 48:
        return None
    if re.search(r"https?://|(?i:无法|不能|抱歉|作为一个AI)", label):
        return None
    return label


def _request_for(task, context):
    context = context if isinstance(context, dict) else {}
    request = {
        "source": str(context.get("source") or task.get("source") or "")[:40],
        "family": str(context.get("family") or task.get("family") or "")[:120],
        "title": str(context.get("title") or task.get("title") or "")[:200],
        "context": str(context.get("context") or "")[:4000],
    }
    title = request["title"].strip()
    content = request["context"].strip()
    if not content and (not title or title in GENERIC_TITLES or
                        re.fullmatch(r"(?:Claude(?: Code)?|Codex)\s*[·:]\s*[0-9a-f-]{6,}", title, re.I)):
        return None
    return request


class TopicLabels:
    """Attach cached labels immediately, and queue changed inputs off-thread."""

    def __init__(self, home, labeler=None):
        self.path = Path(home) / "topic-labels.json"
        bundled = Path(__file__).resolve().parent.parent / "MacOS" / "TopicLabeler"
        configured = labeler or os.environ.get("AGENT_PET_TOPIC_LABELER") or bundled
        self.labeler = Path(configured)
        self.available = self.labeler.is_file() and os.access(self.labeler, os.X_OK)
        self._entries = _read_cache(self.path)
        self._lock = threading.Lock()
        self._queued = set()
        self._retry_after = {}
        self._unavailable_until = 0
        self._work = queue.Queue()
        if self.available:
            threading.Thread(target=self._run, name="agent-pet-topic-labels", daemon=True).start()

    def attach(self, tasks, contexts=None):
        contexts = contexts or {}
        for task in tasks:
            identifier = task.get("id")
            if not isinstance(identifier, str) or not identifier:
                continue
            request = _request_for(task, contexts.get(identifier))
            if request is None:
                continue
            fingerprint = hashlib.sha256(
                json.dumps({"version": PROMPT_VERSION, "request": request},
                           ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
            ).hexdigest()
            with self._lock:
                entry = self._entries.get(identifier)
                if entry and entry["fingerprint"] == fingerprint:
                    task["topic_label"] = entry["label"]
                    continue
                retry = self._retry_after.get((identifier, fingerprint), 0)
                if (self.available and identifier not in self._queued and
                        time.monotonic() >= max(retry, self._unavailable_until)):
                    self._queued.add(identifier)
                    self._work.put((identifier, fingerprint, request))

    def _run(self):
        while True:
            identifier, fingerprint, request = self._work.get()
            try:
                with self._lock:
                    unavailable_until = self._unavailable_until
                if time.monotonic() < unavailable_until:
                    with self._lock:
                        self._retry_after[(identifier, fingerprint)] = unavailable_until
                    continue
                outcome = subprocess.run(
                    [str(self.labeler)], input=json.dumps(request, ensure_ascii=False),
                    text=True, capture_output=True, timeout=45, check=False,
                )
                label = None
                if outcome.returncode == 0 and len(outcome.stdout) <= 4096:
                    try:
                        label = _clean_label(json.loads(outcome.stdout).get("label"))
                    except (ValueError, AttributeError):
                        pass
                with self._lock:
                    if label:
                        self._entries[identifier] = {
                            "fingerprint": fingerprint, "label": label, "saved_at": time.time(),
                        }
                        if len(self._entries) > 2000:
                            newest = sorted(self._entries.items(), key=lambda pair: pair[1]["saved_at"], reverse=True)[:2000]
                            self._entries = dict(newest)
                        try:
                            _atomic_json(self.path, {"version": 1, "entries": self._entries})
                        except OSError:
                            # Keep the label in memory even if the cache cannot be saved.
                            pass
                    else:
                        if outcome.returncode == 3:
                            self._unavailable_until = time.monotonic() + 3600
                        self._retry_after[(identifier, fingerprint)] = max(
                            time.monotonic() + 90, self._unavailable_until
                        )
            except (OSError, subprocess.TimeoutExpired):
                with self._lock:
                    self._retry_after[(identifier, fingerprint)] = time.monotonic() + 90
            finally:
                with self._lock:
                    self._queued.discard(identifier)
                self._work.task_done()
