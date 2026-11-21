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
SYNC_CORE_FILES = frozenset({
    "LocalSyncFolder",
    "RemoteSyncFolder",
    "SyncApplier",
    "SyncCrypto",
    "SyncEngine",
    "SyncFiles",
    "SyncFolder",
    "SyncHttpClient",
    "SyncPairing",
    "SyncRecord",
    "SyncSchema",
    "SyncServerWatcher",
    "SyncStore",
    "SyncWorker",
})
SYNC_COORDINATOR_FILES = frozenset({
    "SyncController",
    "SyncNotifier",
    "SyncedSettings",
})
# 覆盖全部 071 同步核心文件与协同适配器，避免新增 Sync* 模块漏出 R4 边界。
SYNC_FILES = set(SYNC_CORE_FILES | SYNC_COORDINATOR_FILES)
SYNC_INCLUDE_ALLOWLIST = {
    "LocalSyncFolder.h",
    "RemoteSyncFolder.h",
    "SyncApplier.h",
    "SyncCrypto.h",
    "SyncEngine.h",
    "SyncFiles.h",
    "SyncFolder.h",
    "SyncHttpClient.h",
    "SyncPairing.h",
    "SyncRecord.h",
    "SyncSchema.h",
    "SyncServerWatcher.h",
    "SyncStore.h",
    "SyncWorker.h",
    "DatabaseManager.h",
    "ServiceReadResult.h",
    "FocusSessionRules.h",
    "RoutineRules.h",
}
SYNC_COORDINATOR_HEADER_ALLOWLIST = set(SYNC_INCLUDE_ALLOWLIST) | {
    "SyncController.h",
    "SyncNotifier.h",
    "SyncedSettings.h",
}
SYNC_COORDINATOR_CPP_ALLOWLIST = {
    "SyncedSettings": SYNC_INCLUDE_ALLOWLIST | {
        "SyncedSettings.h",
        "AppSettings.h",
        "ScheduleService.h",
    },
    "SyncController": SYNC_INCLUDE_ALLOWLIST | {
        "SyncController.h",
        "SyncNotifier.h",
        "SyncedSettings.h",
        "AppSettings.h",
        "ScheduleService.h",
    },
    "SyncNotifier": SYNC_INCLUDE_ALLOWLIST | {
        "SyncNotifier.h",
        "SyncedSettings.h",
        "AppSettings.h",
        "CategoryManager.h",
        "CountdownService.h",
        "FocusHistoryService.h",
        "KnowledgeGapService.h",
        "MemoService.h",
        "RoutineManager.h",
        "ScheduleService.h",
        "TaskManager.h",
        "TrashStore.h",
    },
}
INCLUDE_RE = re.compile(r"^\s*#\s*include\s*[<\"]([^>\"]+)[>\"]")
QML_INCLUDE_RE = re.compile(r"^(?:QQml|QQuick|QJS|QtQml/|QtQuick/)")
PLATFORM_MACRO_RE = re.compile(r"\b(?:Q_OS_[A-Za-z0-9_]*|__APPLE__|TARGET_OS_[A-Za-z0-9_]*)\b")
APPLE_ONLY_MACRO_RE = re.compile(r"\b(?:__APPLE__|TARGET_OS_[A-Za-z0-9_]*)\b")

# R9：服务单例只减不增（062 A057）。存量约 569 处 ::instance() 调用不一次性迁移，迁移顺序见
# docs/062-服务单例迁移设计.md；新服务由 SharedApp 构造、经 AppServices 注入。名单按 instance()
# 的返回类型记（TrashStore.h 里的单例是 TrashNotifier，MonotonicClock.h 里的是 SystemMonotonicClock）。
SINGLETON_ALLOWLIST = frozenset({
    "AppSettings",
    "BackupService",
    "CategoryManager",
    "CountdownService",
    "DatabaseManager",
    "ExportService",
    "FocusHistoryService",
    "FocusTimer",
    "KnowledgeGapService",
    "LogicalDayService",
    "MemoService",
    "NotificationService",
    "PhaseSoundService",
    "RoutineManager",
    "ScheduleService",
    "ShortcutRegistry",
    "StatisticsService",
    "SystemMonotonicClock",
    "TaskManager",
    "TrashNotifier",
    "TrashService",
})
# 只认类内的静态声明（out-of-line 定义如 Kept::instance 不计入）；支持指针、引用、east-const、instance(void)、属性、inline 与尾置返回类型。
SINGLETON_PREFIX = r"(?:(?:inline|static|\[\[[^\]]*\]\])\s+)*\bstatic\s+(?:(?:inline|const|\[\[[^\]]*\]\])\s+)*"
SINGLETON_TYPE = r"((?:[A-Za-z_]\w*\s*::\s*)*[A-Za-z_]\w*)"
SINGLETON_DECL_RE = re.compile(
    SINGLETON_PREFIX + SINGLETON_TYPE + r"(?:\s+const)?\s*[*&]\s*(?:\bconst\s+)?(?<!::)\binstance\s*\(\s*(?:void\s*)?\)"
)
SINGLETON_TRAILING_RE = re.compile(
    SINGLETON_PREFIX
    + r"auto\s+(?<!::)\binstance\s*\(\s*(?:void\s*)?\)\s*(?:const\s+|noexcept(?:\s*\([^)]*\))?\s*)*->\s*(?:const\s+)?"
    + SINGLETON_TYPE
    + r"(?:\s+const)?\s*[*&]"
)


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


def strip_comments_and_continuations(code: str) -> str:
    """移除反斜杠续行、行注释与块注释，但保留引号/尖括号文本，专用于精准扫描 #include 指令。"""
    code = code.replace("\r\n", "\n")
    while "\\\n" in code:
        code = code.replace("\\\n", "")
    result: list[str] = []
    i = 0
    n = len(code)
    while i < n:
        c = code[i]
        if i + 1 < n and code[i : i + 2] == "//":
            i += 2
            while i < n and code[i] != "\n":
                i += 1
        elif i + 1 < n and code[i : i + 2] == "/*":
            i += 2
            has_newline = False
            while i + 1 < n and code[i : i + 2] != "*/":
                if code[i] == "\n":
                    has_newline = True
                i += 1
            i += 2
            result.append("\n" if has_newline else " ")
        elif c in ('"', "'"):
            q = c
            result.append(c)
            i += 1
            while i < n:
                ch = code[i]
                result.append(ch)
                if ch == "\\" and i + 1 < n:
                    result.append(code[i + 1])
                    i += 2
                    continue
                i += 1
                if ch == q:
                    break
        else:
            result.append(c)
            i += 1
    return "".join(result)


def strip_comments_and_strings(code: str) -> str:
    """按 C++ 词法移除注释与字符串内容，正确处理反斜杠续行、Raw String 与 C++14 数字分隔符。"""
    code = code.replace("\r\n", "\n")
    while "\\\n" in code:
        code = code.replace("\\\n", "")

    result: list[str] = []
    i = 0
    n = len(code)
    while i < n:
        c = code[i]
        if i + 1 < n and code[i : i + 2] == "//":
            i += 2
            while i < n and code[i] != "\n":
                i += 1
        elif i + 1 < n and code[i : i + 2] == "/*":
            i += 2
            has_newline = False
            while i + 1 < n and code[i : i + 2] != "*/":
                if code[i] == "\n":
                    has_newline = True
                i += 1
            i += 2
            result.append("\n" if has_newline else " ")
        elif c.isdigit() or (c == "." and i + 1 < n and code[i + 1].isdigit()):
            # 扫描完整数字字面量，跳过内部的 C++14 单引号数字分隔符，避免把 40'000 当成字符字面量起点。
            num_buf: list[str] = [c]
            i += 1
            while i < n:
                ch = code[i]
                if ch in "eEpP" and i + 1 < n and code[i + 1] in "+-":
                    num_buf.append(ch)
                    num_buf.append(code[i + 1])
                    i += 2
                elif ch == "'" and i + 1 < n and (code[i + 1].isalnum() or code[i + 1] == "_"):
                    i += 1
                elif ch.isalnum() or ch in "._":
                    num_buf.append(ch)
                    i += 1
                else:
                    break
            result.append("".join(num_buf))
        elif c.isalpha() or c == "_":
            # 先读出完整标识符，再判断是否属于 u8/u/U/L/R 字符串前缀（避免 myR"..." 误判）。
            j = i + 1
            while j < n and (code[j].isalnum() or code[j] == "_"):
                j += 1
            ident = code[i:j]
            if ident in {"R", "u8R", "uR", "UR", "LR"} and j < n and code[j] == '"':
                raw_m = re.match(r'"([^\s()\\]{0,16})\(', code[j:])
                if raw_m:
                    delim = ")" + raw_m.group(1) + '"'
                    end_pos = code.find(delim, j + raw_m.end())
                    i = (end_pos + len(delim)) if end_pos >= 0 else n
                    result.append('""')
                    continue
            if ident in {"u8", "u", "U", "L"} and j < n and code[j] == '"':
                i = j
                continue
            if ident in {"u8", "u", "U", "L"} and j < n and code[j] == "'":
                i = j
                continue
            result.append(ident)
            i = j
        elif c == '"':
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
        elif c == "'":
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
            result.append(c)
            i += 1
    return "".join(result)


def _match_function_header(header: str) -> tuple[str, str] | None:
    """用括号配对解析 C++ 函数定义头，支持参数默认值中的嵌套括号、尾置返回与成员初始化列表。"""
    # 顶层出现 `=`（在括号外），说明是变量/lambda 初始化而非函数签名。
    pdepth = 0
    adepth = 0
    top_parens: list[tuple[int, int]] = []
    paren_start = -1
    limit_idx = len(header)
    i = 0
    while i < len(header):
        ch = header[i]
        if ch == "<":
            adepth += 1
        elif ch == ">" and adepth > 0:
            adepth -= 1
        elif ch == "(":
            if pdepth == 0:
                paren_start = i
            pdepth += 1
        elif ch == ")" and pdepth > 0:
            pdepth -= 1
            if pdepth == 0 and paren_start >= 0:
                top_parens.append((paren_start, i))
                paren_start = -1
        elif pdepth == 0:
            if ch == "=":
                return None
            if ch == "-" and i + 1 < len(header) and header[i + 1] == ">":
                limit_idx = i
                break
            if ch == ":" and not (i + 1 < len(header) and header[i + 1] == ":") and not (i > 0 and header[i - 1] == ":"):
                limit_idx = i
                break
        i += 1

    candidates = [pair for pair in top_parens if pair[1] < limit_idx]
    if not candidates:
        return None
    ps, pe = candidates[-1]
    suffix = header[pe + 1 : limit_idx].strip()
    # 仅允许 noexcept / const / override / final / 空格作为签名后修饰符。
    cleaned_suffix = re.sub(r"\bnoexcept\s*(?:\([^)]*\))?", "", suffix)
    for kw in ("const", "override", "final", "volatile", "&", "&&"):
        cleaned_suffix = re.sub(r"(?<!\w)" + re.escape(kw) + r"(?!\w)" if kw.isalpha() else re.escape(kw), "", cleaned_suffix)
    if cleaned_suffix.strip():
        return None

    before = header[:ps].strip()
    name_m = re.search(r"([A-Za-z_]\w*(?:\s*::\s*[A-Za-z_]\w*)*)$", before)
    if not name_m:
        return None
    full_name = name_m.group(1)
    simple = full_name.split("::")[-1].strip()
    if simple in {"if", "while", "for", "switch", "catch", "decltype", "alignas"}:
        return None
    return full_name, header[ps + 1 : pe]


def parse_scope_declarations(
    code: str,
    current_ns: list[str],
    declared_classes: set[str] | None = None,
) -> tuple[list[dict], list[str], list[tuple[tuple[str, ...], str]]]:
    """递归解析命名空间、函数定义与作用域外顶层语句。"""
    if declared_classes is None:
        declared_classes = set()
    functions: list[dict] = []
    unsupported_errors: list[str] = []
    top_statements: list[tuple[tuple[str, ...], str]] = []
    i = 0
    n = len(code)
    last_stmt_end = 0

    while i < n:
        char = code[i]
        if char == ";":
            stmt = code[last_stmt_end:i].strip()
            if stmt:
                top_statements.append((tuple(current_ns), stmt))
            last_stmt_end = i + 1
            i += 1
        elif char == "{":
            header = code[last_stmt_end:i].strip()

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

                # 1. namespace [name] { ... }
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
                    sub_funcs, sub_errs, sub_tops = parse_scope_declarations(
                        block_body, sub_ns, declared_classes
                    )
                    functions.extend(sub_funcs)
                    unsupported_errors.extend(sub_errs)
                    top_statements.extend(sub_tops)
                    last_stmt_end = j
                    i = j
                    continue

                # 2. class / struct 定义（注意避免误伤返回值含 struct Foo* 的函数定义）
                struct_head_m = re.match(
                    r"^(?:template\s*<[^>]*>\s*)?(class|struct)\s+([A-Za-z_]\w*)", header
                )
                parsed_fn = _match_function_header(header)
                if struct_head_m or (re.search(r"\b(?:class|struct)\b", header) and parsed_fn is None):
                    if struct_head_m:
                        declared_classes.add(struct_head_m.group(2))
                    if re.search(r"\([^)]*\)[^;{]*\{", block_body):
                        unsupported_errors.append("class/struct 内包含成员函数实现")
                    top_statements.append((tuple(current_ns), header + "{" + block_body + "}"))
                    last_stmt_end = j
                    i = j
                    continue

                # 3. 命名函数定义
                if parsed_fn is not None:
                    full_fn_name, params_str = parsed_fn
                    fn_parts = [p.strip() for p in full_fn_name.split("::") if p.strip()]
                    func_name = fn_parts[-1]
                    extra_ns = fn_parts[:-1]
                    if any(part in declared_classes for part in extra_ns):
                        unsupported_errors.append(f"class/struct 成员函数类外定义 {full_fn_name}")
                    fn_ns = current_ns + extra_ns
                    is_main = func_name == "main" and not fn_ns
                    functions.append({
                        "name": func_name,
                        "namespace": list(fn_ns),
                        "body": block_body,
                        "params": params_str,
                        "is_main": is_main,
                    })
                else:
                    # 非命名函数的块（如全局 brace/lambda 初始化），交给顶层语句检查。
                    top_statements.append((tuple(current_ns), header + "{" + block_body + "}"))

                last_stmt_end = j
                i = j
            else:
                break
        else:
            i += 1

    return functions, unsupported_errors, top_statements


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
    # 剥离 #include / #pragma 行，防止 `#include <QSettings>` 被顶层语句检查误当成全局代码。
    clean_code = re.sub(r"(?m)^\s*#\s*(?:include|pragma|line)\b[^\n]*", "", clean_code)

    # 入口文件禁止使用条件编译或宏定义（防止用 #ifdef 包裹 applyApplicationIdentity 或用 #define 隐藏危险操作）
    if re.search(r"(?m)^\s*#\s*(?:if|ifdef|ifndef|elif|else|endif|define|undef)\b", clean_code):
        fail(f"R8：{entry_path} 中存在不支持解析的预处理条件编译或宏指令，轻量门禁无法保证启动时序，拒绝放行")
        return False

    # 0. 检查轻量门禁不支持的语法：using namespace、无等号 using 符号声明、命名空间别名与危险类型别名追踪
    if re.search(r"\busing\s+namespace\b", clean_code):
        fail(f"R8：{entry_path} 中存在不支持解析的语法（using namespace 指令），轻量门禁无法保证启动时序，拒绝放行")
        return False

    alias_targets: dict[str, str] = {}
    for m in re.finditer(r"\busing\s+([^;{]+);", clean_code):
        stmt = m.group(1).strip()
        if stmt.startswith("namespace ") or stmt.startswith("namespace\t"):
            continue
        if "=" not in stmt:
            fail(f"R8：{entry_path} 中存在不支持解析的语法（using 符号声明），轻量门禁无法保证启动时序，拒绝放行")
            return False
        lhs, rhs = stmt.split("=", 1)
        alias_name = lhs.strip().split()[-1] if lhs.strip() else ""
        if re.fullmatch(r"[A-Za-z_]\w*", alias_name):
            alias_targets[alias_name] = rhs.strip()

    for m in re.finditer(r"\btypedef\s+([^;{]+)\s+([A-Za-z_]\w*)\s*;", clean_code):
        alias_targets[m.group(2)] = m.group(1).strip()

    if re.search(r"\bnamespace\s+[A-Za-z_]\w*\s*=\s*[A-Za-z_][\w:]*\s*;", clean_code):
        fail(f"R8：{entry_path} 中存在不支持解析的语法（命名空间别名定义），轻量门禁无法保证启动时序，拒绝放行")
        return False

    all_funcs, unsupported_errs, top_statements = parse_scope_declarations(clean_code, [])
    if unsupported_errs:
        fail(f"R8：{entry_path} 中存在不支持解析的语法（{unsupported_errs[0]}），轻量门禁无法保证启动时序，拒绝放行")
        return False

    main_funcs = [f for f in all_funcs if f["is_main"]]
    if not main_funcs:
        fail(f"R8：在 {entry_path} 中未找到顶层 main() 函数体")
        return False

    main_body = main_funcs[0]["body"]

    # 1. 检查 QGuiApplication 实例创建（排除 QGuiApplication::setAttribute 等静态调用伪装）
    app_match = re.search(r"\bQGuiApplication\b(?!\s*::)", main_body)
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

    # 3. 检查 main() 内直接危险操作（含单例 instance() 访问与通过类型别名引入的危险类型）是否出现在身份设置之前
    dangerous_patterns: list[tuple[str, re.Pattern]] = [
        ("QSettings", re.compile(r"\bQSettings\b")),
        ("QStandardPaths", re.compile(r"\bQStandardPaths\b")),
        ("MacPreferencesCleanup", re.compile(r"\bMacPreferencesCleanup\b")),
        ("SingleInstanceGuard", re.compile(r"\bSingleInstanceGuard\b")),
        ("openDatabase", re.compile(r"\bopenDatabase\s*\(")),
        ("resolveProduction", re.compile(r"\bresolveProduction\s*\(")),
        ("McpAccessController", re.compile(r"\bMcpAccessController\b")),
        ("MacSqliteRuntime", re.compile(r"\bMacSqliteRuntime\b")),
        ("AppSettings", re.compile(r"\bAppSettings\b")),
        ("BackupService", re.compile(r"\bBackupService\b")),
        ("DatabaseManager", re.compile(r"\bDatabaseManager\b")),
        ("SharedApp", re.compile(r"\bSharedApp\b")),
        ("singleton instance()", re.compile(r"\b[A-Za-z_]\w*\s*::\s*instance\s*\(")),
    ]

    # 展开 using/typedef 类型别名闭包：using S = QSettings; using S2 = S; 均视为危险类型。
    dangerous_aliases: set[str] = set()
    changed_alias = True
    while changed_alias:
        changed_alias = False
        for alias_name, rhs in alias_targets.items():
            if alias_name in dangerous_aliases:
                continue
            hits_base = any(p.search(rhs) for _, p in dangerous_patterns)
            hits_alias = any(re.search(rf"\b{re.escape(da)}\b", rhs) for da in dangerous_aliases)
            if hits_base or hits_alias:
                dangerous_aliases.add(alias_name)
                dangerous_patterns.append((f"alias {alias_name}", re.compile(rf"\b{re.escape(alias_name)}\b")))
                changed_alias = True

    for name, pattern in dangerous_patterns:
        for m in pattern.finditer(main_body):
            if m.start() < pos_identity:
                fail(
                    f"R8：{entry_path} 中操作 {name}（位置 {m.start()}）出现在 "
                    f"McpPaths::applyApplicationIdentity()（位置 {pos_identity}）之前"
                )
                return False

    # 4. 分析 main 之外的辅助函数（同时覆盖函数体与参数默认值表达式）
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
        grouped_funcs[key]["bodies"].append(fn["params"] + "\n" + fn["body"])

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

    # 4.3 检查顶层/命名空间静态全局初始化（全部早于 main() 执行）
    for stmt_ns, stmt in top_statements:
        for name, pattern in dangerous_patterns:
            if pattern.search(stmt):
                fail(f"R8：{entry_path} 的全局/命名空间作用域初始化包含危险操作 {name}（早于 main 执行）")
                return False
        for is_global, qual_parts, call_name, _ in extract_calls(stmt):
            target_sym = resolve_call(stmt_ns, is_global, qual_parts, call_name, grouped_funcs)
            if target_sym is not None and target_sym["is_dangerous"]:
                fail(
                    f"R8：{entry_path} 的全局/命名空间作用域调用了含危险操作的辅助函数 "
                    f"{target_sym['display_name']}（早于 main 执行）"
                )
                return False

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


def find_singletons(source_root: Path) -> dict[str, list[Path]] | None:
    """列出 source_root 下头文件里声明 instance() 单例的类型及所在头文件；读不出文件时返回 None。"""
    found: dict[str, list[Path]] = {}
    for header in sorted(list(source_root.rglob("*.h")) + list(source_root.rglob("*.hpp"))):
        try:
            text = header.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            fail(f"R9：无法读取头文件 {header}: {exc}")
            return None
        stripped = strip_comments_and_strings(text)
        for pattern in (SINGLETON_DECL_RE, SINGLETON_TRAILING_RE):
            for match in pattern.finditer(stripped):
                type_name = re.sub(r"\s+", "", match.group(1)).split("::")[-1]
                paths = found.setdefault(type_name, [])
                if header not in paths:
                    paths.append(header)
    return found


def check_singletons_r9(source_root: Path, allowlist: frozenset[str] = SINGLETON_ALLOWLIST) -> bool:
    """R9：source_root 下头文件里声明的 instance() 单例不得超出白名单。

    白名单里的类去掉单例不算失败（允许逐步迁移），只提示把它从名单里删掉，免得名单留着空位被复用。
    """
    found = find_singletons(source_root)
    if found is None:
        return False

    valid = True
    for type_name in sorted(set(found) - allowlist):
        locations = "、".join(str(path) for path in found[type_name])
        fail(
            f"R9：{locations} 新增了 {type_name}::instance() 单例。新服务由 SharedApp/AppServices "
            f"构造并注入，不再新增 instance() 单例（见 docs/062-服务单例迁移设计.md）"
        )
        valid = False
    for type_name in sorted(allowlist - set(found)):
        print(f"ArchitectureGate R9 提示：{type_name} 已不再声明 instance()，请从 SINGLETON_ALLOWLIST 中移除")
    return valid


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

    def transitive_project_includes(start_file: Path) -> set[Path]:
        visited: set[Path] = set()
        queue = [start_file]
        while queue:
            cur = queue.pop(0)
            try:
                cur_text = strip_comments_and_continuations(cur.read_text(encoding="utf-8"))
            except OSError:
                continue
            for inc_line in cur_text.splitlines():
                inc_m = INCLUDE_RE.match(inc_line)
                if not inc_m:
                    continue
                res = resolve_include(inc_m.group(1), cur, root)
                if res is None or not res.is_relative_to(root) or res in visited:
                    continue
                visited.add(res)
                queue.append(res)
        return visited

    for source in sorted(core_sources):
        stem = source.stem
        try:
            text = source.read_text(encoding="utf-8")
        except OSError as exc:
            fail(f"无法读取 PTCore 源文件 {source}: {exc}")
            valid = False
            continue

        stripped_text = strip_comments_and_strings(text)
        include_scan_text = strip_comments_and_continuations(text)
        if stem == "PhaseSoundService":
            if APPLE_ONLY_MACRO_RE.search(stripped_text):
                fail(f"R5：{source.relative_to(root)} 不允许使用 __APPLE__ 或 TARGET_OS_* 宏")
                valid = False
        elif PLATFORM_MACRO_RE.search(stripped_text):
            fail(f"R5：{source.relative_to(root)} 含平台宏（Q_OS_/__APPLE__/TARGET_OS_），现存唯一例外仅允许 PhaseSoundService.cpp 的 Q_OS_")
            valid = False

        if "Sync" in stem and stem not in SYNC_FILES:
            fail(f"R4：同步服务文件 {source.relative_to(root)} 未纳入 SYNC_CORE_FILES / SYNC_COORDINATOR_FILES 边界管辖")
            valid = False

        for line in include_scan_text.splitlines():
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

        # R4 同步层直接 + 传递本地头文件闭包检查
        if stem in SYNC_CORE_FILES:
            for dep in sorted(transitive_project_includes(source)):
                if dep.name not in SYNC_INCLUDE_ALLOWLIST:
                    fail(
                        f"R4：{source.relative_to(root)} 直接或传递 include 了 {dep.name}；"
                        f"同步核心白名单为 {sorted(SYNC_INCLUDE_ALLOWLIST)}"
                    )
                    valid = False
        elif stem in SYNC_COORDINATOR_FILES:
            if source.suffix in {".h", ".hpp"}:
                for dep in sorted(transitive_project_includes(source)):
                    if dep.name not in SYNC_COORDINATOR_HEADER_ALLOWLIST:
                        fail(
                            f"R4：同步协同头文件 {source.relative_to(root)} 传递 include 了 {dep.name}"
                        )
                        valid = False
            else:
                allowed_direct = SYNC_COORDINATOR_CPP_ALLOWLIST[stem]
                for line in include_scan_text.splitlines():
                    match = INCLUDE_RE.match(line)
                    if not match:
                        continue
                    resolved = resolve_include(match.group(1), source, root)
                    if resolved is None or not resolved.is_relative_to(root):
                        continue
                    if resolved.name not in allowed_direct:
                        fail(
                            f"R4：{source.relative_to(root)} 不允许 include {resolved.name}；"
                            f"允许集合为 {sorted(allowed_direct)}"
                        )
                        valid = False
                    if resolved.stem in SYNC_CORE_FILES:
                        for trans_dep in sorted(transitive_project_includes(resolved)):
                            if trans_dep.name not in SYNC_INCLUDE_ALLOWLIST:
                                fail(
                                    f"R4：{source.relative_to(root)} 经 {resolved.name} 传递 include 了 {trans_dep.name}"
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

        if PLATFORM_MACRO_RE.search(strip_comments_and_strings(text)):
            fail(f"R6：{source.relative_to(root)} 含平台分支宏（Q_OS_/__APPLE__/TARGET_OS_），PTApp 不允许包含任何平台分支宏")
            valid = False
        for line in strip_comments_and_continuations(text).splitlines():
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

        if PLATFORM_MACRO_RE.search(strip_comments_and_strings(text)):
            fail(f"R7：{source.relative_to(root)} 含平台分支宏（Q_OS_/__APPLE__/TARGET_OS_），PTQml 不允许包含任何平台分支宏")
            valid = False
        for line in strip_comments_and_continuations(text).splitlines():
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
        for line in strip_comments_and_continuations(text).splitlines():
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

    # 6. R9 检查：服务单例只减不增
    if not check_singletons_r9(root / "src"):
        valid = False

    # 7. 检查 PomodoroTodoMcp 清单：helper 禁止静态或直接链接业务库/SQLite，源码必须限制在 helper/common
    mcp_helper = manifest.get("PomodoroTodoMcp")
    if mcp_helper is not None:
        if not isinstance(mcp_helper, dict) or not isinstance(mcp_helper.get("sources"), list):
            fail("PomodoroTodoMcp 清单格式无效")
            valid = False
        else:
            allowed_mcp_links = {"Qt6::Core", "Qt6::Network"}
            # qt_add_executable 会注入 Qt6 权限插件条件生成器表达式（QT_IS_PLUGIN_GENEX）；仅放行该已知插件表达式，其余一切生成器表达式与链接仍严格受限。
            qt_perm_plugin_re = re.compile(
                r"^\$<\$<BOOL:\$<AND:\$<BOOL:QT_IS_PLUGIN_GENEX>,.*>>:Qt6::QDarwin[A-Za-z0-9_]*PermissionPlugin(?:_init)?>$"
            )
            raw_mcp_links = [
                x for x in (mcp_helper.get("link_libraries") or [])
                if not (isinstance(x, str) and qt_perm_plugin_re.fullmatch(x))
            ]
            mcp_direct, mcp_direct_ok = link_items(raw_mcp_links, "PomodoroTodoMcp", "LINK_LIBRARIES")
            mcp_iface, mcp_iface_ok = link_items(mcp_helper.get("interface_link_libraries"), "PomodoroTodoMcp", "INTERFACE_LINK_LIBRARIES")
            valid = valid and mcp_direct_ok and mcp_iface_ok
            for dep in mcp_direct + mcp_iface:
                if dep not in allowed_mcp_links:
                    fail(f"PomodoroTodoMcp 不允许链接 {dep!r}，只允许 {sorted(allowed_mcp_links)}")
                    valid = False

            allowed_mcp_prefixes = ((root / "src/mcp/helper").resolve(), (root / "src/mcp/common").resolve())
            forbidden_mcp_inc_prefixes = (
                "QSql", "QtSql/", "QGui", "QtGui/", "QtWidgets/", "QWidget",
                "QApplication", "QMainWindow", "QDialog", "QtConcurrent", "QFuture", "QtMultimedia",
            )
            for raw in mcp_helper["sources"]:
                if not isinstance(raw, str):
                    fail(f"PomodoroTodoMcp.sources 含非文本项：{raw!r}")
                    valid = False
                    continue
                src_p = Path(raw)
                if not src_p.is_absolute():
                    src_p = root / src_p
                src_p = src_p.resolve()
                if not any(src_p.is_relative_to(pref) for pref in allowed_mcp_prefixes):
                    fail(f"PomodoroTodoMcp 禁止直接编入外部源码：{src_p.relative_to(root)}")
                    valid = False
                if src_p.is_file():
                    for line in strip_comments_and_continuations(src_p.read_text(encoding="utf-8")).splitlines():
                        inc_m = INCLUDE_RE.match(line)
                        if not inc_m:
                            continue
                        inc = inc_m.group(1)
                        if QML_INCLUDE_RE.match(inc) or "sqlite" in inc.lower() or inc.startswith(forbidden_mcp_inc_prefixes):
                            fail(f"PomodoroTodoMcp 源文件 {src_p.relative_to(root)} 禁止 include {inc}")
                            valid = False
                        res = resolve_include(inc, src_p, root)
                        if res is not None and res.is_relative_to(root):
                            if not any(res.is_relative_to(pref) for pref in allowed_mcp_prefixes):
                                fail(f"PomodoroTodoMcp 禁止 include {res.relative_to(root)}")
                                valid = False

    if not valid:
        return 1

    print(
        f"ArchitectureGate: PTCore、PTApp 与 PTQml R1-R9 全部通过（"
        f"PTCore {len(core_sources)} 个源文件，"
        f"PTApp {len(app_sources)} 个源文件，"
        f"PTQml {len(qml_sources)} 个源文件）"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
