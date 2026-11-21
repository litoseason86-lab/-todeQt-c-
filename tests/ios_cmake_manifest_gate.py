#!/usr/bin/env python3
"""iOS Swift 与 Objective-C++ 桥接源文件 ↔ CMakeLists.txt / PomodoroTodoTests.cmake 双向清单门禁。

起因：macOS 上的 IPadSwiftTests 通过 SwiftPM 自动扫描 src/ui/ipad/Sources/IPadCore，
若新增 .swift 文件或桥接 .mm 文件漏登记到 CMakeLists.txt（或漏标 -fobjc-arc），
macOS 全量 ctest 依然通过，直到 iOS Xcode 构建或运行期 ARC 缺失才暴露。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


def strip_cmake_comments(text: str) -> str:
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def check_manifests(root: Path) -> list[str]:
    problems: list[str] = []
    cmake_path = root / "CMakeLists.txt"
    tests_cmake_path = root / "cmake" / "PomodoroTodoTests.cmake"
    if not cmake_path.is_file() or not tests_cmake_path.is_file():
        return [f"找不到 CMakeLists.txt 或 cmake/PomodoroTodoTests.cmake（root={root}）"]

    cmake_clean = strip_cmake_comments(cmake_path.read_text(encoding="utf-8"))
    tests_clean = strip_cmake_comments(tests_cmake_path.read_text(encoding="utf-8"))

    # 1. 双向核对 IPadCore 与 IPadUI 的全部 .swift 源文件
    disk_swift = {
        p.relative_to(root).as_posix()
        for sub in ("src/ui/ipad/Sources/IPadCore", "src/ui/ipad/Sources/IPadUI")
        for p in (root / sub).rglob("*.swift")
        if p.is_file()
    }
    cmake_swift = set(re.findall(r"src/ui/ipad/Sources/(?:IPadCore|IPadUI)/[A-Za-z0-9_./-]+\.swift", cmake_clean))

    for missing in sorted(disk_swift - cmake_swift):
        problems.append(f"CMakeLists.txt 未登记 Swift 源文件：{missing}")
    for ghost in sorted(cmake_swift - disk_swift):
        problems.append(f"CMakeLists.txt 登记了不存在的 Swift 源文件：{ghost}")

    # 2. 双向核对 src/platform/ios/bridge/*.mm 登记、ARC 编译选项与 macOS 桥接测试覆盖
    disk_bridges = {
        p.relative_to(root).as_posix()
        for p in (root / "src/platform/ios/bridge").glob("*.mm")
        if p.is_file()
    }
    cmake_bridges = set(re.findall(r"src/platform/ios/bridge/[A-Za-z0-9_.-]+\.mm", cmake_clean))
    tests_bridges = set(re.findall(r"src/platform/ios/bridge/[A-Za-z0-9_.-]+\.mm", tests_clean))

    for missing in sorted(disk_bridges - cmake_bridges):
        problems.append(f"CMakeLists.txt 未登记 iOS 桥接源文件：{missing}")
    for ghost in sorted(cmake_bridges - disk_bridges):
        problems.append(f"CMakeLists.txt 登记了不存在的 iOS 桥接源文件：{ghost}")
    for untested in sorted(disk_bridges - tests_bridges):
        problems.append(f"cmake/PomodoroTodoTests.cmake 未覆盖 iOS 桥接源文件：{untested}")

    # 3. 核对所有桥接 .mm 在 CMakeLists.txt 与 PomodoroTodoTests.cmake 中均显式开启 -fobjc-arc
    arc_block_re = re.compile(
        r"set_source_files_properties\s*\((.*?)PROPERTIES\s+COMPILE_OPTIONS\s+\"-fobjc-arc\"\s*\)",
        re.S,
    )
    cmake_arc: set[str] = set()
    for m in arc_block_re.finditer(cmake_clean):
        cmake_arc.update(re.findall(r"src/platform/ios/bridge/[A-Za-z0-9_.-]+\.mm", m.group(1)))
    tests_arc: set[str] = set()
    for m in arc_block_re.finditer(tests_clean):
        tests_arc.update(re.findall(r"src/platform/ios/bridge/[A-Za-z0-9_.-]+\.mm", m.group(1)))

    for no_arc in sorted(disk_bridges - cmake_arc):
        problems.append(f"CMakeLists.txt 未为桥接文件开启 -fobjc-arc：{no_arc}")
    for no_test_arc in sorted(disk_bridges - tests_arc):
        problems.append(f"cmake/PomodoroTodoTests.cmake 未为桥接文件开启 -fobjc-arc：{no_test_arc}")

    return problems


def main(argv: list[str]) -> int:
    root = Path(argv[1]).resolve() if len(argv) > 1 else Path(__file__).resolve().parent.parent
    problems = check_manifests(root)
    if problems:
        for p in problems:
            print(f"IosCmakeManifestGate: {p}", file=sys.stderr)
        return 1
    print("IosCmakeManifestGate: Swift 与 ObjC++ 桥接源文件双向清单及 -fobjc-arc 核对通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
