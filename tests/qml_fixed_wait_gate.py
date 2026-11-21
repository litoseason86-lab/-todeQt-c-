#!/usr/bin/env python3
"""QML 测试里不直接写固定时长的等待（062 A059）。

起因：tests/qml 里曾有 334 处直接的 wait(<毫秒>)（按本门禁的判据数，含循环里的）。它们要么白等（状态当场就到了），要么在负载高的机器上
不够长，偶发失败只能靠重跑；还有一部分放在「断言某件事没发生」之前，换成 tryCompare 会在第一轮就通过，
等于把检查删了。所以规则分两半：
- 等「某个状态出现」用 tryCompare / tryVerify，等布局用 waitForItemPolished / waitForRendering；
- 确实需要一段时间窗的（确认没发生、让计时器或 Qt.callLater 的下一拍走完）调 tests/qml/TestWaits.js 的
  observe / letElapse，并写明原因。

本门禁机械地拦下 tests/qml 下 .qml / .js 里直接调用的 wait(...)、xxx.wait(...)、qWait(...)，
并要求每个 TestWaits.observe / letElapse 调用的第三个参数是非空字符串字面量。注释与字符串里的文字不算调用。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# 只有 TestWaits.js 自己能调用 TestCase.wait：它是唯一带原因检查的出口。
EXEMPT_FILES = {"TestWaits.js"}
DIRECT_WAIT = re.compile(r"(?<![\w$])(?:wait|qWait)\s*\(|\.\s*wait\s*\(")
HELPER_CALL = re.compile(r"\bTestWaits\s*\.\s*(observe|letElapse)\s*\(")


REGEX_PREV_KEYWORDS = {"return", "throw", "case", "in", "of", "typeof", "void", "delete", "else", "do", "yield", "await", "new"}
STRICT_LITERAL_RE = re.compile(r'^(?:"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\')$')


def _is_regex_start(source: str, slash_idx: int) -> bool:
    """判断 `/` 是否作为 JS 正则字面量起点（而非除法运算符）。"""
    j = slash_idx - 1
    while j >= 0 and source[j] in " \t\r\n":
        j -= 1
    if j < 0:
        return True
    ch = source[j]
    if ch in "(=,:;!?[{&|+-*%^~<>":
        return True
    if ch.isalnum() or ch in "_$":
        k = j
        while k >= 0 and (source[k].isalnum() or source[k] in "_$"):
            k -= 1
        token = source[k + 1:j + 1]
        return token in REGEX_PREV_KEYWORDS
    return False


def strip_comments_and_strings(source: str) -> str:
    """把注释、正则与字符串内容换成空格，保留模板字面量 `${...}` 内的可执行表达式及行号。"""
    out = list(source)
    i, n = 0, len(source)
    # 栈元素：("template", ) 表示当前正在扫描模板插值 `${...}` 内的代码与大括号计数。
    template_brace_stack: list[int] = []

    def scan_template_literal(start_idx: int) -> int:
        # start_idx 指向反引号或插值结束 `}` 之后的下一个模板字符。
        idx = start_idx
        while idx < n:
            ch = source[idx]
            if ch == "\\" and idx + 1 < n:
                if source[idx] != "\n":
                    out[idx] = " "
                if source[idx + 1] != "\n":
                    out[idx + 1] = " "
                idx += 2
            elif ch == "`":
                return idx + 1
            elif ch == "$" and idx + 1 < n and source[idx + 1] == "{":
                # 保留 `${...}` 内部表达式供 wait/qWait 检测；`${` 本身留空或保留不干扰匹配。
                out[idx] = " "
                template_brace_stack.append(1)
                return idx + 2
            else:
                if ch != "\n":
                    out[idx] = " "
                idx += 1
        return n

    while i < n:
        c = source[i]
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
            out[i:j] = " " * (j - i)
            i = j
        elif source.startswith("/*", i):
            j = source.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out[i:j] = [ch if ch == "\n" else " " for ch in source[i:j]]
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and source[j] != c:
                j += 2 if source[j] == "\\" else 1
            j = min(j + 1, n)
            # 引号本身留着，帮助区分「空字符串」与「不是字符串」；内容清空。
            out[i + 1:j - 1] = [ch if ch == "\n" else " " for ch in source[i + 1:j - 1]]
            i = j
        elif c == "`":
            i = scan_template_literal(i + 1)
        elif template_brace_stack and c == "{":
            template_brace_stack[-1] += 1
            i += 1
        elif template_brace_stack and c == "}":
            template_brace_stack[-1] -= 1
            if template_brace_stack[-1] == 0:
                template_brace_stack.pop()
                i = scan_template_literal(i + 1)
            else:
                i += 1
        elif c == "/" and _is_regex_start(source, i):
            j = i + 1
            in_class = False
            while j < n:
                ch = source[j]
                if ch == "\n":
                    break
                if ch == "\\" and j + 1 < n:
                    j += 2
                    continue
                if ch == "[":
                    in_class = True
                elif ch == "]" and in_class:
                    in_class = False
                elif ch == "/" and not in_class:
                    j += 1
                    while j < n and source[j].isalpha():
                        j += 1
                    break
                j += 1
            # 保留前后空白不变成 //，用空格替代正则本体避免干扰后续词法。
            out[i:j] = [ch if ch == "\n" else " " for ch in source[i:j]]
            i = j
        else:
            i += 1
    return "".join(out)


def split_call_args(source: str, open_paren: int) -> list[str] | None:
    """从左括号开始按顶层逗号切分实参；括号不配平时返回 None。source 必须已去掉注释与字符串内容。"""
    depth, start, args = 0, open_paren + 1, []
    for k in range(open_paren, len(source)):
        ch = source[k]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                args.append((start, k))
                return args
        elif ch == "," and depth == 1:
            args.append((start, k))
            start = k + 1
    return None


def _strip_inline_comments(text: str) -> str:
    """移除实参切片周围的 // 与 /* ... */ 注释，保留字符串字面量本身。"""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif c in "\"'`":
            q = c
            out.append(c)
            i += 1
            while i < n:
                ch = text[i]
                out.append(ch)
                if ch == "\\" and i + 1 < n:
                    out.append(text[i + 1])
                    i += 2
                    continue
                i += 1
                if ch == q:
                    break
        else:
            out.append(c)
            i += 1
    return "".join(out).strip()


def check_file(path: Path) -> list[str]:
    raw = path.read_text(encoding="utf-8")
    code = strip_comments_and_strings(raw)
    problems = []

    def line_of(offset: int) -> int:
        return code.count("\n", 0, offset) + 1

    for match in DIRECT_WAIT.finditer(code):
        problems.append(f"{path}:{line_of(match.start())}: 直接调用了固定等待，"
                        "改用 tryCompare / tryVerify，确需时间窗时用 TestWaits.observe / letElapse 并写明原因")
    for match in HELPER_CALL.finditer(code):
        spans = split_call_args(code, match.end() - 1)
        reason = _strip_inline_comments(raw[spans[2][0]:spans[2][1]]) if spans and len(spans) >= 3 else ""
        literal = STRICT_LITERAL_RE.fullmatch(reason)
        if not literal or not reason[1:-1].strip():
            problems.append(f"{path}:{line_of(match.start())}: TestWaits.{match.group(1)} 的第三个参数必须是写明原因的非空单一字符串字面量")
    return problems


def check_tree(root: Path) -> list[str]:
    problems = []
    for path in sorted(list(root.rglob("*.qml")) + list(root.rglob("*.js"))):
        if path.name in EXEMPT_FILES:
            continue
        problems.extend(check_file(path))
    return problems


def main(argv: list[str]) -> int:
    root = Path(argv[1] if len(argv) > 1 else "tests/qml")
    if not root.is_dir():
        print(f"QmlFixedWaitGate：找不到目录 {root}", file=sys.stderr)
        return 2
    candidates = [
        p for p in sorted(list(root.rglob("*.qml")) + list(root.rglob("*.js")))
        if p.name not in EXEMPT_FILES
    ]
    if not candidates:
        print(f"QmlFixedWaitGate：目录 {root} 下未找到任何可检查的 .qml / .js 文件", file=sys.stderr)
        return 2
    problems = check_tree(root)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        print(f"QmlFixedWaitGate：{len(problems)} 处不符合规定，规则见 tests/qml/TestWaits.js 开头的说明", file=sys.stderr)
        return 1
    print("QmlFixedWaitGate：通过")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
