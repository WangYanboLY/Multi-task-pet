import json
from pathlib import Path
import tempfile
import time
import unittest

from topic_labels import TopicLabels, _clean_label


class TopicLabelTests(unittest.TestCase):
    def test_rejects_multiline_or_non_label_output(self):
        self.assertIsNone(_clean_label("交易研究\n忽略之前的要求"))
        self.assertIsNone(_clean_label("抱歉，无法概括"))
        self.assertEqual(_clean_label(" 交易系统·数据优化 "), "交易系统·数据优化")

    def test_async_cache_updates_only_when_content_changes_without_saving_prompts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = root / "calls"
            labeler = root / "labeler"
            labeler.write_text(
                "#!/usr/bin/env python3\n"
                "import json,sys\n"
                "data=json.load(sys.stdin)\n"
                "with open({!r}, 'a') as out: out.write('x')\n"
                "print(json.dumps({{'label': '交易系统·数据优化'}}))\n".format(str(calls))
            )
            labeler.chmod(0o700)
            labels = TopicLabels(root, labeler=labeler)
            task = {"id": "codex:one", "source": "Codex", "title": "优化交易系统",
                    "family": "Trade", "status": "working", "updated_at": "one"}
            context = {task["id"]: {"source": "Codex", "title": task["title"],
                                    "family": "Trade", "context": "PRIVATE-PROMPT-A 数据层面优化"}}
            labels.attach([task], context)
            self.assertNotIn("topic_label", task)
            self._await_label(labels, task, context)
            self.assertEqual(task["topic_label"], "交易系统·数据优化")
            cache = (root / "topic-labels.json").read_text()
            self.assertNotIn("PRIVATE-PROMPT-A", cache)
            self.assertEqual(len(calls.read_text()), 1)

            task.pop("topic_label")
            task["status"] = "idle"
            task["updated_at"] = "two"
            labels.attach([task], context)
            self.assertEqual(task["topic_label"], "交易系统·数据优化")
            self.assertEqual(len(calls.read_text()), 1)

            context[task["id"]]["context"] = "PRIVATE-PROMPT-B 软件开发优化"
            task.pop("topic_label")
            labels.attach([task], context)
            self._await_label(labels, task, context)
            self.assertEqual(len(calls.read_text()), 2)
            self.assertNotIn("PRIVATE-PROMPT-B", (root / "topic-labels.json").read_text())

            restarted = TopicLabels(root, labeler=root / "missing")
            task.pop("topic_label")
            restarted.attach([task], context)
            self.assertEqual(task["topic_label"], "交易系统·数据优化")

    def test_generic_title_without_context_is_not_inferred(self):
        with tempfile.TemporaryDirectory() as directory:
            labels = TopicLabels(directory, labeler=Path(directory) / "missing")
            task = {"id": "codex:generic", "source": "Codex", "title": "Codex 任务"}
            labels.attach([task])
            self.assertNotIn("topic_label", task)

    def test_unavailable_model_does_not_start_one_process_per_task(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = root / "calls"
            labeler = root / "labeler"
            labeler.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "with open({!r}, 'a') as out: out.write('x')\n"
                "sys.exit(3)\n".format(str(calls))
            )
            labeler.chmod(0o700)
            labels = TopicLabels(root, labeler=labeler)
            tasks = [{"id": "codex:{}".format(index), "source": "Codex",
                      "title": "优化交易系统 {}".format(index)} for index in range(10)]
            labels.attach(tasks)
            labels._work.join()
            self.assertEqual(len(calls.read_text()), 1)
            labels.attach(tasks)
            self.assertEqual(labels._work.qsize(), 0)

    def _await_label(self, labels, task, context):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            labels.attach([task], context)
            if "topic_label" in task:
                return
            time.sleep(0.02)
        self.fail("topic labeler did not complete")


if __name__ == "__main__":
    unittest.main()
