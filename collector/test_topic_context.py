import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from topic_context import MAX_CONTEXT_CHARS, _CLAUDE_CACHE, topic_contexts


def codex_item(text):
    return json.dumps({"type": "userMessage", "content": [{"type": "text", "text": text}]})


class TopicContextTests(unittest.TestCase):
    def setUp(self):
        _CLAUDE_CACHE.clear()
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.codex_home = self.root / "codex"
        self.claude_home = self.root / "claude"
        self.codex_home.mkdir()
        self.claude_home.mkdir()

    def _codex_fixtures(self):
        state = sqlite3.connect(self.codex_home / "state_5.sqlite")
        state.execute("CREATE TABLE threads (id TEXT, first_user_message TEXT, agent_path TEXT)")
        state.execute("CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT)")
        state.executemany("INSERT INTO threads VALUES (?, ?, ?)", [
            ("parent", "开发 GPT 交易系统的软件功能", None),
            ("child-path", "子代理私有提示词", "/root/child"),
            ("child-edge", "子代理私有提示词", None),
        ])
        state.execute("INSERT INTO thread_spawn_edges VALUES ('parent', 'child-edge')")
        state.commit()
        state.close()
        history = sqlite3.connect(self.codex_home / "thread_history_1.sqlite")
        history.execute("CREATE TABLE thread_items (thread_id TEXT, item_type TEXT, rollout_ordinal INTEGER, item_json TEXT)")
        history.executemany("INSERT INTO thread_items VALUES (?, ?, ?, ?)", [
            ("parent", "userMessage", 1, codex_item("开发 GPT 交易系统的软件功能")),
            ("parent", "userMessage", 2, codex_item("<in-app-browser-context>private browser URL</in-app-browser-context>现在改进交易系统的数据层采集")),
            ("parent", "userMessage", 3, codex_item("继续")),
            ("parent", "userMessage", 4, codex_item("<send_user_message_question_reply>[{\"answer\":\"增加本地行情缓存\"}]</send_user_message_question_reply>")),
            ("child-path", "userMessage", 1, codex_item("child path secret")),
            ("child-edge", "userMessage", 1, codex_item("child edge secret")),
        ])
        history.commit()
        history.close()

    def test_codex_uses_top_level_user_prompts_and_filters_child_threads(self):
        self._codex_fixtures()
        tasks = [
            {"id": "codex:parent", "source": "Codex", "title": "交易系统", "family": "Trade"},
            {"id": "codex:child-path", "source": "Codex", "title": "Child", "family": "Trade"},
            {"id": "codex:child-edge", "source": "Codex", "title": "Child", "family": "Trade"},
        ]
        contexts = topic_contexts(tasks, self.codex_home, self.claude_home)
        self.assertEqual(set(contexts), {"codex:parent"})
        context = contexts["codex:parent"]["context"]
        self.assertIn("开发 GPT 交易系统的软件功能", context)
        self.assertIn("交易系统的数据层采集", context)
        self.assertIn("增加本地行情缓存", context)
        self.assertNotIn("private browser URL", context)
        self.assertNotIn("继续", context)
        self.assertNotIn("子代理", context)
        self.assertLessEqual(len(context), MAX_CONTEXT_CHARS)

    def test_claude_reads_only_plain_top_level_user_prompts_and_caches(self):
        project = self.claude_home / "projects" / "work"
        project.mkdir(parents=True)
        transcript = project / "main.jsonl"
        events = [
            {"type": "user", "isSidechain": False, "message": {"content": "补充 Alignment 实验与基线对比"}},
            {"type": "user", "isSidechain": False, "message": {"content": [{"type": "tool_result", "content": "PRIVATE TOOL RESULT"}]}},
            {"type": "user", "isMeta": True, "message": {"content": "PRIVATE META PROMPT"}},
            {"type": "user", "isSidechain": True, "message": {"content": "PRIVATE SIDECHAIN PROMPT"}},
            {"type": "assistant", "message": {"content": "PRIVATE ASSISTANT RESPONSE"}},
            {"type": "ai-title", "aiTitle": "Alignment experiments"},
            {"type": "custom-title", "customTitle": "Alignment 实验"},
            {"type": "user", "message": {"content": "对照组需要增加随机初始化和样本量报告"}},
        ]
        transcript.write_text("".join(json.dumps(event) + "\n" for event in events))
        child_dir = project / "main" / "subagents"
        child_dir.mkdir(parents=True)
        (child_dir / "agent-child.jsonl").write_text(json.dumps({"type": "user", "message": {"content": "CHILD SECRET"}}) + "\n")
        tasks = [
            {"id": "claude-code:main", "source": "Claude Code", "title": "Claude Code · main", "family": "Alignment"},
            {"id": "claude-agent:child", "source": "Claude Code", "title": "Child", "family": "Alignment"},
        ]
        contexts = topic_contexts(tasks, self.codex_home, self.claude_home)
        self.assertEqual(set(contexts), {"claude-code:main"})
        value = contexts["claude-code:main"]
        self.assertEqual(value["title"], "Alignment 实验")
        self.assertIn("补充 Alignment 实验", value["context"])
        self.assertIn("增加随机初始化", value["context"])
        for excluded in ("PRIVATE TOOL RESULT", "PRIVATE META PROMPT", "PRIVATE SIDECHAIN PROMPT", "PRIVATE ASSISTANT RESPONSE", "CHILD SECRET"):
            self.assertNotIn(excluded, value["context"])

        # An unchanged file is served from the stat-signature cache.
        with patch.object(Path, "open", side_effect=AssertionError("rescanned transcript")):
            self.assertEqual(topic_contexts(tasks, self.codex_home, self.claude_home), contexts)

        with transcript.open("a") as handle:
            handle.write(json.dumps({"type": "user", "message": {"content": "检查 THE 对比 WE 的理论优势"}}) + "\n")
        updated = topic_contexts(tasks, self.codex_home, self.claude_home)
        self.assertIn("THE 对比 WE", updated["claude-code:main"]["context"])

    def test_web_uses_title_only_and_large_local_prompts_are_bounded(self):
        self._codex_fixtures()
        state = sqlite3.connect(self.codex_home / "state_5.sqlite")
        state.execute("INSERT INTO threads VALUES (?, ?, ?)", ("long", "首轮任务：" + "甲" * 20_000, None))
        state.commit()
        state.close()
        history = sqlite3.connect(self.codex_home / "thread_history_1.sqlite")
        history.execute("INSERT INTO thread_items VALUES (?, ?, ?, ?)", ("long", "userMessage", 1, codex_item("首轮任务：" + "甲" * 20_000)))
        history.execute("INSERT INTO thread_items VALUES (?, ?, ?, ?)", ("long", "userMessage", 2, codex_item("近期任务：" + "乙" * 20_000)))
        history.commit()
        history.close()
        tasks = [
            {"id": "codex:long", "source": "Codex", "title": "Very long", "family": "Long"},
            {"id": "web:chatgpt:abc", "source": "ChatGPT", "title": "大单净量与价格关系", "family": "ChatGPT 网页", "body": "PRIVATE BROWSER BODY"},
        ]
        contexts = topic_contexts(tasks, self.codex_home, self.claude_home)
        self.assertLessEqual(len(contexts["codex:long"]["context"]), MAX_CONTEXT_CHARS)
        self.assertIn("首轮任务", contexts["codex:long"]["context"])
        self.assertIn("近期任务", contexts["codex:long"]["context"])
        self.assertEqual(contexts["web:chatgpt:abc"]["title"], "大单净量与价格关系")
        self.assertEqual(contexts["web:chatgpt:abc"]["context"], "")
        self.assertNotIn("PRIVATE BROWSER BODY", str(contexts))


if __name__ == "__main__":
    unittest.main()
