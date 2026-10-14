#!/usr/bin/env python3
"""057 的架构依赖门禁（覆盖 057-A PTCore、057-B PTApp、057-C PTQml 与入口顺序）。

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
ALLOWED_QML_LINKS = ALLOWED_QT_LINKS | {
    "PTCore",
    "PTApp",
    "Qt6::Qml",
    "Qt6::Quick",
    "Qt6::QuickControls2",
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


def strip_comments_and_strings(code: str) -> str:
    """移除 C++ 源码中的注释和字符串字面量，保留其余代码结构。"""
    result = []
    i = 0
    n = len(code)
    while i < n:
        if i + 1 < n and code[i : i + 2] == "//":
            i += 2
            while i < n and code[i] != "\n":
                i += 1
        elif i + 1 < n and code[i : i + 2] == "/*":
            i += 2
            while i + 1 < n and code[i : i + 2] != "*/":
                i += 1
            i += 2
        elif code[i] == '"':
            i += 1
            while i < n:
                if code[i] == "\\" and i + 1 < n:
                    i += 2
                elif code[i] == '"':
                    i += 1
                    break
                else:
                    i += 1
        elif code[i] == "'":
            i += 1
            while i < n:
                if code[i] == "\\" and i + 1 < n:
                    i += 2
                elif code[i] == "'":
                    i += 1
                    break
                else:
                    i += 1
        else:
            result.append(code[i])
            i += 1
    return "".join(result)


def extract_main_body(clean_code: str) -> str | None:
    """从去除了注释和字符串的代码中提取 main() 函数体。"""
    match = re.search(r"\bint\s+main\s*\([^)]*\)\s*\{", clean_code)
    if not match:
        return None
    start = match.end() - 1  # '{' 的位置
    depth = 0
    for idx in range(start, len(clean_code)):
        char = clean_code[idx]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return clean_code[start + 1 : idx]
    return None


def check_entry_r8(entry_path: Path) -> bool:
    """检查入口 main() 启动时序约束（R8 规则）。"""
    if not entry_path.is_file():
        fail(f"R8：入口文件不存在：{entry_path}")
        return False

    try:
        raw_code = entry_path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"R8：无法读取入口文件 {entry_path}: {exc}")
        return False

    clean_code = strip_comments_and_strings(raw_code)
    main_body = extract_main_body(clean_code)
    if main_body is None:
        fail(f"R8：在 {entry_path} 中未找到 main() 函数体")
        return False

    pos_app = main_body.find("QGuiApplication")
    if pos_app == -1:
        fail(f"R8：{entry_path} 的 main() 中未创建 QGuiApplication")
        return False

    pos_identity = main_body.find("McpPaths::applyApplicationIdentity()")
    if pos_identity == -1:
        fail(f"R8：{entry_path} 的 main() 中未调用 McpPaths::applyApplicationIdentity()")
        return False

    if pos_app > pos_identity:
        fail(
            f"R8：{entry_path} 中 QGuiApplication（位置 {pos_app}）必须在 "
            f"McpPaths::applyApplicationIdentity()（位置 {pos_identity}）之前创建"
        )
        return False

    # 后序操作必须出现在 McpPaths::applyApplicationIdentity() 之后
    post_ops = [
        "QSettings",
        "QStandardPaths::",
        "MacPreferencesCleanup::",
        "SingleInstanceGuard",
        "openDatabase(",
    ]
    for op in post_ops:
        pos_op = main_body.find(op)
        if pos_op != -1 and pos_op < pos_identity:
            fail(
                f"R8：{entry_path} 中操作 {op}（位置 {pos_op}）出现在 "
                f"McpPaths::applyApplicationIdentity()（位置 {pos_identity}）之前"
            )
            return False

    # 检查 main 之外是否有辅助函数使用了 QSettings 或 QStandardPaths
    # 若有，则该辅助函数在 main_body 中的首次调用位置必须在 applyApplicationIdentity 之后
    main_match = re.search(r"\bint\s+main\s*\([^)]*\)", clean_code)
    if main_match:
        outside_code = clean_code[: main_match.start()] + clean_code[main_match.end() + len(main_body) + 2 :]
        for dangerous in ("QSettings", "QStandardPaths"):
            if dangerous in outside_code:
                # 寻找在 outside_code 中定义并在 main 中被调用的函数
                func_defs = re.findall(r"\b([A-Za-z_]\w*)\s*\([^)]*\)\s*\{", outside_code)
                for func_name in func_defs:
                    pos_call = main_body.find(func_name + "(")
                    if pos_call != -1 and pos_call < pos_identity:
                        fail(
                            f"R8：辅助函数 {func_name}（含 {dangerous}）在 main() 中的调用"
                            f"（位置 {pos_call}）早于 applyApplicationIdentity()（位置 {pos_identity}）"
                        )
                        return False

    return True


def main() -> int:
    if len(sys.argv) != 3:
        fail("用法：architecture_gate.py <manifest-path> <source-root>")
        return 1

    manifest_path = Path(sys.argv[1])
    root = Path(sys.argv[2]).resolve()
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except OSError as exc:
        fail(f"无法读取清单文件 {manifest_path}: {exc}")
        return 1
    except json.JSONDecodeError as exc:
        fail(f"清单文件 JSON 格式错误 {manifest_path}: {exc}")
        return 1

    # 1. 检查 PTCore
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

    core_direct, core_direct_valid = link_items(core.get("link_libraries"), "PTCore", "LINK_LIBRARIES")
    core_interface, core_interface_valid = link_items(
        core.get("interface_link_libraries"), "PTCore", "INTERFACE_LINK_LIBRARIES"
    )
    valid = valid and core_direct_valid and core_interface_valid
    for dependency in core_direct + core_interface:
        if dependency not in ALLOWED_QT_LINKS:
            fail(f"R1：PTCore 不允许链接 {dependency!r}，允许集合为 {sorted(ALLOWED_QT_LINKS)}")
            valid = False

    for source in sorted(core_sources):
        stem = source.stem
        try:
            text = source.read_text(encoding="utf-8")
        except OSError as exc:
            fail(f"无法读取 PTCore 源文件 {source}: {exc}")
            valid = False
            continue

        if "Q_OS_" in text and stem != "PhaseSoundService":
            fail(f"R5：{source.relative_to(root)} 含 Q_OS_，现存唯一例外仅允许 PhaseSoundService.cpp")
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

    # 2. 检查 PTApp（057-B 新增 R6 规则）
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

    # 3. 检查 PTQml（057-C 新增 R7 规则）
    qml = manifest.get("PTQml")
    if not isinstance(qml, dict):
        fail("清单缺少 PTQml")
        return 1
    qml_sources_raw = qml.get("sources")
    if not isinstance(qml_sources_raw, list):
        fail("PTQml.sources 不是清单")
        return 1

    qml_sources: set[Path] = set()
    for raw in qml_sources_raw:
        if not isinstance(raw, str):
            fail(f"PTQml.sources 含非文本项：{raw!r}")
            valid = False
            continue
        path = Path(raw)
        if not path.is_absolute():
            path = root / path
        path = path.resolve()
        if not path.is_file():
            fail(f"PTQml 清单中的源文件不存在：{path}")
            valid = False
        qml_sources.add(path)

    qml_direct, qml_direct_valid = link_items(qml.get("link_libraries"), "PTQml", "LINK_LIBRARIES")
    qml_interface, qml_interface_valid = link_items(
        qml.get("interface_link_libraries"), "PTQml", "INTERFACE_LINK_LIBRARIES"
    )
    valid = valid and qml_direct_valid and qml_interface_valid
    for dependency in qml_direct + qml_interface:
        if dependency not in ALLOWED_QML_LINKS:
            fail(f"R7：PTQml 不允许链接 {dependency!r}，允许集合为 {sorted(ALLOWED_QML_LINKS)}")
            valid = False

    for source in sorted(qml_sources):
        try:
            text = source.read_text(encoding="utf-8")
        except OSError as exc:
            fail(f"无法读取 PTQml 源文件 {source}: {exc}")
            valid = False
            continue

        if "Q_OS_" in text:
            fail(f"R7：{source.relative_to(root)} 含 Q_OS_，PTQml 不允许包含任何平台分支宏")
            valid = False
        for line in text.splitlines():
            match = INCLUDE_RE.match(line)
            if not match:
                continue
            include = match.group(1)
            resolved = resolve_include(include, source, root)
            if resolved is None or not resolved.is_relative_to(root):
                continue
            if resolved not in core_sources and resolved not in app_sources and resolved not in qml_sources:
                fail(
                    f"R7：{source.relative_to(root)} include 的项目文件 "
                    f"{resolved.relative_to(root)} 不属于 PTQml、PTApp 或 PTCore"
                )
                valid = False

    # 4. R7 补充检查：PTCore 与 PTApp 不许 include src/entry、src/qmlfacade、src/platform
    forbidden_prefixes = (root / "src" / "entry", root / "src" / "qmlfacade", root / "src" / "platform")
    for source in sorted(core_sources | app_sources):
        try:
            text = source.read_text(encoding="utf-8")
        except OSError as exc:
            continue
        for line in text.splitlines():
            match = INCLUDE_RE.match(line)
            if not match:
                continue
            resolved = resolve_include(match.group(1), source, root)
            if resolved is None or not resolved.is_relative_to(root):
                continue
            for prefix in forbidden_prefixes:
                if resolved == prefix or resolved.is_relative_to(prefix):
                    fail(
                        f"R7：{source.relative_to(root)} 违规 include 了 "
                        f"{resolved.relative_to(root)}（禁止包含 entry/qmlfacade/platform）"
                    )
                    valid = False

    # 5. R8 检查：Mac 与 iOS 两个入口的 main() 启动时序约束
    mac_entry = root / "src" / "entry" / "mac" / "main.cpp"
    ios_entry = root / "src" / "entry" / "ios" / "main.cpp"
    if not check_entry_r8(mac_entry):
        valid = False
    if not check_entry_r8(ios_entry):
        valid = False

    if not valid:
        return 1

    print(
        f"ArchitectureGate: PTCore、PTApp 与 PTQml R1-R8 全部通过（"
        f"PTCore {len(core_sources)} 个源文件，"
        f"PTApp {len(app_sources)} 个源文件，"
        f"PTQml {len(qml_sources)} 个源文件）"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
