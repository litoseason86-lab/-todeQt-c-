#!/usr/bin/env python3
"""运行使用系统偏好的测试，并在进程退出后清理其专用偏好域。"""

import hashlib
from pathlib import Path
import plistlib
import subprocess
import sys
import time


def preference_domain(executable: Path) -> str:
    # 与三套测试的 initTestCase 保持一致：Qt 用构建目录的 SHA-1 前八位隔离偏好域。
    digest = hashlib.sha1(str(executable.parent).encode("utf-8")).hexdigest()[:8]
    domains = {
        "PomodoroTodoTests": f"com.pomodorotodotests-{digest}.PomodoroTodoTests",
        "TrashServiceTests": f"com.pomodorotodotests-{digest}.TrashServiceTests",
        "KnowledgeGapServiceTests": f"com.pomodorotodotest-{digest}.KnowledgeGapServiceTests",
        "MacPreferencesCleanupTests": "com.pomodorotodo.cleanup-tests",
    }
    # 使用显式白名单，拒绝把任意应用或正式应用的偏好传入删除流程。
    return domains[executable.name]


def cleanup_domain(domain: str) -> None:
    path = Path.home() / "Library/Preferences" / f"{domain}.plist"
    # 必须在测试进程退出后调用：进程内删文件会被退出时的偏好同步重新写回。
    # defaults 通知 cfprefsd（系统偏好守护进程）清空域，但实测 macOS 27.0.1
    # 仍可能延迟写出空 plist，因此还需等待磁盘稳定，不能只信命令退出码。
    deletion = subprocess.run(
        ["/usr/bin/defaults", "delete", domain],
        capture_output=True, text=True, check=False, timeout=5,
    )
    deadline = time.monotonic() + 5
    absent_since = None
    while time.monotonic() < deadline:
        try:
            with path.open("rb") as source:
                values = plistlib.load(source)
            absent_since = None
            # defaults 删除已空或不存在的域会返回 1；以落盘内容为准。
            # 非空时继续等同步，不能直接 unlink 掩盖清空域失败或另一进程的写入。
            if values == {}:
                path.unlink(missing_ok=True)
        except FileNotFoundError:
            now = time.monotonic()
            if absent_since is None:
                absent_since = now
            elif now - absent_since >= 1:
                return
        time.sleep(0.05)
    raise RuntimeError(f"测试偏好未能清空或持续被重新写入：{path}；{deletion.stderr.strip()}")


def main() -> int:
    executable = Path(sys.argv[1]).resolve()
    domain = preference_domain(executable)
    result = subprocess.run([str(executable), *sys.argv[2:]], check=False)
    # 包括断言失败和崩溃在内的测试结果必须继续向 CTest 传播。
    exit_code = result.returncode if result.returncode >= 0 else 128 - result.returncode
    try:
        cleanup_domain(domain)
    except (OSError, RuntimeError, plistlib.InvalidFileException, subprocess.TimeoutExpired) as error:
        print(f"测试偏好清理失败：{error}", file=sys.stderr)
        return exit_code or 1
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
