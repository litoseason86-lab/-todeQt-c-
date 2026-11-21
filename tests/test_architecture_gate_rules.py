#!/usr/bin/env python3
"""architecture_gate.py 的 R4/R5/R6/R7 与 MCP helper 清单反绕过自检。"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR / "tests"))

import architecture_gate  # noqa: E402


class ArchitectureGateRulesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(prefix="arch-rules-")
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        for sub in ("src/services", "src/models", "src/app", "src/qmlfacade", "src/entry/mac", "src/entry/ios", "src/mcp/helper", "src/mcp/common"):
            (self.root / sub).mkdir(parents=True, exist_ok=True)
        for entry in ("src/entry/mac/main.cpp", "src/entry/ios/main.cpp"):
            (self.root / entry).write_text(
                "int main(int argc, char** argv) {\n"
                "    QGuiApplication app(argc, argv);\n"
                "    McpPaths::applyApplicationIdentity();\n"
                "    return 0;\n"
                "}\n",
                encoding="utf-8",
            )

    def _run_gate(self, manifest_obj: dict) -> tuple[int, str, str]:
        manifest_path = self.root / "architecture-manifest.json"
        manifest_path.write_text(json.dumps(manifest_obj), encoding="utf-8")
        out, err = io.StringIO(), io.StringIO()
        argv_backup = sys.argv
        try:
            sys.argv = ["architecture_gate.py", str(manifest_path), str(self.root)]
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                rc = architecture_gate.main()
        finally:
            sys.argv = argv_backup
        return rc, out.getvalue(), err.getvalue()

    def _base_manifest(self) -> dict:
        return {
            "PTCore": {"sources": [], "link_libraries": ["Qt6::Core", "Qt6::Sql"], "interface_link_libraries": []},
            "PTApp": {"sources": [], "link_libraries": ["Qt6::Core", "PTCore"], "interface_link_libraries": []},
            "PTQml": {"sources": [], "link_libraries": ["Qt6::Core", "PTCore", "PTApp"], "interface_link_libraries": []},
            "PomodoroTodoMcp": {"sources": [], "link_libraries": ["Qt6::Core", "Qt6::Network"], "interface_link_libraries": []},
        }

    def test_r4_covers_all_sync_service_files_and_rejects_business_include(self) -> None:
        """保证仓库现有全部 15 个 Sync* 服务文件均纳入 R4 管辖，任何 071 同步核心文件禁止 include 业务管理器。"""
        actual_sync_stems = {p.stem for p in (ROOT_DIR / "src/services").glob("*Sync*.cpp")}
        tracked = set(architecture_gate.SYNC_CORE_FILES) | set(architecture_gate.SYNC_COORDINATOR_FILES)
        self.assertTrue(actual_sync_stems.issubset(tracked), f"R4 漏管同步文件: {sorted(actual_sync_stems - tracked)}")

        for stem in ("LocalSyncFolder", "RemoteSyncFolder", "SyncCrypto", "SyncPairing", "SyncServerWatcher", "SyncSchema"):
            with self.subTest(stem=stem):
                task_hdr = self.root / "src/services/TaskManager.h"
                task_hdr.write_text("class TaskManager {};\n", encoding="utf-8")
                src_file = self.root / f"src/services/{stem}.cpp"
                src_file.write_text('#include "TaskManager.h"\n', encoding="utf-8")
                manifest = self._base_manifest()
                manifest["PTCore"]["sources"] = [f"src/services/{stem}.cpp", "src/services/TaskManager.h"]
                rc, _, err = self._run_gate(manifest)
                self.assertNotEqual(rc, 0)
                self.assertIn("R4", err)

    def test_r4_rejects_transitive_local_header_smuggling(self) -> None:
        """保证同步核心文件通过白名单头文件（如 FocusSessionRules.h）传递 include 业务服务时仍被 R4 拦下。"""
        (self.root / "src/services/TaskManager.h").write_text("class TaskManager {};\n", encoding="utf-8")
        (self.root / "src/services/FocusSessionRules.h").write_text('#include "TaskManager.h"\n', encoding="utf-8")
        (self.root / "src/services/SyncStore.h").write_text('#include "FocusSessionRules.h"\n', encoding="utf-8")
        manifest = self._base_manifest()
        manifest["PTCore"]["sources"] = [
            "src/services/SyncStore.h",
            "src/services/FocusSessionRules.h",
            "src/services/TaskManager.h",
        ]
        rc, _, err = self._run_gate(manifest)
        self.assertNotEqual(rc, 0)
        self.assertIn("R4", err)

    def test_r5_r6_r7_forbids_apple_and_target_os_macros(self) -> None:
        """保证 PTCore/PTApp/PTQml 不允许使用 __APPLE__ 或 TARGET_OS_* 宏绕过平台宏禁令。"""
        cases = [
            ("PTCore", "src/services/DummyService.cpp", "#if defined(__APPLE__)\nint x;\n#endif\n", "R5"),
            ("PTCore", "src/services/PhaseSoundService.cpp", "#if TARGET_OS_OSX\nint x;\n#endif\n", "R5"),
            ("PTApp", "src/app/DummyApp.cpp", "#ifdef __APPLE__\nint x;\n#endif\n", "R6"),
            ("PTQml", "src/qmlfacade/DummyQml.cpp", "#if TARGET_OS_IPHONE\nint x;\n#endif\n", "R7"),
        ]
        for target, rel_path, content, rule_tag in cases:
            with self.subTest(target=target, rel_path=rel_path):
                f = self.root / rel_path
                f.write_text(content, encoding="utf-8")
                manifest = self._base_manifest()
                manifest[target]["sources"] = [rel_path]
                rc, _, err = self._run_gate(manifest)
                self.assertNotEqual(rc, 0)
                self.assertIn(rule_tag, err)

    def test_mcp_helper_manifest_rejects_forbidden_links_and_sources(self) -> None:
        """保证 PomodoroTodoMcp 不可通过清单静态链接 PTCore/SQLite3 或直接编入业务源码。"""
        helper_main = self.root / "src/mcp/helper/main.cpp"
        helper_main.write_text("int main() { return 0; }\n", encoding="utf-8")
        biz_cpp = self.root / "src/services/DatabaseManager.cpp"
        biz_cpp.write_text("int db_stub() { return 0; }\n", encoding="utf-8")

        m1 = self._base_manifest()
        m1["PomodoroTodoMcp"]["sources"] = ["src/mcp/helper/main.cpp"]
        m1["PomodoroTodoMcp"]["link_libraries"] = ["Qt6::Core", "Qt6::Network", "PTCore"]
        rc1, _, err1 = self._run_gate(m1)
        self.assertNotEqual(rc1, 0)
        self.assertIn("PomodoroTodoMcp", err1)

        m2 = self._base_manifest()
        m2["PomodoroTodoMcp"]["sources"] = ["src/mcp/helper/main.cpp", "src/services/DatabaseManager.cpp"]
        rc2, _, err2 = self._run_gate(m2)
        self.assertNotEqual(rc2, 0)
        self.assertIn("PomodoroTodoMcp", err2)

    def test_include_comment_and_line_continuation_bypasses_rejected(self) -> None:
        """保证块注释后接 #include、#include 内嵌块注释、以及反斜杠续行均无法绕过 R2/R4，且多行注释内的 #include 不误报。"""
        (self.root / "src/services/TaskManager.h").write_text("class TaskManager {};\n", encoding="utf-8")
        safe_sync = self.root / "src/services/SyncStore.cpp"
        safe_sync.write_text('/*\n#include "TaskManager.h"\n*/\nint ok = 1;\n', encoding="utf-8")
        manifest = self._base_manifest()
        manifest["PTCore"]["sources"] = ["src/services/SyncStore.cpp", "src/services/TaskManager.h"]
        rc_ok, _, err_ok = self._run_gate(manifest)
        self.assertEqual(rc_ok, 0, err_ok)

        for label, bad_line in (
            ("leading_block_comment", '/* comment */ #include "TaskManager.h"\n'),
            ("inline_block_comment", '#include /* comment */ "TaskManager.h"\n'),
            ("backslash_continuation", '#inc\\\nlude "TaskManager.h"\n'),
        ):
            with self.subTest(case=label):
                safe_sync.write_text(bad_line, encoding="utf-8")
                rc_bad, _, err_bad = self._run_gate(manifest)
                self.assertNotEqual(rc_bad, 0, f"{label} 绕过未被 R4 拦截")
                self.assertIn("R4", err_bad)


if __name__ == "__main__":
    unittest.main()
