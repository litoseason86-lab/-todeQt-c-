#!/usr/bin/env python3
"""只部署临时伪应用包，验证缺失/不可执行的 helper 不会挪走旧包。"""
from pathlib import Path
import plistlib
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
        self.write_identity(self.source)
        self.write_identity(self.destination)

    def write_identity(self, bundle, identifier="com.zerionlito.pomodorotodo"):
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))

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

    # 保证错误路径指向其它应用时，不会替换或删除该应用及其中的内容。
    def test_wrong_destination_identity_keeps_old_package(self):
        self.write_binary(self.source, "PomodoroTodoMcp", b"new-helper")
        self.write_identity(self.destination, "org.example.other-app")
        result = self.deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("身份", result.stderr)
        self.assert_old_preserved()
        self.assertEqual(plistlib.loads((self.destination / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"], "org.example.other-app")

    # 保证缺失或错误身份的新包不能覆盖现有应用。
    def test_invalid_source_identity_keeps_old_package(self):
        self.write_binary(self.source, "PomodoroTodoMcp", b"new-helper")
        for identifier in ("org.example.other-app", "", None):
            with self.subTest(identifier=identifier):
                if identifier is None:
                    (self.source / "Contents/Info.plist").unlink()
                else:
                    self.write_identity(self.source, identifier)
                result = self.deploy()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("身份", result.stderr)
                self.assert_old_preserved()

    # 保证无法识别身份的旧包不会在部署中被删除。
    def test_missing_destination_identity_keeps_old_package(self):
        self.write_binary(self.source, "PomodoroTodoMcp", b"new-helper")
        (self.destination / "Contents/Info.plist").unlink()
        self.assertNotEqual(self.deploy().returncode, 0)
        self.assert_old_preserved()

    # 保证目标为符号链接时既不替换链接，也不破坏链接指向的包。
    def test_symlink_destination_is_rejected(self):
        self.write_binary(self.source, "PomodoroTodoMcp", b"new-helper")
        actual = self.root / "actual.app"
        self.destination.rename(actual)
        self.destination.symlink_to(actual, target_is_directory=True)
        self.assertNotEqual(self.deploy().returncode, 0)
        self.assertTrue(self.destination.is_symlink())
        self.assert_old_preserved()

    # 保证首次安装支持不存在的目标，不把身份保护误写为只能覆盖旧包。
    def test_first_install_accepts_project_identity(self):
        self.destination = self.root / "first.app"
        self.write_binary(self.source, "PomodoroTodoMcp", b"new-helper")
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "Contents/MacOS/PomodoroTodo").read_bytes(), b"new-main")

    # 保证相同源目标不会撤销自己的可用安装或注册位置。
    def test_source_equal_to_destination_is_rejected(self):
        self.source = self.destination
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
