#!/usr/bin/env python3
"""057 的架构依赖门禁（已覆盖 057-A PTCore 与 057-B PTApp）。

门禁按 CMake 生成的源文件清单判断归属。目录没有被搬动时，仅按目录扫描会漏掉
跨层 include；这里解析每个源文件的 include，并把直接、接口链接依赖一起核对。
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ALLOWED_QT_LINKS = {
    "Qt6::Core",
    "Qt6::Gui",
    "Qt6::Sql",
    "Qt6::Concurrent",
}
SYNC_FILES = {"SyncEngine", "SyncStore", "SyncWorker", "SyncFiles", "SyncRecord"}
SYNC_INCLUDE_ALLOWLIST = {
    "SyncEngine.h",
    "SyncStore.h",
    "SyncWorker.h",
    "SyncFiles.h",
    "SyncRecord.h",
    "SyncFolder.h",
    "SyncSchema.h",
    "DatabaseManager.h",
    "ServiceReadResult.h",
    "FocusSessionRules.h",
    "RoutineRules.h",
}
INCLUDE_RE = re.compile(r"^\s*#\s*include\s*[<\"]([^>\"]+)[>\"]")
QML_INCLUDE_RE = re.compile(r"^(?:QQml|QQuick|QJS|QtQml/|QtQuick/)")


def fail(message: str) -> None:
    print(f"ArchitectureGate: {message}", file=sys.stderr)


def resolve_include(include: str, source: Path, root: Path) -> Path | None:
    """按源文件目录、src、仓库根的顺序解析项目 include。"""
    for candidate in (source.parent / include, root / "src" / include, root / include):
        if candidate.is_file():
            return candidate.resolve()
    return None


def link_items(value: object, target: str, attribute: str) -> tuple[list[str], bool]:
    if value is None:
        return [], True
    if not isinstance(value, list):
        fail(f"{target}.{attribute} 不是清单：{value!r}")
        return [], False
    result: list[str] = []
    valid = True
    for item in value:
        if not isinstance(item, str) or not item:
            fail(f"{target}.{attribute} 含空项或非文本项：{item!r}")
            valid = False
            continue
        # 静态库接口可能把合法依赖包装成 LINK_ONLY；只解包这一种已知表达式。
        if item.startswith("$<LINK_ONLY:") and item.endswith(">"):
            item = item[len("$<LINK_ONLY:") : -1]
        elif item.startswith("$<"):
            fail(f"{target}.{attribute} 含无法解析的生成器表达式：{item}")
            valid = False
            continue
        result.append(item)
    return result, valid


def main() -> int:
    if len(sys.argv) != 3:
        print("用法：architecture_gate.py <architecture-manifest.json> <source-root>", file=sys.stderr)
        return 2

    manifest_path = Path(sys.argv[1]).resolve()
    root = Path(sys.argv[2]).resolve()
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"无法读取清单 {manifest_path}: {exc}")
        return 1

    core = manifest.get("PTCore")
    if not isinstance(core, dict):
        fail("清单缺少 PTCore")
        return 1
    core_sources_raw = core.get("sources")
    if not isinstance(core_sources_raw, list):
        fail("PTCore.sources 不是清单")
        return 1

    core_sources: set[Path] = set()
    valid = True
    for raw in core_sources_raw:
        if not isinstance(raw, str):
            fail(f"PTCore.sources 含非文本项：{raw!r}")
            valid = False
            continue
        path = Path(raw)
        if not path.is_absolute():
            path = root / path
        path = path.resolve()
        if not path.is_file():
            fail(f"PTCore 清单中的源文件不存在：{path}")
            valid = False
        core_sources.add(path)

    direct, direct_valid = link_items(core.get("link_libraries"), "PTCore", "LINK_LIBRARIES")
    interface, interface_valid = link_items(
        core.get("interface_link_libraries"), "PTCore", "INTERFACE_LINK_LIBRARIES"
    )
    valid = valid and direct_valid and interface_valid
    for dependency in direct + interface:
        if dependency not in ALLOWED_QT_LINKS:
            fail(f"R1：PTCore 不允许链接 {dependency!r}，允许集合为 {sorted(ALLOWED_QT_LINKS)}")
            valid = False

    for source in sorted(core_sources):
        try:
            text = source.read_text(encoding="utf-8")
        except OSError as exc:
            fail(f"无法读取 PTCore 源文件 {source}: {exc}")
            valid = False
            continue

        if "Q_OS_" in text and source.name != "PhaseSoundService.cpp":
            fail(f"R5：{source.relative_to(root)} 含 Q_OS_，唯一允许位置是 PhaseSoundService.cpp")
            valid = False
        stem = source.stem
        for line in text.splitlines():
            match = INCLUDE_RE.match(line)
            if not match:
                continue
            include = match.group(1)
            if QML_INCLUDE_RE.match(include):
                fail(f"R3：{source.relative_to(root)} include 了 QML/Quick/Javascript 头文件 {include}")
                valid = False
            resolved = resolve_include(include, source, root)
            if resolved is None or not resolved.is_relative_to(root):
                continue
            if resolved not in core_sources:
                fail(
                    f"R2：{source.relative_to(root)} include 的项目文件 "
                    f"{resolved.relative_to(root)} 不属于 PTCore"
                )
                valid = False
            if stem in SYNC_FILES and resolved.name not in SYNC_INCLUDE_ALLOWLIST:
                fail(
                    f"R4：{source.relative_to(root)} 不允许 include {resolved.name}；"
                    f"同步引擎白名单为 {sorted(SYNC_INCLUDE_ALLOWLIST)}"
                )
                valid = False

    # 检查 PTApp（057-B 新增 R6 规则）
    app = manifest.get("PTApp")
    if not isinstance(app, dict):
        fail("清单缺少 PTApp")
        return 1
    app_sources_raw = app.get("sources")
    if not isinstance(app_sources_raw, list):
        fail("PTApp.sources 不是清单")
        return 1

    app_sources: set[Path] = set()
    for raw in app_sources_raw:
        if not isinstance(raw, str):
            fail(f"PTApp.sources 含非文本项：{raw!r}")
            valid = False
            continue
        path = Path(raw)
        if not path.is_absolute():
            path = root / path
        path = path.resolve()
        if not path.is_file():
            fail(f"PTApp 清单中的源文件不存在：{path}")
            valid = False
        app_sources.add(path)

    app_direct, app_direct_valid = link_items(app.get("link_libraries"), "PTApp", "LINK_LIBRARIES")
    app_interface, app_interface_valid = link_items(
        app.get("interface_link_libraries"), "PTApp", "INTERFACE_LINK_LIBRARIES"
    )
    valid = valid and app_direct_valid and app_interface_valid
    allowed_app_links = ALLOWED_QT_LINKS | {"PTCore"}
    for dependency in app_direct + app_interface:
        if dependency not in allowed_app_links:
            fail(f"R6：PTApp 不允许链接 {dependency!r}，允许集合为 {sorted(allowed_app_links)}")
            valid = False

    for source in sorted(app_sources):
        try:
            text = source.read_text(encoding="utf-8")
        except OSError as exc:
            fail(f"无法读取 PTApp 源文件 {source}: {exc}")
            valid = False
            continue

        if "Q_OS_" in text:
            fail(f"R6：{source.relative_to(root)} 含 Q_OS_，PTApp 不允许包含任何平台分支宏")
            valid = False
        for line in text.splitlines():
            match = INCLUDE_RE.match(line)
            if not match:
                continue
            include = match.group(1)
            if QML_INCLUDE_RE.match(include):
                fail(f"R3：{source.relative_to(root)} include 了 QML/Quick/Javascript 头文件 {include}")
                valid = False
            resolved = resolve_include(include, source, root)
            if resolved is None or not resolved.is_relative_to(root):
                continue
            if resolved not in core_sources and resolved not in app_sources:
                fail(
                    f"R6：{source.relative_to(root)} include 的项目文件 "
                    f"{resolved.relative_to(root)} 不属于 PTApp 或 PTCore"
                )
                valid = False

    if not valid:
        return 1
    print(f"ArchitectureGate: PTCore 与 PTApp R1-R6 通过（PTCore {len(core_sources)} 个源文件，PTApp {len(app_sources)} 个源文件）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
