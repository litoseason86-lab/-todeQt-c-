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
# 059仅为核心的独立备份连接增加原生SQLite依赖；PTApp/PTQml仍不能直接链接它。
ALLOWED_CORE_LINKS = ALLOWED_QT_LINKS | {"SQLite::SQLite3"}
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
    """移除 C++ 源码中的注释和字符串字面量，保留其余代码结构与必要词法分隔。"""
    result = []
    i = 0
    n = len(code)
    while i < n:
        if i + 1 < n and code[i : i + 2] == "//":
            i += 2
            while i < n and code[i] != "\n":
                i += 1
            # 换行符在循环下一步处理，保留换行结构
        elif i + 1 < n and code[i : i + 2] == "/*":
            i += 2
            has_newline = False
            while i + 1 < n and code[i : i + 2] != "*/":
                if code[i] == "\n":
                    has_newline = True
                i += 1
            i += 2
            # 块注释用一个空格（或换行）替代，保留词法分隔，防止前后 token 拼接
            result.append("\n" if has_newline else " ")
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
            result.append('""')
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
            result.append("''")
        else:
            result.append(code[i])
            i += 1
    return "".join(result)


def parse_scope_declarations(
    code: str, current_ns: list[str]
) -> tuple[list[dict], list[str]]:
    """递归解析 code 文本中的命名空间与函数定义，并收集不支持解析的语法错误。

    返回 (functions, unsupported_errors)。
    functions 列表中每项表示一个函数定义：
      name: 函数简单名称，如 'loadSettings'
      namespace: 当前所在的命名空间路径列表，如 ['startup'] 或 ['']（匿名）或 []（全局）
      body: 函数体文本（不含外层大括号）
      is_main: bool，是否为 main 函数
    """
    functions: list[dict] = []
    unsupported_errors: list[str] = []
    i = 0
    n = len(code)
    last_stmt_end = 0

    while i < n:
        char = code[i]
        if char == ";":
            last_stmt_end = i + 1
            i += 1
        elif char == "{":
            header = code[last_stmt_end:i].strip()

            # 寻找配对的闭合大括号
            depth = 1
            j = i + 1
            while j < n and depth > 0:
                if code[j] == "{":
                    depth += 1
                elif code[j] == "}":
                    depth -= 1
                j += 1

            if depth == 0:
                block_body = code[i + 1 : j - 1]

                # 1. 检查是否为命名空间：namespace [name] {
                ns_match = re.search(
                    r"\bnamespace(?:\s+([A-Za-z_][\w:]*))?\s*$", header, re.DOTALL
                )
                if ns_match:
                    ns_name = ns_match.group(1)
                    if ns_name:
                        parts = [p.strip() for p in ns_name.split("::") if p.strip()]
                        sub_ns = current_ns + parts
                    else:
                        sub_ns = current_ns + [""]
                    sub_funcs, sub_errs = parse_scope_declarations(block_body, sub_ns)
                    functions.extend(sub_funcs)
                    unsupported_errors.extend(sub_errs)
                else:
                    # 2. 检查是否为 class 或 struct 定义
                    struct_match = re.search(r"\b(?:class|struct)\b", header) and not re.search(
                        r"\)\s*(?:const|noexcept|override|final|\s)*$", header
                    )
                    if struct_match:
                        # 若类/结构体内包含成员函数实现体（覆盖普通方法、const、noexcept、override 等限定符修饰的方法实现）
                        # 轻量门禁不支持解析类作用域，明确诊断并拒绝
                        if re.search(r"\([^)]*\)[^;{]*\{", block_body):
                            unsupported_errors.append("class/struct 内包含成员函数实现")
                    else:
                        # 3. 检查是否为函数定义
                        fn_match = re.search(
                            r"\b([A-Za-z_]\w*(?:\s*::\s*[A-Za-z_]\w*)*)\s*\([^)]*\)\s*(?:const|noexcept|override|final|\s)*$",
                            header,
                            re.DOTALL,
                        )
                        if fn_match:
                            full_fn_name = fn_match.group(1)
                            fn_parts = [p.strip() for p in full_fn_name.split("::") if p.strip()]
                            func_name = fn_parts[-1]
                            extra_ns = fn_parts[:-1]
                            if func_name not in {"if", "while", "for", "switch", "catch"}:
                                fn_ns = current_ns + extra_ns
                                is_main = (func_name == "main" and not fn_ns)
                                functions.append({
                                    "name": func_name,
                                    "namespace": list(fn_ns),
                                    "body": block_body,
                                    "is_main": is_main,
                                })

                last_stmt_end = j
                i = j
            else:
                break
        else:
            i += 1

    return functions, unsupported_errors


CALL_RE = re.compile(
    r"(?<![A-Za-z0-9_:])(::)?\s*([A-Za-z_]\w*(?:\s*::\s*[A-Za-z_]\w*)*)\s*\("
)

IGNORED_KEYWORDS = {
    "if", "while", "for", "switch", "catch",
    "sizeof", "decltype", "static_cast", "dynamic_cast",
    "reinterpret_cast", "const_cast", "typeid",
}


def extract_calls(code: str) -> list[tuple[bool, list[str], str, int]]:
    """提取 code 中的所有函数调用表达式。

    返回四元组列表：(is_global, qual_parts, func_name, start_pos)
    - is_global: 是否带有全局前缀 '::'
    - qual_parts: 限定命名空间列表，如 ['outer', 'inner']
    - func_name: 调用的函数简单名称，如 'loadSettings'
    - start_pos: 调用在 code 中的起始字符偏移
    """
    calls: list[tuple[bool, list[str], str, int]] = []
    for m in CALL_RE.finditer(code):
        is_global = bool(m.group(1))
        full_name = m.group(2)
        parts = [p.strip() for p in full_name.split("::") if p.strip()]
        if not parts:
            continue
        func_name = parts[-1]
        qual_parts = parts[:-1]

        # 忽略控制流与类型运算符关键字调用
        if not is_global and not qual_parts and func_name in IGNORED_KEYWORDS:
            continue

        calls.append((is_global, qual_parts, func_name, m.start()))
    return calls


def resolve_call(
    caller_ns: tuple[str, ...],
    is_global: bool,
    qual_parts: list[str],
    func_name: str,
    grouped_funcs: dict[tuple[tuple[str, ...], str], dict],
) -> dict | None:
    """按 C++ 名称查找规则将调用解析到对应的函数符号组。

    支持逐级向外查找和近层同名函数遮蔽（Shadowing）。
    """
    qual_tuple = tuple(qual_parts)

    def find_in_candidate(candidate_ns: tuple[str, ...]) -> dict | None:
        # 1. 优先在 candidate_ns 命名空间中精确匹配
        key = (candidate_ns, func_name)
        if key in grouped_funcs:
            return grouped_funcs[key]
        # 2. 检查 candidate_ns 命名空间内的匿名命名空间
        for (sym_def_ns, sym_name), sym_info in grouped_funcs.items():
            if sym_name == func_name:
                if len(sym_def_ns) > len(candidate_ns) and sym_def_ns[: len(candidate_ns)] == candidate_ns:
                    if all(p == "" for p in sym_def_ns[len(candidate_ns) :]):
                        return sym_info
        return None

    # 全局限定调用（如 ::outer::inner::loadSettings()）：只从全局顶级查找
    if is_global:
        return find_in_candidate(qual_tuple)

    # 相对限定调用或非限定短名调用：从 caller_ns 逐级向外层查找
    # 过滤 caller_ns 中的匿名命名空间标记 ""，得到具名作用域层级
    effective_ns = tuple(p for p in caller_ns if p)
    for k in range(len(effective_ns), -1, -1):
        candidate_ns = effective_ns[:k] + qual_tuple
        matched = find_in_candidate(candidate_ns)
        if matched is not None:
            return matched

    return None


def get_brace_depth(text: str, pos: int) -> int:
    """计算 text 中指定字符位置 pos 处的大括号深度。"""
    depth = 0
    for idx in range(pos):
        if text[idx] == "{":
            depth += 1
        elif text[idx] == "}":
            depth -= 1
    return depth


def check_top_level_identity_statement(main_body: str) -> tuple[bool, int, str]:
    """检查 main_body 中是否存在顶层、独立、无条件的 McpPaths::applyApplicationIdentity(); 语句。

    返回 (valid, pos_identity, error_msg)。
    """
    pattern = re.compile(
        r"\bMcpPaths\s*::\s*applyApplicationIdentity\s*\(\s*\)", re.DOTALL
    )
    matches = list(pattern.finditer(main_body))
    if not matches:
        return False, -1, "main() 中未调用 McpPaths::applyApplicationIdentity()"

    valid_positions: list[int] = []
    has_wrapped_call = False

    for m in matches:
        # 1. 必须在 main 顶层（大括号深度为 0）
        if get_brace_depth(main_body, m.start()) != 0:
            has_wrapped_call = True
            continue

        # 2. 检查后置字符：跳过空白符，必须紧跟 ';'
        post_idx = m.end()
        while post_idx < len(main_body) and main_body[post_idx].isspace():
            post_idx += 1
        if post_idx >= len(main_body) or main_body[post_idx] != ";":
            has_wrapped_call = True
            continue

        # 3. 检查前置字符：向前跳过空白符，必须是 ';' 或 '}'（或是 main_body 起始）
        pre_idx = m.start() - 1
        while pre_idx >= 0 and main_body[pre_idx].isspace():
            pre_idx -= 1
        if pre_idx >= 0 and main_body[pre_idx] not in {";", "}"}:
            has_wrapped_call = True
            continue

        valid_positions.append(m.start())

    if not valid_positions:
        if has_wrapped_call:
            return (
                False,
                -1,
                "McpPaths::applyApplicationIdentity() 必须在 main() 顶层作为独立、无条件的语句直接调用，"
                "禁止在 if/else、循环、短路表达式、条件表达式、lambda 或嵌套块中包装",
            )
        return False, -1, "main() 中未找到合法的 McpPaths::applyApplicationIdentity() 独立语句"

    return True, valid_positions[0], ""


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

    # 0. 检查轻量门禁不支持的语法：using namespace、using 符号声明、命名空间别名
    if re.search(r"\busing\s+namespace\b", clean_code):
        fail(f"R8：{entry_path} 中存在不支持解析的语法（using namespace 指令），轻量门禁无法保证启动时序，拒绝放行")
        return False

    for m in re.finditer(r"\busing\s+([^;{]+);", clean_code):
        stmt = m.group(1).strip()
        if stmt.startswith("namespace ") or stmt.startswith("namespace\t"):
            continue
        if "=" not in stmt:
            fail(f"R8：{entry_path} 中存在不支持解析的语法（using 符号声明），轻量门禁无法保证启动时序，拒绝放行")
            return False

    if re.search(r"\bnamespace\s+[A-Za-z_]\w*\s*=\s*[A-Za-z_][\w:]*\s*;", clean_code):
        fail(f"R8：{entry_path} 中存在不支持解析的语法（命名空间别名定义），轻量门禁无法保证启动时序，拒绝放行")
        return False

    all_funcs, unsupported_errs = parse_scope_declarations(clean_code, [])
    if unsupported_errs:
        fail(f"R8：{entry_path} 中存在不支持解析的语法（{unsupported_errs[0]}），轻量门禁无法保证启动时序，拒绝放行")
        return False

    main_funcs = [f for f in all_funcs if f["is_main"]]
    if not main_funcs:
        fail(f"R8：在 {entry_path} 中未找到顶层 main() 函数体")
        return False

    main_body = main_funcs[0]["body"]

    # 1. 检查 QGuiApplication 创建
    app_match = re.search(r"\bQGuiApplication\b", main_body)
    if not app_match:
        fail(f"R8：{entry_path} 的 main() 中未创建 QGuiApplication")
        return False
    pos_app = app_match.start()

    # 2. 检查 McpPaths::applyApplicationIdentity()，必须在 main 顶层直接、独立、无条件调用
    id_valid, pos_identity, id_err = check_top_level_identity_statement(main_body)
    if not id_valid:
        fail(f"R8：{entry_path} 中 {id_err}")
        return False

    if pos_app > pos_identity:
        fail(
            f"R8：{entry_path} 中 QGuiApplication（位置 {pos_app}）必须在 "
            f"McpPaths::applyApplicationIdentity()（位置 {pos_identity}）之前创建"
        )
        return False

    # 3. 检查 main() 内直接危险操作是否出现在身份设置之前
    dangerous_patterns: list[tuple[str, re.Pattern]] = [
        ("QSettings", re.compile(r"\bQSettings\b")),
        ("QStandardPaths", re.compile(r"\bQStandardPaths\b")),
        ("MacPreferencesCleanup", re.compile(r"\bMacPreferencesCleanup\b")),
        ("SingleInstanceGuard", re.compile(r"\bSingleInstanceGuard\b")),
        ("openDatabase", re.compile(r"\bopenDatabase\s*\(")),
    ]

    for name, pattern in dangerous_patterns:
        for m in pattern.finditer(main_body):
            if m.start() < pos_identity:
                fail(
                    f"R8：{entry_path} 中操作 {name}（位置 {m.start()}）出现在 "
                    f"McpPaths::applyApplicationIdentity()（位置 {pos_identity}）之前"
                )
                return False

    # 4. 分析 main 之外的辅助函数：按命名空间与函数名分组，保守合并同名重载危险性
    grouped_funcs: dict[tuple[tuple[str, ...], str], dict] = {}
    for fn in all_funcs:
        if fn["is_main"]:
            continue
        def_ns = tuple(fn["namespace"])
        name = fn["name"]
        key = (def_ns, name)

        if key not in grouped_funcs:
            qual_parts = [p for p in def_ns if p]
            display_name = ("::".join(qual_parts) + "::" + name) if qual_parts else name
            grouped_funcs[key] = {
                "name": name,
                "def_ns": def_ns,
                "display_name": display_name,
                "bodies": [],
                "is_dangerous": False,
            }
        grouped_funcs[key]["bodies"].append(fn["body"])

    # 4.1 初步判定直接危险性：只要同一分组内的任意重载包含危险操作，该函数组即为危险
    for gid, ginfo in grouped_funcs.items():
        ginfo["is_dangerous"] = any(
            any(pattern.search(b) for _, pattern in dangerous_patterns)
            for b in ginfo["bodies"]
        )

    # 4.2 传递闭包：如果函数 A 调用了危险函数 B，则 A 同样被判定为危险
    changed = True
    while changed:
        changed = False
        for a_key, a_info in grouped_funcs.items():
            if a_info["is_dangerous"]:
                continue
            caller_ns = a_info["def_ns"]
            for body in a_info["bodies"]:
                for is_global, qual_parts, call_name, _ in extract_calls(body):
                    target_sym = resolve_call(
                        caller_ns, is_global, qual_parts, call_name, grouped_funcs
                    )
                    if target_sym is not None and target_sym["is_dangerous"]:
                        a_info["is_dangerous"] = True
                        changed = True
                        break
                if a_info["is_dangerous"]:
                    break

    # 5. 检查 main() 中调用的辅助函数（按相同解析规则，检查身份设置之前的调用）
    caller_ns: tuple[str, ...] = ()  # main() 位于顶层全局作用域
    for is_global, qual_parts, call_name, call_pos in extract_calls(main_body):
        if call_pos >= pos_identity:
            continue
        target_sym = resolve_call(
            caller_ns, is_global, qual_parts, call_name, grouped_funcs
        )
        if target_sym is not None and target_sym["is_dangerous"]:
            fail(
                f"R8：辅助函数 {target_sym['display_name']}（含危险操作）在 main() 中的调用"
                f"（位置 {call_pos}）早于 applyApplicationIdentity()（位置 {pos_identity}）"
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
        if dependency not in ALLOWED_CORE_LINKS:
            fail(f"R1：PTCore 不允许链接 {dependency!r}，允许集合为 {sorted(ALLOWED_CORE_LINKS)}")
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
