#!/usr/bin/env python3
"""architecture_gate.py 中 R9 规则（服务单例只减不增）的自动回归测试。"""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR / "tests"))

from architecture_gate import SINGLETON_ALLOWLIST, check_singletons_r9, find_singletons  # noqa: E402


class ArchitectureGateR9Tests(unittest.TestCase):
    def setUp(self) -> None:
        # 反例都写进临时目录里的头文件，不改产品源码；门禁只认传进去的根目录。
        self.temp_dir = tempfile.TemporaryDirectory()
        self.src = Path(self.temp_dir.name) / "src"
        (self.src / "services").mkdir(parents=True)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _write_header(self, name: str, content: str) -> None:
        (self.src / "services" / name).write_text(content, encoding="utf-8")

    def _run_quietly(self, allowlist: frozenset[str]) -> tuple[bool, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            ok = check_singletons_r9(self.src, allowlist)
        return ok, out.getvalue(), err.getvalue()

    def test_allowlist_matches_current_source_tree(self) -> None:
        """保证白名单与仓库现有的单例逐个一致：多一个说明有新增漏拦，少一个说明名单留着可被复用的空位。"""
        found = find_singletons(ROOT_DIR / "src")
        self.assertIsNotNone(found)
        self.assertEqual(set(found), set(SINGLETON_ALLOWLIST))
        self.assertTrue(check_singletons_r9(ROOT_DIR / "src"))

    def test_new_singleton_is_rejected(self) -> None:
        """保证在白名单外新增 instance() 单例会让门禁失败，并在错误里点名这个类和替代做法。"""
        self._write_header("Existing.h", "class Existing { public: static Existing* instance(); };\n")
        self._write_header("Fresh.h", "class FreshService {\npublic:\n    static FreshService *instance ( );\n};\n")
        ok, _, err = self._run_quietly(frozenset({"Existing"}))
        self.assertFalse(ok)
        self.assertIn("FreshService", err)
        self.assertIn("SharedApp/AppServices", err)
        self.assertNotIn("Existing::instance", err)

    def test_declaration_variants_are_detected(self) -> None:
        """保证 const 返回、命名空间限定和多余空白的写法同样算单例，不能换个写法绕过门禁。"""
        self._write_header(
            "Variants.h",
            "class A { static const A* instance(); };\n"
            "class B { static  pt::detail::B   *   instance(   ); };\n",
        )
        found = find_singletons(self.src)
        self.assertEqual(set(found), {"A", "B"})
        ok, _, err = self._run_quietly(frozenset({"A"}))
        self.assertFalse(ok)
        self.assertIn("B::instance", err)

    def test_comments_and_non_singletons_are_ignored(self) -> None:
        """保证注释里的示例、带参数的工厂函数和类外定义不被当成新增单例，现状照常通过。"""
        self._write_header(
            "Quiet.h",
            "// 旧写法：static Legacy* instance();\n"
            "/* static Another* instance(); */\n"
            "class Factory { static Factory* instance(int id); };\n"
            "inline Kept* Kept::instance() { return nullptr; }\n"
            "class Kept { static Kept* instance(); };\n",
        )
        self.assertEqual(set(find_singletons(self.src)), {"Kept"})
        ok, _, err = self._run_quietly(frozenset({"Kept"}))
        self.assertTrue(ok, err)

    def test_removed_singleton_passes_with_hint(self) -> None:
        """保证白名单里的类迁移掉单例后门禁仍通过，并提示把它从名单里删掉。"""
        self._write_header("Kept.h", "class Kept { static Kept* instance(); };\n")
        ok, out, err = self._run_quietly(frozenset({"Kept", "Migrated"}))
        self.assertTrue(ok, err)
        self.assertIn("Migrated", out)
        self.assertIn("SINGLETON_ALLOWLIST", out)
        self.assertNotIn("Kept", out)


if __name__ == "__main__":
    unittest.main()
