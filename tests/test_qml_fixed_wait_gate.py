#!/usr/bin/env python3
"""qml_fixed_wait_gate.py 的自检：该拦的写法都拦、注释与字符串里的文字不误报、仓库现状通过。"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR / "tests"))

from qml_fixed_wait_gate import check_tree  # noqa: E402


class QmlFixedWaitGateTests(unittest.TestCase):
    def setUp(self) -> None:
        # 反例写进临时目录，不改仓库里的测试；门禁只认传进去的根目录。
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _problems(self, name: str, body: str) -> list[str]:
        (self.root / name).write_text(body, encoding="utf-8")
        return check_tree(self.root)

    def test_repository_tests_pass(self) -> None:
        """保证仓库里现有的 QML 测试都已改完，门禁上线当天就是绿的。"""
        self.assertEqual(check_tree(ROOT_DIR / "tests" / "qml"), [])

    def test_every_direct_wait_form_is_rejected(self) -> None:
        """保证裸 wait、带对象的 wait、qWait、带分号和表达式参数的写法都被拦下，并报出所在行。"""
        for line in ("wait(100)", "testCase.wait(20);", "wait(shortTip.delay + 300);",
                     "if (x) wait(0)", "  qWait(5)", "testCase . wait (10)"):
            with self.subTest(line=line):
                problems = self._problems("tst_x.qml", "import QtTest\n\n" + line + "\n")
                self.assertEqual(len(problems), 1, problems)
                self.assertIn("tst_x.qml:3:", problems[0])

    def test_comments_strings_and_lookalikes_are_not_calls(self) -> None:
        """保证注释、字符串里提到 wait(…)，以及 waitForRendering 这类名字相近的函数不会误报。"""
        body = ("// 原来这里是 wait(100)\n"
                "/* wait(20)\n   跨行注释 */\n"
                "var s = \"别写 wait(50)\"\n"
                "verify(waitForItemPolished(item))\n"
                "verify(waitForRendering(item))\n"
                "tryCompare(obj, \"waiting\", true)\n"
                "function awaitDone() { return true }\n"
                "awaitDone()\n")
        self.assertEqual(self._problems("tst_ok.qml", body), [])

    def test_helper_requires_literal_reason(self) -> None:
        """保证 TestWaits 调用缺原因、原因为空白或不是字面量时被拦下，写明原因的调用放行。"""
        bad = ("TestWaits.observe(testCase, 100)", "TestWaits.letElapse(testCase, 0, \"  \")",
               "TestWaits.observe(testCase, 60, reasonVar)")
        for call in bad:
            with self.subTest(call=call):
                self.assertEqual(len(self._problems("tst_h.qml", call + "\n")), 1)
        good = "TestWaits.observe(testCase, 60, \"确认排队刷新没有发生，没有信号可等\")\n"
        self.assertEqual(self._problems("tst_h.qml", good), [])

    def test_only_test_waits_helper_is_exempt(self) -> None:
        """保证豁免只给 TestWaits.js 本身：别的 .js 辅助文件里的直接等待同样被拦。"""
        (self.root / "TestWaits.js").write_text("function f(t) { t.wait(1) }\n", encoding="utf-8")
        self.assertEqual(check_tree(self.root), [])
        problems = self._problems("Helpers.js", "function g(t) { t.wait(1) }\n")
        self.assertEqual(len(problems), 1)
        self.assertIn("Helpers.js:1:", problems[0])

    def test_template_regex_and_concat_bypasses_are_rejected(self) -> None:
        """保证模板字符串插值、带单引号的正则字面量与拼接表达式无法绕过固定等待门禁。"""
        samples = {
            "tpl.qml": "import QtQuick\nItem { property string s: `${wait(500)}` }\n",
            "regex.js": "var re = /don't/;\nwait(500);\nvar end = \"'\";\n",
            "concat.qml": 'import QtQuick\nItem { function f() { TestWaits.letElapse(testCase, 50, "" + dynamicVar + "") } }\n',
        }
        for name, body in samples.items():
            with self.subTest(sample=name):
                sub = self.root / name.replace(".", "_")
                sub.mkdir()
                (sub / name).write_text(body, encoding="utf-8")
                problems = check_tree(sub)
                self.assertEqual(len(problems), 1, problems)

    def test_division_slashes_do_not_trigger_false_regex(self) -> None:
        """保证除法斜杠不会误判为正则字面量而吞掉字符串引号或误报，且第三参旁带行内注释仍正常放行。"""
        body = 'var ratio = a / b + c / d;\nvar msg = "not wait(100)";\nTestWaits.observe(tc, 20, /* 理由 */ "除法后字符串字面量保持完整");\n'
        self.assertEqual(self._problems("Division.js", body), [])


if __name__ == "__main__":
    unittest.main()
