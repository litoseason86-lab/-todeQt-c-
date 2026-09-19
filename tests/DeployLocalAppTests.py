#!/usr/bin/env python3
"""只部署临时伪应用包，验证缺失/不可执行的 helper 不会挪走旧包。"""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "cmake" / "DeployLocalApp.cmake"


class DeployLocalAppTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="deploy-mcp-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "source.app"
        self.destination = self.root / "target.app"
        self.write_binary(self.destination, "PomodoroTodo", b"old-main")
        self.write_binary(self.destination, "PomodoroTodoMcp", b"old-helper")
        self.write_binary(self.source, "PomodoroTodo", b"new-main")

    def write_binary(self, bundle, name, data, mode=0o755):
        path = bundle / "Contents" / "MacOS" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)

    def deploy(self):
        return subprocess.run(["cmake", f"-DSOURCE_APP={self.source}", f"-DDESTINATION_APP={self.destination}",
                               "-DBUNDLE_EXECUTABLE=PomodoroTodo", "-DHELPER_EXECUTABLE=PomodoroTodoMcp",
                               "-P", str(SCRIPT)], capture_output=True, text=True, timeout=15)

    def assert_old_preserved(self):
        self.assertEqual((self.destination / "Contents/MacOS/PomodoroTodo").read_bytes(), b"old-main")
        self.assertEqual((self.destination / "Contents/MacOS/PomodoroTodoMcp").read_bytes(), b"old-helper")
        self.assertFalse(list(self.root.glob("target.app.*")))

    def test_missing_helper_keeps_old_package(self):
        self.assertNotEqual(self.deploy().returncode, 0)
        self.assert_old_preserved()

    def test_non_executable_helper_keeps_old_package(self):
        self.write_binary(self.source, "PomodoroTodoMcp", b"new-helper", 0o644)
        self.assertNotEqual(self.deploy().returncode, 0)
        self.assert_old_preserved()

    def test_both_binaries_replaced_together(self):
        self.write_binary(self.source, "PomodoroTodoMcp", b"new-helper")
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "Contents/MacOS/PomodoroTodo").read_bytes(), b"new-main")
        self.assertEqual((self.destination / "Contents/MacOS/PomodoroTodoMcp").read_bytes(), b"new-helper")
        self.assertFalse(list(self.root.glob("target.app.*")))


if __name__ == "__main__":
    unittest.main()
