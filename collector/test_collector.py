import json
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import os
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
import unittest

from collector import Collector, claude_task_progress, collect_claude, collect_codex, make_handler, now_ms, scheduled_codex_task_ids, validate_web_event


class CollectorTests(unittest.TestCase):
    def test_scheduled_codex_target_is_tagged_without_hiding_task(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "codex"
            home.mkdir()
            target = "11111111-1111-1111-1111-111111111111"
            ordinary = "22222222-2222-2222-2222-222222222222"
            automation = home / "automations" / "heartbeat"
            automation.mkdir(parents=True)
            (automation / "automation.toml").write_text(
                'kind = "heartbeat"\ntarget_thread_id = "{}"\n'.format(target))
            cron = home / "automations" / "cron"
            cron.mkdir()
            (cron / "automation.toml").write_text('kind = "cron"\nname = "Ordinary task"\n')

            state = sqlite3.connect(home / "state_5.sqlite")
            state.execute("CREATE TABLE threads (id TEXT, cwd TEXT, title TEXT, name TEXT, agent_nickname TEXT, agent_path TEXT, updated_at INTEGER, updated_at_ms INTEGER, recency_at_ms INTEGER, archived INTEGER)")
            state.execute("CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT)")
            history = sqlite3.connect(home / "thread_history_1.sqlite")
            history.execute("CREATE TABLE thread_turns (thread_id TEXT, status TEXT, started_at INTEGER, completed_at INTEGER, rollout_ordinal INTEGER)")
            current = now_ms()
            for identifier in (target, ordinary):
                state.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?)",
                              (identifier, directory, "Ordinary task", None, None, None,
                               current // 1000, current, current, 0))
                history.execute("INSERT INTO thread_turns VALUES (?,?,?,?,?)",
                                (identifier, "failed", (current - 1000) // 1000, None, 1))
            state.commit()
            history.commit()
            state.close()
            history.close()

            self.assertEqual(scheduled_codex_task_ids(home), {"codex:" + target})
            snapshot = Collector(home=root / "out", codex_home=home,
                                 claude_home=root / "claude", desktop_home=root / "desktop").snapshot()
            self.assertEqual(snapshot["scheduled_task_ids"], ["codex:" + target])
            self.assertEqual({task["id"] for task in snapshot["tasks"]},
                             {"codex:" + target, "codex:" + ordinary})

    def test_codex_requires_fresh_turn_and_thread(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            state = sqlite3.connect(home / "state_5.sqlite")
            state.execute("CREATE TABLE threads (id TEXT, cwd TEXT, title TEXT, name TEXT, agent_nickname TEXT, agent_path TEXT, updated_at INTEGER, updated_at_ms INTEGER, recency_at_ms INTEGER, archived INTEGER)")
            state.execute("CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT)")
            history = sqlite3.connect(home / "thread_history_1.sqlite")
            history.execute("CREATE TABLE thread_turns (thread_id TEXT, status TEXT, started_at INTEGER, completed_at INTEGER, rollout_ordinal INTEGER)")
            current = now_ms()
            for identifier, started in (("fresh", current - 20_000), ("stale", current - 7 * 86400_000)):
                state.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?)", (identifier, directory, identifier, None, None, None, current // 1000, current, current, 0))
                history.execute("INSERT INTO thread_turns VALUES (?,?,?,?,?)", (identifier, "inProgress", started // 1000, None, 1))
            state.commit()
            history.commit()
            state.close()
            history.close()
            tasks = collect_codex(home, current)
            self.assertEqual([task["id"] for task in tasks], ["codex:fresh"])
            self.assertEqual(tasks[0]["status"], "working")

    def test_codex_revision_requires_completed_turn_and_ignores_metadata_touch(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            state = sqlite3.connect(home / "state_5.sqlite")
            state.execute("CREATE TABLE threads (id TEXT, cwd TEXT, title TEXT, name TEXT, agent_nickname TEXT, agent_path TEXT, updated_at INTEGER, updated_at_ms INTEGER, recency_at_ms INTEGER, archived INTEGER)")
            state.execute("CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT)")
            history = sqlite3.connect(home / "thread_history_1.sqlite")
            history.execute("CREATE TABLE thread_turns (thread_id TEXT, status TEXT, started_at INTEGER, completed_at INTEGER, rollout_ordinal INTEGER)")
            current = now_ms()
            for identifier, turn_status in (("complete", "completed"), ("interrupted", "interrupted"), ("failed", "failed")):
                state.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?)", (identifier, directory, identifier, None, None, None, current // 1000, current, current, 0))
                history.execute("INSERT INTO thread_turns VALUES (?,?,?,?,?)", (identifier, turn_status, (current - 20_000) // 1000, current // 1000 if turn_status == "completed" else None, 3))
            state.commit()
            history.commit()
            by_id = {item["id"]: item for item in collect_codex(home, current)}
            self.assertEqual(by_id["codex:complete"]["answer_revision"], "3:{}".format(current // 1000))
            self.assertNotIn("answer_revision", by_id["codex:interrupted"])
            self.assertNotIn("answer_revision", by_id["codex:failed"])

            state.execute("UPDATE threads SET updated_at_ms = ? WHERE id = ?", (current + 1000, "complete"))
            state.commit()
            touched = {item["id"]: item for item in collect_codex(home, current + 1000)}
            self.assertEqual(touched["codex:complete"]["answer_revision"], by_id["codex:complete"]["answer_revision"])
            history.execute("INSERT INTO thread_turns VALUES (?,?,?,?,?)", ("complete", "completed", current // 1000, current // 1000 + 2, 4))
            history.commit()
            newer = {item["id"]: item for item in collect_codex(home, current + 2000)}
            self.assertEqual(newer["codex:complete"]["answer_revision"], "4:{}".format(current // 1000 + 2))
            state.close()
            history.close()

    def test_codex_omits_subagents_before_limits_and_exports_old_child_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "codex"
            home.mkdir()
            state = sqlite3.connect(home / "state_5.sqlite")
            state.execute("CREATE TABLE threads (id TEXT, cwd TEXT, title TEXT, name TEXT, agent_nickname TEXT, agent_path TEXT, updated_at INTEGER, updated_at_ms INTEGER, recency_at_ms INTEGER, archived INTEGER)")
            state.execute("CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT)")
            history = sqlite3.connect(home / "thread_history_1.sqlite")
            history.execute("CREATE TABLE thread_turns (thread_id TEXT, status TEXT, started_at INTEGER, completed_at INTEGER, rollout_ordinal INTEGER)")
            current = now_ms()

            def add_thread(identifier, updated, title, agent_path=None, edge=False, with_turn=True):
                state.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?)",
                              (identifier, directory, title, None, None, agent_path,
                               updated // 1000, updated, updated, 0))
                if edge:
                    state.execute("INSERT INTO thread_spawn_edges VALUES (?,?)", ("top-0", identifier))
                if with_turn:
                    history.execute("INSERT INTO thread_turns VALUES (?,?,?,?,?)",
                                    (identifier, "completed", (updated - 1000) // 1000,
                                     updated // 1000, 1))

            # More than the SQL row limit are newer child threads. The two
            # independent child signals are both represented, including a
            # child with a normal-looking title.
            for index in range(360):
                identifier = "child-{}".format(index)
                add_thread(identifier, current - (index + 1) * 1000,
                           "Named task" if index == 0 else None,
                           agent_path="/root/child" if index % 2 else None,
                           edge=index % 2 == 0)
            for index in range(10):
                add_thread("top-{}".format(index), current - 600_000 - index * 1000,
                           None if index == 0 else "Top task {}".format(index))
            add_thread("old-child", current - 2 * 86400_000, "Older child",
                       agent_path="/root/old", with_turn=False)
            state.commit()
            history.commit()
            state.close()
            history.close()

            ignored = set()
            tasks = collect_codex(home, current, ignored)
            self.assertEqual([item["id"] for item in tasks],
                             ["codex:top-{}".format(index) for index in range(8)])
            self.assertEqual(tasks[0]["title"], "Codex 任务")
            self.assertEqual(len(ignored), 361)
            self.assertIn("codex:child-0", ignored)
            self.assertIn("codex:child-1", ignored)
            self.assertIn("codex:old-child", ignored)

            snapshot = Collector(home=root / "out", codex_home=home,
                                 claude_home=root / "claude", desktop_home=root / "desktop").snapshot()
            self.assertEqual(snapshot["ignored_task_ids"], sorted(ignored))
            self.assertEqual(json.loads((root / "out" / "tasks.json").read_text())["ignored_task_ids"],
                             sorted(ignored))

    def test_claude_uses_live_pid_and_does_not_call_idle_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sessions = root / "claude" / "sessions"
            sessions.mkdir(parents=True)
            timestamp = now_ms()
            (sessions / "current.json").write_text(json.dumps({
                "pid": os.getpid(), "sessionId": "live", "cwd": directory,
                "entrypoint": "cli", "status": "idle", "statusUpdatedAt": timestamp,
            }))
            (sessions / "desktop.json").write_text(json.dumps({
                "pid": os.getpid(), "sessionId": "desktop", "cwd": directory,
                "entrypoint": "claude-desktop", "status": "busy", "statusUpdatedAt": timestamp,
            }))
            child_dir = root / "claude" / "projects" / "work" / "live" / "subagents"
            child_dir.mkdir(parents=True)
            (child_dir / "agent-child.meta.json").write_text(json.dumps({"description": "Child work"}))
            (child_dir / "agent-child.jsonl").write_text("{}\n")
            tasks = collect_claude(root / "claude", root / "desktop", timestamp)
            self.assertEqual(len(tasks), 2)
            self.assertTrue(all(not task["id"].startswith("claude-agent:") for task in tasks))
            by_id = {task["id"]: task for task in tasks}
            self.assertEqual(by_id["claude-code:live"]["source"], "Claude Code")
            self.assertEqual(by_id["claude-code:live"]["status"], "idle")
            self.assertIn("这一轮已结束", by_id["claude-code:live"]["detail"])
            self.assertEqual(by_id["claude-code:live"]["answer_revision"], str(timestamp))
            self.assertEqual(by_id["claude-code:desktop"]["source"], "Claude")
            self.assertEqual(by_id["claude-code:desktop"]["status"], "working")
            self.assertNotIn("answer_revision", by_id["claude-code:desktop"])

    def test_claude_revision_requires_explicit_fresh_idle_status_time(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sessions = root / "claude" / "sessions"
            sessions.mkdir(parents=True)
            timestamp = now_ms()
            for identifier, status_time, update_time in (
                ("fresh", timestamp - 1000, timestamp),
                ("fallback", None, timestamp),
                ("stale", timestamp - 7 * 60 * 60 * 1000, timestamp),
            ):
                data = {"pid": os.getpid(), "sessionId": identifier, "cwd": directory,
                        "entrypoint": "cli", "status": "idle", "updatedAt": update_time}
                if status_time is not None:
                    data["statusUpdatedAt"] = status_time
                (sessions / (identifier + ".json")).write_text(json.dumps(data))
            by_id = {item["id"]: item for item in collect_claude(root / "claude", root / "desktop", timestamp)}
            self.assertEqual(by_id["claude-code:fresh"]["answer_revision"], str(timestamp - 1000))
            self.assertNotIn("answer_revision", by_id["claude-code:fallback"])
            self.assertNotIn("answer_revision", by_id["claude-code:stale"])

    def test_web_events_validate_origin_data_and_expire(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collector = Collector(home=root / "out", codex_home=root / "codex", claude_home=root / "claude", desktop_home=root / "desktop")
            event = {"source": "ChatGPT", "id": "conversation-1", "url": "https://chatgpt.com/c/1", "title": "A task", "status": "working"}
            self.assertIsNone(validate_web_event({**event, "url": "https://attacker.test/c/1"}, now_ms()))
            self.assertFalse(collector.receive({**event, "source": "Claude"}))
            self.assertTrue(collector.receive(event))
            self.assertEqual(collector.snapshot()["tasks"][0]["status"], "working")
            for value in collector.browser.values():
                value["seen_ms"] = now_ms() - 40_000
            self.assertEqual(collector.snapshot()["tasks"][0]["status"], "unknown")
            self.assertTrue((root / "out" / "tasks.json").is_file())

    def test_web_answer_revision_survives_heartbeats_without_false_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collector = Collector(home=root / "out", codex_home=root / "codex", claude_home=root / "claude", desktop_home=root / "desktop")
            event = {"source": "ChatGPT", "id": "conversation-1", "url": "https://chatgpt.com/c/1",
                     "title": "A task", "status": "idle", "answer_revision": str(now_ms() - 1000)}
            self.assertTrue(collector.receive(event))
            first = collector.snapshot()["tasks"][0]["answer_revision"]
            self.assertTrue(collector.receive(event))
            self.assertEqual(collector.snapshot()["tasks"][0]["answer_revision"], first)
            self.assertFalse(collector.receive({**event, "answer_revision": "not-a-revision"}))
            self.assertFalse(collector.receive({**event, "answer_revision": str(now_ms() + 60_000)}))
            self.assertTrue(collector.receive({**event, "answer_revision": str(now_ms())}))
            self.assertNotEqual(collector.snapshot()["tasks"][0]["answer_revision"], first)

    def test_claude_progress_counts_explicit_tasks_only(self):
        with tempfile.TemporaryDirectory() as directory:
            transcript = Path(directory) / "session.jsonl"
            stamp = "2026-09-22T20:00:00Z"
            events = [
                {"timestamp": stamp, "message": {"content": [{"name": "TaskCreate", "id": "a"}]}},
                {"timestamp": stamp, "message": {"content": [{"type": "tool_result", "tool_use_id": "a", "content": "Task #1 created"}]}},
                {"timestamp": stamp, "message": {"content": [{"name": "TaskCreate", "id": "b"}]}},
                {"timestamp": stamp, "message": {"content": [{"type": "tool_result", "tool_use_id": "b", "content": "Task #2 created"}]}},
                {"timestamp": stamp, "message": {"content": [{"name": "TaskUpdate", "input": {"taskId": "1", "status": "completed"}}]}},
            ]
            transcript.write_text("".join(json.dumps(event) + "\n" for event in events))
            current = int(time.mktime(time.strptime("2026-09-22T20:01:00Z", "%Y-%m-%dT%H:%M:%SZ")) * 1000)
            self.assertEqual(claude_task_progress(transcript, current), (1, 2))
            with transcript.open("a") as handle:
                handle.write(json.dumps({"timestamp": stamp, "message": {"content": [{"name": "TaskUpdate", "input": {"taskId": "2", "status": "completed"}}]}}) + "\n")
            self.assertEqual(claude_task_progress(transcript, current), (2, 2))

    def test_browser_bridge_accepts_extension_and_rejects_web_page(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collector = Collector(home=root / "out", codex_home=root / "codex", claude_home=root / "claude", desktop_home=root / "desktop")
            server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(collector))
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                event = {"source": "Claude", "id": "conversation-1", "url": "https://claude.ai/chat/1", "title": "A task", "status": "working"}
                connection = HTTPConnection("127.0.0.1", server.server_port)
                connection.request("POST", "/event", json.dumps(event), {"Content-Type": "application/json", "Origin": "https://claude.ai"})
                self.assertEqual(connection.getresponse().status, 403)
                connection.close()
                connection = HTTPConnection("127.0.0.1", server.server_port)
                connection.request("POST", "/event", json.dumps(event), {"Content-Type": "application/json", "Origin": "chrome-extension://test"})
                self.assertEqual(connection.getresponse().status, 204)
                connection.close()
                self.assertEqual(collector.snapshot()["tasks"][0]["source"], "Claude")
            finally:
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    unittest.main()
