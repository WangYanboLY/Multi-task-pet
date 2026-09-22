"""Build small, private topic inputs for the local conversation labeler.

Only user-authored text from top-level local sessions is read. Raw prompts are
kept in process memory and are never written to the collector snapshot.
"""

from collections import OrderedDict, deque
import json
from pathlib import Path
import re
import sqlite3


MAX_CONTEXT_CHARS = 4_000
FIRST_PROMPT_CHARS = 1_200
RECENT_PROMPT_CHARS = 1_300
MAX_CACHED_PROMPT_CHARS = 4_000
MAX_CLAUDE_CACHE_ENTRIES = 64

_AMBIENT = re.compile(r"<in-app-browser-context\b[^>]*>.*?</in-app-browser-context>", re.I | re.S)
_QUESTION_REPLY = re.compile(r"<send_user_message_question_reply>(.*?)</send_user_message_question_reply>", re.I | re.S)
_SPACE = re.compile(r"\s+")
_SESSION_ID = re.compile(r"^[A-Za-z0-9_-]{1,200}$")
_GENERIC_REPLIES = {"继续", "请继续", "好的", "好", "可以", "同意", "ok", "yes", "continue", "go on"}

# Values remain in memory only. The size and mtime signature prevents a full
# transcript scan on every three-second collector poll.
_CLAUDE_CACHE = OrderedDict()


def _question_answers(match):
    try:
        values = json.loads(match.group(1).strip())
    except (TypeError, ValueError):
        return " "
    if not isinstance(values, list):
        return " "
    answers = [value.get("answer") for value in values if isinstance(value, dict)]
    return " ".join(answer for answer in answers if isinstance(answer, str))


def _clean(value):
    if not isinstance(value, str):
        return ""
    value = _AMBIENT.sub(" ", value)
    value = _QUESTION_REPLY.sub(_question_answers, value)
    return _SPACE.sub(" ", value.replace("\x00", " ")).strip()


def _substantive(value):
    return len(value) >= 8 and value.casefold() not in _GENERIC_REPLIES


def _clip(value, limit):
    if len(value) <= limit:
        return value
    head = int((limit - 3) * 0.7)
    return value[:head].rstrip() + " … " + value[-(limit - head - 3):].lstrip()


def _context(first, recent):
    first = _clean(first)
    seen = {first} if first else set()
    latest = []
    for value in recent:
        value = _clean(value)
        if _substantive(value) and value not in seen:
            latest.append(value)
            seen.add(value)
    latest = latest[-2:]
    parts = []
    if first:
        parts.append("起始请求：" + _clip(first, FIRST_PROMPT_CHARS))
    for value in latest:
        parts.append("近期请求：" + _clip(value, RECENT_PROMPT_CHARS))
    return "\n".join(parts)[:MAX_CONTEXT_CHARS]


def _codex_text(item_json):
    try:
        item = json.loads(item_json)
    except (TypeError, ValueError):
        return ""
    content = item.get("content") if isinstance(item, dict) else None
    if not isinstance(content, list):
        return ""
    return _clean(" ".join(
        block.get("text", "") for block in content
        if isinstance(block, dict) and block.get("type") == "text"
        and isinstance(block.get("text"), str)
    ))


def _readonly_sqlite(path):
    if not path.is_file():
        return None
    try:
        connection = sqlite3.connect("file:{}?mode=ro".format(path.as_posix()), uri=True, timeout=0.5)
        connection.execute("PRAGMA query_only=ON")
        return connection
    except sqlite3.Error:
        return None


def _codex_contexts(tasks, codex_home):
    identifiers = {
        task["id"][len("codex:"):]
        for task in tasks if isinstance(task.get("id"), str)
        and task["id"].startswith("codex:")
    }
    if not identifiers:
        return {}
    state = _readonly_sqlite(Path(codex_home) / "state_5.sqlite")
    if state is None:
        return {}
    try:
        placeholders = ",".join("?" for _ in identifiers)
        rows = state.execute(
            "SELECT id, first_user_message FROM threads "
            "WHERE id IN ({}) AND COALESCE(agent_path, '') = '' "
            "AND NOT EXISTS (SELECT 1 FROM thread_spawn_edges AS e "
            "WHERE e.child_thread_id = threads.id)".format(placeholders),
            tuple(identifiers),
        ).fetchall()
    except sqlite3.Error:
        return {}
    finally:
        state.close()

    history = _readonly_sqlite(Path(codex_home) / "thread_history_1.sqlite")
    result = {}
    try:
        for identifier, first_user in rows:
            recent = []
            if history is not None:
                try:
                    values = history.execute(
                        "SELECT item_json FROM thread_items "
                        "WHERE thread_id = ? AND item_type = 'userMessage' "
                        "ORDER BY rollout_ordinal DESC LIMIT 24",
                        (identifier,),
                    ).fetchall()
                    recent = [_codex_text(row[0]) for row in reversed(values)]
                    if not first_user:
                        oldest = history.execute(
                            "SELECT item_json FROM thread_items "
                            "WHERE thread_id = ? AND item_type = 'userMessage' "
                            "ORDER BY rollout_ordinal ASC LIMIT 1",
                            (identifier,),
                        ).fetchone()
                        if oldest:
                            first_user = _codex_text(oldest[0])
                except sqlite3.Error:
                    pass
            result["codex:" + identifier] = _context(first_user, recent)
    finally:
        if history is not None:
            history.close()
    return result


def _claude_entry(path):
    try:
        stat = path.stat()
    except OSError:
        return None
    signature = (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)
    cached = _CLAUDE_CACHE.get(path)
    if cached and cached["signature"] == signature:
        _CLAUDE_CACHE.move_to_end(path)
        return cached

    append = (cached is not None and cached["signature"][:2] == signature[:2]
              and stat.st_size > cached["signature"][2]
              and stat.st_size >= cached["offset"])
    entry = dict(cached) if append else {
        "offset": 0, "first": "", "recent": deque(maxlen=24),
        "custom_title": "", "ai_title": "",
    }
    if append:
        entry["recent"] = deque(cached["recent"], maxlen=24)
    try:
        with path.open("rb") as handle:
            handle.seek(entry["offset"])
            while True:
                start = handle.tell()
                line = handle.readline()
                if not line:
                    break
                if not line.endswith(b"\n"):
                    handle.seek(start)
                    break
                try:
                    event = json.loads(line)
                except (UnicodeError, ValueError):
                    continue
                if not isinstance(event, dict):
                    continue
                kind = event.get("type")
                if kind == "user" and not event.get("isMeta") and not event.get("isSidechain"):
                    message = event.get("message")
                    content = message.get("content") if isinstance(message, dict) else None
                    # Claude writes tool results as user events with list
                    # content. Only plain-string user prompts are topic input.
                    if isinstance(content, str):
                        prompt = _clean(content)
                        if prompt:
                            prompt = _clip(prompt, MAX_CACHED_PROMPT_CHARS)
                            if not entry["first"]:
                                entry["first"] = prompt
                            entry["recent"].append(prompt)
                elif kind == "custom-title":
                    entry["custom_title"] = _clean(event.get("customTitle"))[:160]
                elif kind == "ai-title":
                    entry["ai_title"] = _clean(event.get("aiTitle"))[:160]
            entry["offset"] = handle.tell()
    except OSError:
        return None
    entry["signature"] = signature
    _CLAUDE_CACHE[path] = entry
    _CLAUDE_CACHE.move_to_end(path)
    while len(_CLAUDE_CACHE) > MAX_CLAUDE_CACHE_ENTRIES:
        _CLAUDE_CACHE.popitem(last=False)
    return entry


def _claude_contexts(tasks, claude_home):
    result = {}
    projects = Path(claude_home) / "projects"
    if not projects.is_dir():
        return result
    for task in tasks:
        task_id = task.get("id")
        if not isinstance(task_id, str) or not task_id.startswith("claude-code:"):
            continue
        session_id = task_id[len("claude-code:"):]
        if not _SESSION_ID.fullmatch(session_id):
            continue
        # Top-level transcripts are direct children of each project folder.
        # Claude subagents live in nested subagents/ folders, never globbed.
        path = next(projects.glob("*/{}.jsonl".format(session_id)), None)
        if path is None or path.is_symlink():
            continue
        entry = _claude_entry(path)
        if entry is None:
            continue
        result[task_id] = {
            "context": _context(entry["first"], entry["recent"]),
            "title": entry["custom_title"] or entry["ai_title"],
        }
    return result


def topic_contexts(tasks, codex_home, claude_home):
    """Return bounded inputs keyed by visible top-level task ID.

    Output records contain ``source``, ``title``, ``family``, and ``context``.
    Web tasks provide their existing title and an empty context; no browser
    message body is read.
    """
    codex = _codex_contexts(tasks, codex_home)
    claude = _claude_contexts(tasks, claude_home)
    result = {}
    for task in tasks:
        task_id = task.get("id")
        if not isinstance(task_id, str) or task_id.startswith("claude-agent:"):
            continue
        if task_id.startswith("codex:") and task_id not in codex:
            continue  # Excludes subagents even if an older task feed included one.
        title = _clean(task.get("title"))[:160]
        context = codex.get(task_id, "")
        if task_id in claude:
            title = claude[task_id]["title"] or title
            context = claude[task_id]["context"]
        result[task_id] = {
            "source": _clean(task.get("source"))[:40],
            "title": title,
            "family": _clean(task.get("family"))[:160],
            "context": context,
        }
    return result
