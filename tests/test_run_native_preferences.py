#!/usr/bin/env python3
"""run_native_preferences_test.py 读取域名文件、白名单把关与退出码传播的自检。"""

from __future__ import annotations

import contextlib
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR / "tests"))

import run_native_preferences_test as runner  # noqa: E402


class NativePreferencesRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        # 不启动真实测试、不碰真实偏好：运行与清理都换成记录调用的替身，可执行文件只是临时目录里的路径。
        self.temp_dir = tempfile.TemporaryDirectory()
        self.executable = Path(self.temp_dir.name) / "PomodoroTodoTests"
        self.executable.write_text("", encoding="utf-8")
        self.cleaned: list[str] = []

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _run(self, *, writes: str | None, returncode: int) -> tuple[int, str]:
        def fake_run(command, check):
            self.assertEqual(command[0], str(self.executable.resolve()))
            if writes is not None:
                runner.domain_file(self.executable).write_text(writes, encoding="utf-8")
            return subprocess.CompletedProcess(command, returncode)

        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = runner.main([str(self.executable)], run=fake_run, cleanup=self.cleaned.append)
        return code, err.getvalue()

    def test_published_test_domain_is_cleaned(self) -> None:
        """保证测试写出的合法域名会被清理，测试自身的失败退出码原样传给 CTest，域名文件随后删掉。"""
        code, _ = self._run(writes="com.pomodorotodotests-0123abcd.PomodoroTodoTests\n", returncode=3)
        self.assertEqual(code, 3)
        self.assertEqual(self.cleaned, ["com.pomodorotodotests-0123abcd.PomodoroTodoTests"])
        self.assertFalse(runner.domain_file(self.executable).exists())

    def test_whitelist_accepts_every_existing_form(self) -> None:
        """保证现有四种测试域（含少一个 s 的历史前缀和清理测试的固定域）都能通过白名单。"""
        for domain in ("com.pomodorotodotests-0123abcd.TrashServiceTests",
                       "com.pomodorotodotest-0123abcd.KnowledgeGapServiceTests",
                       "com.pomodorotodo.cleanup-tests"):
            self.cleaned.clear()
            code, err = self._run(writes=domain, returncode=0)
            self.assertEqual((code, self.cleaned), (0, [domain]), err)

    def test_domain_outside_whitelist_is_refused(self) -> None:
        """保证域名文件写成正式应用或任意别的域时拒绝删除，即使测试本身通过也以失败退出。"""
        for domain in ("com.zerionlito.pomodorotodo", "com.pomodorotodo.PomodoroTodo",
                       "com.pomodorotodotests-0123abcd.PomodoroTodoTests extra", ""):
            self.cleaned.clear()
            code, err = self._run(writes=domain, returncode=0)
            self.assertEqual(code, 1, domain)
            self.assertEqual(self.cleaned, [], domain)
            self.assertIn("白名单", err)

    def test_missing_domain_file_skips_cleanup_and_keeps_exit_code(self) -> None:
        """保证测试在写出域名前就退出（包括被信号杀掉）时不清理任何域，退出码照旧传播。"""
        code, err = self._run(writes=None, returncode=-6)
        self.assertEqual(code, 134)
        self.assertEqual(self.cleaned, [])
        self.assertIn("不做清理", err)

    def test_stale_domain_file_is_not_trusted(self) -> None:
        """保证上一次运行留下的域名文件在本次运行前被删掉，不会被当成这次测试写出的结果。"""
        runner.domain_file(self.executable).write_text("com.pomodorotodotests-0123abcd.PomodoroTodoTests",
                                                       encoding="utf-8")
        code, _ = self._run(writes=None, returncode=0)
        self.assertEqual(code, 0)
        self.assertEqual(self.cleaned, [])


if __name__ == "__main__":
    unittest.main()
