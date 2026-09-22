#!/usr/bin/env python3
"""Read local agent activity and serve a small loopback feed for browser tabs.

The collector deliberately reads metadata only. A completed assistant turn is
reported as idle; it is not treated as completion of the user's whole task.
"""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import sqlite3
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


PORT = 56987
POLL_SECONDS = 3
WEB_LIVE_SECONDS = 35
WEB_DROP_SECONDS = 180
CODEX_WORKING_SECONDS = 6 * 60 * 60
CODEX_RECENT_SECONDS = 24 * 60 * 60
CLAUDE_FRESH_SECONDS = 6 * 60 * 60
STATUSES = {"working", "waiting", "done", "failed", "idle", "unknown"}
WEB_HOSTS = {"chatgpt.com": "ChatGPT", "chat.openai.com": "ChatGPT", "claude.ai": "Claude"}
TASK_PROGRESS_CACHE = {}


def now_ms():
    return int(time.time() * 1000)


def iso_from_ms(value):
    return dt.datetime.fromtimestamp(value / 1000, dt.timezone.utc).isoformat().replace("+00:00", "Z")


def safe_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError, UnicodeError):
        return None


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def project_family(cwd, fallback):
    if isinstance(cwd, str) and cwd.strip():
        path = os.path.abspath(os.path.expanduser(cwd))
        name = os.path.basename(path.rstrip(os.sep)) or path
        return "project:" + path, name
    return "source:" + fallback.lower().replace(" ", "-"), fallback


def clean_title(value, fallback):
    if not isinstance(value, str):
        return fallback
    title = " ".join(value.split()).strip()
    return title[:160] or fallback


def read_sqlite(path, query, params=()):
    if not path.is_file():
        return []
    uri = "file:{}?mode=ro".format(path.as_posix())
    connection = None
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=1)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only=ON")
        return [dict(row) for row in connection.execute(query, params)]
    except sqlite3.Error:
        return []
    finally:
        if connection:
            connection.close()


def collect_codex(codex_home, timestamp):
    state = codex_home / "state_5.sqlite"
    history = codex_home / "thread_history_1.sqlite"
    cutoff_ms = timestamp - CODEX_RECENT_SECONDS * 1000
    rows = read_sqlite(
        state,
        """SELECT id, cwd, title, name, agent_nickname, agent_path,
                  updated_at, updated_at_ms, recency_at_ms
             FROM threads
            WHERE archived = 0 AND COALESCE(updated_at_ms, updated_at * 1000) >= ?
            ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC
            LIMIT 350""",
        (cutoff_ms,),
    )
    if not rows:
        return []
    edges = read_sqlite(state, "SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges")
    children = {edge["child_thread_id"]: edge["parent_thread_id"] for edge in edges}
    turns = read_sqlite(
        history,
        """SELECT thread_id, status, started_at, completed_at, rollout_ordinal
             FROM thread_turns
            ORDER BY thread_id, rollout_ordinal DESC""",
    )
    latest_turn = {}
    for turn in turns:
        latest_turn.setdefault(turn["thread_id"], turn)

    active = []
    recent = []
    for row in rows:
        thread_id = row["id"]
        turn = latest_turn.get(thread_id)
        if not turn:
            continue
        updated_ms = int(row["updated_at_ms"] or row["updated_at"] * 1000)
        started_ms = int(turn["started_at"] or 0) * 1000
        turn_status = turn["status"]
        if turn_status == "inProgress":
            # Historical crashes can leave inProgress forever. Require both a
            # recent turn start and a recently touched thread record.
            if (timestamp - started_ms > CODEX_WORKING_SECONDS * 1000 or
                    timestamp - updated_ms > CODEX_WORKING_SECONDS * 1000):
                continue
            status, detail = "working", "正在执行这一轮"
        elif turn_status == "failed":
            status, detail = "failed", "这一轮失败"
        elif turn_status == "interrupted":
            status, detail = "idle", "这一轮已中断"
        elif turn_status == "completed":
            status, detail = "idle", "这一轮已结束"
        else:
            status, detail = "unknown", "这一轮状态未识别"
        family_id, family = project_family(row["cwd"], "Codex")
        title = clean_title(row["name"] or row["title"], "Codex 任务")
        if thread_id in children or row["agent_path"]:
            nickname = clean_title(row["agent_nickname"], "子 agent")
            detail = "{} · {}".format(nickname, detail)
        item = {
            "id": "codex:" + thread_id,
            "source": "Codex",
            "family_id": family_id,
            "family": family,
            "title": title,
            "status": status,
            "updated_at": iso_from_ms(updated_ms),
            "detail": detail,
        }
        # The thread's updated_at can change for metadata edits; only a
        # terminal completed turn is evidence of a new assistant answer.
        if turn_status == "completed" and turn["completed_at"] and turn["rollout_ordinal"] is not None:
            item["answer_revision"] = "{}:{}".format(turn["rollout_ordinal"], turn["completed_at"])
        (active if status == "working" else recent).append(item)
    recent.sort(key=lambda item: item["updated_at"], reverse=True)
    return active + recent[:8]


def desktop_code_titles(desktop_home):
    result = {}
    base = desktop_home / "claude-code-sessions"
    if not base.is_dir():
        return result
    for path in base.glob("*/*/local_*.json"):
        data = safe_json(path)
        if not isinstance(data, dict) or data.get("isArchived"):
            continue
        session_id = data.get("cliSessionId")
        if isinstance(session_id, str) and session_id:
            result[session_id] = clean_title(data.get("title"), "")
    return result


def claude_task_progress(transcript, timestamp):
    """Count only explicit Claude TaskCreate/TaskUpdate events in a session.

    Transcript reads are incremental while the collector is running. The count
    is omitted once the last task event is too old to describe current work.
    """
    try:
        size = transcript.stat().st_size
    except OSError:
        return None
    previous = TASK_PROGRESS_CACHE.get(transcript)
    if previous is None or size < previous["offset"]:
        previous = {"offset": 0, "tasks": {}, "pending": {}, "latest_ms": 0}
    if size > previous["offset"]:
        try:
            with transcript.open("r", encoding="utf-8", errors="replace") as handle:
                handle.seek(previous["offset"])
                while True:
                    position = handle.tell()
                    line = handle.readline()
                    if not line:
                        break
                    if not line.endswith("\n"):
                        handle.seek(position)
                        break
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    contents = (event.get("message") or {}).get("content") or []
                    if not isinstance(contents, list):
                        continue
                    for block in contents:
                        if not isinstance(block, dict):
                            continue
                        name = block.get("name")
                        if name == "TaskCreate" and block.get("id"):
                            previous["pending"][block["id"]] = True
                        elif name == "TaskUpdate":
                            inputs = block.get("input") or {}
                            task_id = str(inputs.get("taskId") or "")
                            if task_id in previous["tasks"]:
                                state = inputs.get("status")
                                if state == "deleted":
                                    del previous["tasks"][task_id]
                                elif isinstance(state, str):
                                    previous["tasks"][task_id] = state
                                previous["latest_ms"] = max(previous["latest_ms"], event_timestamp_ms(event))
                        elif block.get("type") == "tool_result":
                            call_id = block.get("tool_use_id")
                            if call_id in previous["pending"]:
                                previous["pending"].pop(call_id, None)
                                if block.get("is_error"):
                                    continue
                                content = block.get("content")
                                if not isinstance(content, str):
                                    continue
                                match = re.search(r"(?i)\btask\s*(?:id|#)?\s*[:#]?\s*(\d+)\b", content)
                                if match:
                                    previous["tasks"][match.group(1)] = "pending"
                                    previous["latest_ms"] = max(previous["latest_ms"], event_timestamp_ms(event))
                previous["offset"] = handle.tell()
        except OSError:
            return None
        TASK_PROGRESS_CACHE[transcript] = previous
    if not previous["tasks"] or timestamp - previous["latest_ms"] > 48 * 60 * 60 * 1000:
        return None
    completed = sum(state == "completed" for state in previous["tasks"].values())
    return completed, len(previous["tasks"])


def event_timestamp_ms(event):
    value = event.get("timestamp")
    if not isinstance(value, str):
        return 0
    try:
        return int(dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return 0


def collect_claude(claude_home, desktop_home, timestamp):
    sessions_dir = claude_home / "sessions"
    if not sessions_dir.is_dir():
        return []
    titles = desktop_code_titles(desktop_home)
    tasks = []
    for path in sessions_dir.glob("*.json"):
        data = safe_json(path)
        if not isinstance(data, dict) or not pid_alive(data.get("pid")):
            continue
        session_id = data.get("sessionId")
        if not isinstance(session_id, str) or not session_id:
            continue
        try:
            status_updated_ms = int(data.get("statusUpdatedAt") or 0)
            updated_ms = int(data.get("statusUpdatedAt") or data.get("updatedAt") or 0)
        except (TypeError, ValueError):
            continue
        if updated_ms <= 0:
            continue
        age = timestamp - updated_ms
        if age > 24 * 60 * 60 * 1000:
            continue
        raw_status = data.get("status")
        if raw_status == "busy" and age <= CLAUDE_FRESH_SECONDS * 1000:
            status, detail = "working", "正在执行"
        elif raw_status == "idle" and age <= CLAUDE_FRESH_SECONDS * 1000:
            status, detail = "idle", "这一轮已结束"
        else:
            status, detail = "unknown", "会话仍打开，状态较旧"
        entrypoint = data.get("entrypoint")
        if entrypoint == "claude-desktop":
            source = "Claude"
            detail += " · Claude 桌面 Code"
        else:
            source = "Claude Code"
            detail += " · CLI"
        family_id, family = project_family(data.get("cwd"), source)
        fallback = "{} · {}".format(source, session_id[:8])
        title = clean_title(titles.get(session_id) or data.get("name"), fallback)
        tasks.append({
            "id": "claude-code:" + session_id,
            "source": source,
            "family_id": family_id,
            "family": family,
            "title": title,
            "status": status,
            "updated_at": iso_from_ms(updated_ms),
            "detail": detail,
        })
        # updatedAt is not a completion signal. Only a fresh, explicit idle
        # status transition gets a stable answer revision.
        if status == "idle" and status_updated_ms > 0:
            tasks[-1]["answer_revision"] = str(status_updated_ms)
        transcript_files = list((claude_home / "projects").glob("*/{}.jsonl".format(session_id)))
        if transcript_files:
            progress = claude_task_progress(transcript_files[0], timestamp)
            if progress:
                tasks[-1]["completed"], tasks[-1]["total"] = progress
                tasks[-1]["detail"] += " · Task 清单进度"
        # Claude subagents have no reliable terminal status in their metadata.
        # Show only those with recent transcript activity, and say what was seen.
        parent_files = list((claude_home / "projects").glob("*/{}".format(session_id)))
        for parent_dir in parent_files:
            for meta_path in (parent_dir / "subagents").glob("agent-*.meta.json"):
                transcript = meta_path.with_name(meta_path.name.replace(".meta.json", ".jsonl"))
                if not transcript.is_file():
                    continue
                touched_ms = int(transcript.stat().st_mtime * 1000)
                if timestamp - touched_ms > 30 * 60 * 1000:
                    continue
                meta = safe_json(meta_path) or {}
                child_name = clean_title(meta.get("description"), meta_path.stem.replace(".meta", ""))
                child_status = "working" if timestamp - touched_ms <= 90 * 1000 and status == "working" else "unknown"
                tasks.append({
                    "id": "claude-agent:{}:{}".format(session_id, meta_path.stem),
                    "source": source,
                    "family_id": family_id,
                    "family": family,
                    "title": child_name,
                    "status": child_status,
                    "updated_at": iso_from_ms(touched_ms),
                    "detail": "子 agent · 最近活动；没有明确完成信号",
                })
    return tasks


def validate_web_event(value, timestamp):
    if not isinstance(value, dict):
        return None
    url = value.get("url")
    if not isinstance(url, str) or len(url) > 2048:
        return None
    parsed = urlparse(url)
    source = WEB_HOSTS.get((parsed.hostname or "").lower())
    if parsed.scheme != "https" or source is None or value.get("source") != source:
        return None
    status = value.get("status")
    if status not in STATUSES:
        status = "unknown"
    title = clean_title(value.get("title"), source + " 对话")
    identifier = value.get("id")
    if not isinstance(identifier, str) or not identifier or len(identifier) > 512:
        identifier = parsed.path or "/"
    result = {
        "id": "web:{}:{}".format(source.lower(), identifier),
        "source": source,
        "family_id": "web:" + source.lower(),
        "family": source + " 网页",
        "title": title,
        "status": status,
        "updated_at": iso_from_ms(timestamp),
        "detail": "已打开标签页 · 浏览器观察",
        "url": url,
        "seen_ms": timestamp,
    }
    revision = value.get("answer_revision")
    if revision is not None:
        # A content script sends this only after seeing a response end. It is
        # stable across heartbeats, unlike updated_at and observed_at.
        if (not isinstance(revision, str) or
                not re.fullmatch(r"[1-9][0-9]{0,15}", revision) or
                int(revision) > timestamp):
            return None
        result["answer_revision"] = revision
    return result


def atomic_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".agent-pet-", suffix=".json", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Collector:
    def __init__(self, home=None, codex_home=None, claude_home=None, desktop_home=None):
        user_home = Path.home()
        self.home = Path(home or os.environ.get("AGENT_PET_HOME") or user_home / ".agent-pet")
        self.codex_home = Path(codex_home or os.environ.get("AGENT_PET_CODEX_HOME") or user_home / ".codex")
        self.claude_home = Path(claude_home or os.environ.get("AGENT_PET_CLAUDE_HOME") or user_home / ".claude")
        self.desktop_home = Path(desktop_home or os.environ.get("AGENT_PET_CLAUDE_DESKTOP_HOME") or user_home / "Library/Application Support/Claude")
        self.browser = {}
        self.lock = threading.Lock()

    def receive(self, value):
        event = validate_web_event(value, now_ms())
        if event is None:
            return False
        with self.lock:
            self.browser[event["id"]] = event
        return True

    def snapshot(self):
        timestamp = now_ms()
        tasks = collect_codex(self.codex_home, timestamp)
        tasks.extend(collect_claude(self.claude_home, self.desktop_home, timestamp))
        with self.lock:
            for key, event in list(self.browser.items()):
                age = timestamp - event["seen_ms"]
                if age > WEB_DROP_SECONDS * 1000:
                    del self.browser[key]
                    continue
                copy = {k: v for k, v in event.items() if k != "seen_ms"}
                if age > WEB_LIVE_SECONDS * 1000:
                    copy["status"] = "unknown"
                    copy["detail"] = "标签页最近未回报"
                tasks.append(copy)
        order = {"working": 0, "waiting": 1, "failed": 2, "unknown": 3, "idle": 4, "done": 5}
        tasks.sort(key=lambda task: (order.get(task["status"], 6), task["family"], task["title"]))
        result = {"generated_at": iso_from_ms(timestamp), "tasks": tasks}
        atomic_json(self.home / "tasks.json", result)
        return result


def make_handler(collector):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return

        def permitted_origin(self):
            origin = self.headers.get("Origin")
            return origin is None or origin.startswith(("chrome-extension://", "edge-extension://"))

        def send_headers(self, status):
            self.send_response(status)
            origin = self.headers.get("Origin")
            if origin and self.permitted_origin():
                self.send_header("Access-Control-Allow-Origin", origin)
                self.send_header("Vary", "Origin")
                self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
                self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Content-Type", "application/json")
            self.end_headers()

        def do_OPTIONS(self):
            self.send_headers(204 if self.permitted_origin() else 403)

        def do_POST(self):
            if self.path != "/event" or not self.permitted_origin():
                self.send_headers(403)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 65536:
                    raise ValueError("length")
                payload = json.loads(self.rfile.read(length))
            except (ValueError, UnicodeError):
                self.send_headers(400)
                return
            self.send_headers(204 if collector.receive(payload) else 400)

    return Handler


def main():
    parser = argparse.ArgumentParser(description="Local task feed for Agent Pet")
    parser.add_argument("--once", action="store_true", help="write one snapshot and exit")
    parser.add_argument("--parent-pid", type=int, help="exit if the owning app exits")
    args = parser.parse_args()
    collector = Collector()
    if args.once:
        collector.snapshot()
        return
    server = ThreadingHTTPServer(("127.0.0.1", PORT), make_handler(collector))
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        while True:
            if args.parent_pid and os.getppid() != args.parent_pid:
                break
            collector.snapshot()
            time.sleep(POLL_SECONDS)
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
