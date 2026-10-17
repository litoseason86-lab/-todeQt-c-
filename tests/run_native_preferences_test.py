#!/usr/bin/env python3
"""运行使用系统偏好的测试，并在进程退出后清理其专用偏好域。"""

from __future__ import annotations

from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time

# 偏好域只由测试自己决定（tests/support/NativePreferenceDomain.h 写出 <可执行文件>.prefdomain），
# 这里不再重复摘要算法和域名表。文件内容仍可能被写错或被别的东西改掉，所以删除前用白名单把关：
# 只认带构建目录摘要的测试域和清理测试的固定域，正式应用的 com.pomodorotodo.* 永远匹配不上。
# pomodorotodotests? 里的可选 s：KnowledgeGapServiceTests 历来用 PomodoroTodoTest- 前缀。
DOMAIN_PATTERN = re.compile(
    r"^(?:com\.pomodorotodotests?-[0-9a-f]{8}\.[A-Za-z]+Tests|com\.pomodorotodo\.cleanup-tests)$"
)


def domain_file(executable: Path) -> Path:
    return executable.with_name(executable.name + ".prefdomain")


def take_domain(executable: Path) -> str | None:
    """读出并删掉测试写下的域名文件；测试在设定偏好域之前就退出时没有这个文件。"""
    path = domain_file(executable)
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None
    finally:
        path.unlink(missing_ok=True)


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


def main(argv: list[str] | None = None, run=subprocess.run, cleanup=cleanup_domain) -> int:
    args = sys.argv[1:] if argv is None else argv
    executable = Path(args[0]).resolve()
    # 先删掉上一次运行留下的域名文件，免得这次在写出之前就崩溃时拿旧文件冒充本次结果。
    domain_file(executable).unlink(missing_ok=True)
    result = run([str(executable), *args[1:]], check=False)
    # 包括断言失败和崩溃在内的测试结果必须继续向 CTest 传播。
    exit_code = result.returncode if result.returncode >= 0 else 128 - result.returncode
    domain = take_domain(executable)
    if domain is None:
        print(f"未找到 {domain_file(executable).name}：测试在设定偏好域之前就已退出，不做清理", file=sys.stderr)
        return exit_code
    if not DOMAIN_PATTERN.fullmatch(domain):
        print(f"拒绝清理不在白名单内的偏好域：{domain!r}", file=sys.stderr)
        return exit_code or 1
    try:
        cleanup(domain)
    except (OSError, RuntimeError, plistlib.InvalidFileException, subprocess.TimeoutExpired) as error:
        print(f"测试偏好清理失败：{error}", file=sys.stderr)
        return exit_code or 1
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
