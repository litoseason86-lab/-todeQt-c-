#!/usr/bin/env python3
"""QML 文本格式、悬停过渡、iPad 颜色、MCP 包体与 Helper 链接门禁的反绕过自检。"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR / "tests"))

import ios_cmake_manifest_gate  # noqa: E402
import qml_hover_transition_gate  # noqa: E402


class QmlTextFormatGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(prefix="qml-tf-gate-")
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)

    def _run_gate(self, path: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(ROOT_DIR / "tests/qml_text_format_gate.py"), str(path)],
            capture_output=True,
            text=True,
        )

    def test_repository_qml_passes(self) -> None:
        """保证仓库现有 qml/ 全部通过加固后的文本格式门禁。"""
        proc = self._run_gate(ROOT_DIR / "qml")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_bypass_forms_are_rejected(self) -> None:
        """保证单行、同一行分号、显式 AutoText、命令式赋值与内联派生组件均被拦下。"""
        bad_cases = {
            "single_line.qml": "import QtQuick\nText { text: userControlledTitle }\n",
            "semicolon_same_line.qml": "import QtQuick\nText {\n  id: lbl; text: userControlledTitle\n}\n",
            "explicit_autotext.qml": "import QtQuick\nText {\n  text: userControlledTitle\n  textFormat: Text.AutoText\n}\n",
            "explicit_richtext.qml": "import QtQuick\nText {\n  text: userControlledTitle\n  textFormat: Text.RichText\n}\n",
            "root_prop_bypass.qml": "import QtQuick\nText {\n  text: userControlledTitle\n  textFormat: root.anyFormat\n}\n",
            "imperative_assign.qml": "import QtQuick\nItem {\n  Text { id: err }\n  Component.onCompleted: err.text = dynamicReason\n}\n",
            "imperative_plus_assign.qml": "import QtQuick\nItem {\n  Text { id: err; text: \"prefix\" }\n  Component.onCompleted: err.text += dynamicReason\n}\n",
            "inline_subclass.qml": "import QtQuick\nItem {\n  component SubLabel: Text {}\n  SubLabel {\n    text: userControlledTitle\n  }\n}\n",
        }
        for fname, code in bad_cases.items():
            with self.subTest(case=fname):
                sub = self.root / fname.replace(".qml", "")
                sub.mkdir()
                (sub / fname).write_text(code, encoding="utf-8")
                proc = self._run_gate(sub)
                self.assertNotEqual(proc.returncode, 0, f"{fname} 未被文本格式门禁拦截")

    def test_safe_inline_subclass_and_literals_pass(self) -> None:
        """保证基类内联组件已设 Text.PlainText 或纯字面量 text 绑定合法通过。"""
        sub = self.root / "safe_sub"
        sub.mkdir()
        (sub / "Safe.qml").write_text(
            "import QtQuick\n"
            "Item {\n"
            "  component GoodLabel: Label { textFormat: Text.PlainText }\n"
            "  GoodLabel { text: dynamicTitle }\n"
            '  Text { text: qsTr("静态标题") }\n'
            '  Label { id: msg; text: "" }\n'
            "  Component.onCompleted: msg.text = \"ok\"\n"
            "}\n",
            encoding="utf-8",
        )
        proc = self._run_gate(sub)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


class QmlHoverTransitionGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(prefix="qml-hover-gate-")
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)

    def test_repository_qml_passes(self) -> None:
        """保证仓库现有 qml/ 全部通过加固后的悬停过渡门禁。"""
        problems = []
        for path in sorted((ROOT_DIR / "qml").rglob("*.qml")):
            problems.extend(qml_hover_transition_gate.check_file(path))
        self.assertEqual(problems, [])

    def test_black_transparent_variants_rejected(self) -> None:
        """保证单引号、零透明十六进制、零浮点 Qt.rgba 与多行花括号块绑定均被拦截。"""
        bad_cases = {
            "single_quote.qml": "import QtQuick\nRectangle {\n  color: btn.hovered ? Theme.glassHover : 'transparent'\n  Behavior on color { ColorAnimation { duration: 120 } }\n}\n",
            "hex_zero_alpha.qml": 'import QtQuick\nRectangle {\n  color: btn.hovered ? Theme.glassHover : "#00000000"\n  Behavior on color { ColorAnimation { duration: 120 } }\n}\n',
            "hex4_zero_alpha.qml": "import QtQuick\nRectangle {\n  color: btn.hovered ? Theme.glassHover : '#0000'\n  Behavior on color { ColorAnimation { duration: 120 } }\n}\n",
            "float_zero_rgba.qml": "import QtQuick\nRectangle {\n  color: btn.hovered ? Theme.glassHover : Qt.rgba(0.0, 0, 0, 0.0)\n  Behavior on color { ColorAnimation { duration: 120 } }\n}\n",
            "block_binding.qml": 'import QtQuick\nRectangle {\n  color: {\n    if (btn.hovered) return Theme.glassHover;\n    return "transparent";\n  }\n  Behavior on color { ColorAnimation { duration: 120 } }\n}\n',
            "same_line_semicolon.qml": 'import QtQuick\nRectangle {\n  id: bg; color: btn.hovered ? Theme.glassHover : "transparent"\n  Behavior on color { ColorAnimation { duration: 120 } }\n}\n',
            "border_color_transparent.qml": 'import QtQuick\nRectangle {\n  border.color: btn.hovered ? Theme.accent : "transparent"\n  Behavior on border.color { ColorAnimation { duration: 120 } }\n}\n',
            "white_based_rgba.qml": "import QtQuick\nRectangle {\n  color: btn.hovered ? Theme.glassHover : Qt.rgba(1, 1, 1, 0)\n  Behavior on color { ColorAnimation { duration: 120 } }\n}\n",
            "white_based_hex.qml": 'import QtQuick\nRectangle {\n  color: btn.hovered ? Theme.glassHover : "#00ffffff"\n  Behavior on color { ColorAnimation { duration: 120 } }\n}\n',
        }
        for fname, code in bad_cases.items():
            with self.subTest(case=fname):
                p = self.root / fname
                p.write_text(code, encoding="utf-8")
                self.assertTrue(qml_hover_transition_gate.check_file(p), f"{fname} 未被悬停门禁拦截")


class IPadThemeGateTests(unittest.TestCase):
    def test_repository_passes(self) -> None:
        """保证 iPad 颜色与主题/壁纸白名单门禁在当前仓库通过。"""
        proc = subprocess.run(
            [sys.executable, str(ROOT_DIR / "tests/ipad_theme_gate.py")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_hardcoded_swift_colors_in_views_rejected(self) -> None:
        """保证 SwiftUI 视图中硬编码 Color.white / .white.opacity(...) / Color(white:) 及同有 URL 字符串时仍被拦截。"""
        import ipad_theme_gate

        with tempfile.TemporaryDirectory(prefix="ipad-view-check-") as d:
            for idx, snippet in enumerate((
                'Text("x").foregroundColor(Color.white)',
                'Text("https://example.com").foregroundStyle(.white.opacity(0.6))',
                'Rectangle().fill(.black)',
                'Text("x").foregroundStyle(Color(white: 0.9))',
            )):
                view = Path(d) / f"BadView{idx}.swift"
                view.write_text(f"import SwiftUI\nstruct BadView: View {{ var body: some View {{ {snippet} }} }}\n", encoding="utf-8")
                violations = ipad_theme_gate.check_hardcoded_swift_colors([view])
                self.assertTrue(violations, f"`{snippet}` 应被 iPad 主题门禁拦截")

    def test_ios_cmake_manifest_gate_passes_on_repository(self) -> None:
        """保证仓库现有 IPadCore/IPadUI Swift 文件与 ObjC++ 桥接文件均通过双向清单与 -fobjc-arc 门禁。"""
        self.assertEqual(ios_cmake_manifest_gate.check_manifests(ROOT_DIR), [])


class McpBundleAndLinkGateTests(unittest.TestCase):
    def test_check_mcp_bundle_rejects_wrong_tool_and_missing_sqlite_plugin(self) -> None:
        """保证 check_mcp_bundle.py 核对 10 个精确工具名/schema，并验证包内备份执行器与 SQLite 插件。"""
        exact_names = [
            "pomodoro_get_status",
            "pomodoro_list_categories",
            "pomodoro_list_tasks",
            "pomodoro_get_task",
            "pomodoro_get_focus_summary",
            "pomodoro_list_knowledge_gaps",
            "pomodoro_create_task",
            "pomodoro_update_task",
            "pomodoro_reschedule_task",
            "pomodoro_set_task_completed",
        ]
        with tempfile.TemporaryDirectory(prefix="mcp-bundle-gate-") as d:
            root = Path(d)
            app = root / "PomodoroTodo.app"
            macos = app / "Contents/MacOS"
            macos.mkdir(parents=True)
            (app / "Contents/Info.plist").write_text("<plist/>", encoding="utf-8")
            helper = macos / "PomodoroTodoMcp"

            def write_fake_helper(names: list[str]) -> None:
                helper.write_text(
                    "#!/usr/bin/env python3\n"
                    "import json, sys\n"
                    f"NAMES = {names!r}\n"
                    "for line in sys.stdin:\n"
                    "  req = json.loads(line)\n"
                    "  m = req.get('method')\n"
                    "  if m == 'initialize':\n"
                    "    print(json.dumps({'jsonrpc':'2.0','id':req['id'],'result':{'protocolVersion':req['params']['protocolVersion']}}), flush=True)\n"
                    "  elif m == 'tools/list':\n"
                    "    tools = [{'name': n, 'inputSchema': {'type':'object'}} for n in NAMES]\n"
                    "    print(json.dumps({'jsonrpc':'2.0','id':req['id'],'result':{'tools':tools}}), flush=True)\n",
                    encoding="utf-8",
                )
                helper.chmod(helper.stat().st_mode | stat.S_IXUSR)

            # 1) 工具名错配必须失败
            write_fake_helper([f"fake_tool_{i}" for i in range(10)])
            proc = subprocess.run(
                [sys.executable, str(ROOT_DIR / "tests/check_mcp_bundle.py"), str(helper)],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(proc.returncode, 0, "错误工具名竟通过 check_mcp_bundle.py")

            # 2) 工具名正确但缺少备份执行器或 libptqsqlite.dylib 必须失败
            write_fake_helper(exact_names)
            proc2 = subprocess.run(
                [sys.executable, str(ROOT_DIR / "tests/check_mcp_bundle.py"), str(helper)],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(proc2.returncode, 0, "包内缺少备份执行器与 libptqsqlite.dylib 时竟通过 check_mcp_bundle.py")

    def test_check_mcp_helper_links_rejects_libsqlite3_and_static_symbols(self) -> None:
        """保证 CheckMcpHelperLinks.cmake 在已链接 QtCore 时仍拦下 libsqlite3 动态库与静态 DatabaseManager 符号。"""
        cc = shutil.which("clang++") or shutil.which("cc")
        if not cc:
            self.skipTest("系统无 C/C++ 编译器")
        candidate_dirs: list[Path] = []
        if os.environ.get("QT_LIB_DIR"):
            candidate_dirs.append(Path(os.environ["QT_LIB_DIR"]))
        if os.environ.get("QT_ROOT_DIR"):
            candidate_dirs.append(Path(os.environ["QT_ROOT_DIR"]) / "lib")
        candidate_dirs.extend(sorted((Path.home() / "Qt").glob("*/macos/lib")))
        qt_flag_args: list[str] = []
        for lib_dir in candidate_dirs:
            if (lib_dir / "QtCore.framework").is_dir():
                qt_flag_args = ["-F", str(lib_dir), "-Wl,-needed_framework,QtCore"]
                break
        if not qt_flag_args:
            self.skipTest("未找到本地 QtCore.framework 以构造真实 helper 链接负例")

        with tempfile.TemporaryDirectory(prefix="mcp-link-gate-") as d:
            root = Path(d)
            c_src = root / "bad_sqlite.c"
            c_src.write_text(
                "#include <sqlite3.h>\n"
                "int main(void) { sqlite3 *db = 0; sqlite3_close(db); return 0; }\n",
                encoding="utf-8",
            )
            bad_bin = root / "BadHelper"
            compile_proc = subprocess.run(
                [cc, str(c_src), *qt_flag_args, "-lsqlite3", "-o", str(bad_bin)],
                capture_output=True,
                text=True,
            )
            if compile_proc.returncode != 0:
                self.skipTest(f"编译测试二进制失败: {compile_proc.stderr}")
            gate_proc = subprocess.run(
                [
                    "cmake",
                    f"-DHELPER_BINARY={bad_bin}",
                    "-P",
                    str(ROOT_DIR / "cmake/CheckMcpHelperLinks.cmake"),
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(gate_proc.returncode, 0, "直链 libsqlite3 的二进制竟通过 CheckMcpHelperLinks.cmake")

            c_static = root / "bad_static.cpp"
            c_static.write_text(
                "struct DatabaseManager { static int instance(); };\n"
                "int DatabaseManager::instance() { return 0; }\n"
                "int main() { return DatabaseManager::instance(); }\n",
                encoding="utf-8",
            )
            bad_static = root / "BadStaticHelper"
            c2 = subprocess.run(
                [cc, str(c_static), *qt_flag_args, "-o", str(bad_static)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(c2.returncode, 0, c2.stderr)
            gate2 = subprocess.run(
                [
                    "cmake",
                    f"-DHELPER_BINARY={bad_static}",
                    "-P",
                    str(ROOT_DIR / "cmake/CheckMcpHelperLinks.cmake"),
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(gate2.returncode, 0, "静态编入 DatabaseManager 符号竟通过 CheckMcpHelperLinks.cmake")


if __name__ == "__main__":
    unittest.main()
