#!/usr/bin/env python3
"""悬停过渡门禁：带 `Behavior on color` 的对象，状态色分支不得回落到黑基透明。

Qt 的 `"transparent"`、`'transparent'`、`"#00000000"`、`"#0000"` 与 `Qt.rgba(0, 0, 0, 0)`
都是黑基透明（rgb 全 0，alpha 0）。ColorAnimation 从它插值到悬停色时，中间帧会泛灰影。
"""

import pathlib
import re
import sys

BLACK_BASED = re.compile(
    r'''(?:"transparent"|'transparent'|["']#0{4}(?:0{4})?["']|Qt\.rgba\(\s*(?:0+(?:\.0*)?|\.0+)\s*,\s*(?:0+(?:\.0*)?|\.0+)\s*,\s*(?:0+(?:\.0*)?|\.0+)\s*,\s*(?:0+(?:\.0*)?|\.0+)\s*\))''',
    re.IGNORECASE,
)
# 白基透明（rgb 全 1，alpha 0）在深色主题或与 Theme.glassHover 插值时同样会产生发白闪影。
WHITE_BASED = re.compile(
    r'''(?:["']#00f{6}["']|["']#0f{3}["']|Qt\.rgba\(\s*(?:1(?:\.0*)?|255(?:\.0*)?)\s*,\s*(?:1(?:\.0*)?|255(?:\.0*)?)\s*,\s*(?:1(?:\.0*)?|255(?:\.0*)?)\s*,\s*(?:0+(?:\.0*)?|\.0+)\s*\))''',
    re.IGNORECASE,
)
STATEFUL = re.compile(r"\bhovered\b|\bdown\b|\bpressed\b|containsMouse")


def strip_comments(source: str) -> str:
    """去掉 QML 注释但保留字符串与代码字符布局。"""
    out = []
    i, n = 0, len(source)
    while i < n:
        c = source[i]
        if c == "/" and i + 1 < n and source[i + 1] == "/":
            i += 2
            while i < n and source[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and source[i + 1] == "*":
            i += 2
            while i + 1 < n and not (source[i] == "*" and source[i + 1] == "/"):
                if source[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        elif c in ('"', "'"):
            q = c
            out.append(c)
            i += 1
            while i < n:
                ch = source[i]
                out.append(ch)
                if ch == "\\" and i + 1 < n:
                    out.append(source[i + 1])
                    i += 2
                    continue
                i += 1
                if ch == q:
                    break
        else:
            out.append(c)
            i += 1
    return "".join(out)


def find_matching_brace(src: str, open_idx: int) -> int:
    depth = 0
    i, n = open_idx, len(src)
    while i < n:
        c = src[i]
        if c in ('"', "'"):
            q = c
            i += 1
            while i < n:
                if src[i] == "\\" and i + 1 < n:
                    i += 2
                    continue
                ch = src[i]
                i += 1
                if ch == q:
                    break
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n - 1


def prop_expressions(block_inner: str, prop_name: str) -> str:
    """提取对象块第一层级的 `<prop_name>:` 绑定文本（同时支持同行分号、多行三目与 `{ ... }` 块表达式）。"""
    collected: list[str] = []
    i, n = 0, len(block_inner)
    depth = 0
    stmt_start = True
    prop_re = re.compile(rf"{re.escape(prop_name)}\s*:")
    while i < n:
        c = block_inner[i]
        if c in ('"', "'", "`"):
            q = c
            i += 1
            while i < n:
                if block_inner[i] == "\\" and i + 1 < n:
                    i += 2
                    continue
                ch = block_inner[i]
                i += 1
                if ch == q:
                    break
            stmt_start = False
            continue
        if depth == 0 and stmt_start and prop_re.match(block_inner[i:]):
            start = i
            j = block_inner.index(":", i) + 1
            while j < n and block_inner[j] in " \t":
                j += 1
            if j < n and block_inner[j] == "{":
                end = find_matching_brace(block_inner, j) + 1
            else:
                # 常规表达式一直读到下一个同层属性绑定 / 子对象声明 / 分号 / 行尾非续行处
                pdepth = 0
                end = j
                while end < n:
                    ch = block_inner[end]
                    if ch in ('"', "'", "`"):
                        q = ch
                        end += 1
                        while end < n:
                            if block_inner[end] == "\\" and end + 1 < n:
                                end += 2
                                continue
                            c2 = block_inner[end]
                            end += 1
                            if c2 == q:
                                break
                        continue
                    if ch == "(":
                        pdepth += 1
                    elif ch == ")":
                        pdepth = max(0, pdepth - 1)
                    elif ch == "\n" and pdepth == 0:
                        k = end + 1
                        while k < n and block_inner[k] in " \t":
                            k += 1
                        if k >= n or block_inner[k] == "}" or re.match(r"(?:[\w.]+\s*:|[A-Z]\w*\s*\{)", block_inner[k:]):
                            break
                    elif ch == ";" and pdepth == 0:
                        break
                    end += 1
            collected.append(block_inner[start:end])
            i = end
            stmt_start = False
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth = max(0, depth - 1)
        stmt_start = c in "\n;" or (stmt_start and c in " \t")
        i += 1
    return "\n".join(collected)


def has_direct_behavior_on_prop(block_inner: str, prop_name: str) -> bool:
    """只在对象自身顶层查找 `Behavior on <prop_name>`，避免外层容器误继承子按钮的行为。"""
    i, n = 0, len(block_inner)
    depth = 0
    pat = re.compile(rf"Behavior\s+on\s+{re.escape(prop_name)}\b")
    while i < n:
        c = block_inner[i]
        if c in ('"', "'", "`"):
            q = c
            i += 1
            while i < n:
                if block_inner[i] == "\\" and i + 1 < n:
                    i += 2
                    continue
                ch = block_inner[i]
                i += 1
                if ch == q:
                    break
            continue
        if depth == 0 and block_inner.startswith("Behavior", i) and pat.match(block_inner[i:]):
            return True
        if c == "{":
            depth += 1
        elif c == "}":
            depth = max(0, depth - 1)
        i += 1
    return False


def check_file(path: pathlib.Path) -> list[str]:
    problems: list[str] = []
    clean = strip_comments(path.read_text(encoding="utf-8"))
    for m in re.finditer(r"\b[A-Z]\w*(?:\.[A-Z]\w*)?\s*\{", clean):
        open_idx = m.end() - 1
        close_idx = find_matching_brace(clean, open_idx)
        block_inner = clean[open_idx + 1:close_idx]
        for prop_name in ("color", "border.color"):
            if not has_direct_behavior_on_prop(block_inner, prop_name):
                continue
            expr = prop_expressions(block_inner, prop_name)
            if STATEFUL.search(expr):
                if BLACK_BASED.search(expr):
                    line_no = clean[:m.start()].count("\n") + 1
                    problems.append(
                        f"{path}:{line_no}: 带颜色过渡的状态色（{prop_name}）回落到黑基透明，"
                        f"悬停时会插值出灰影；改用同色零透明（见 Theme.glassHoverIdle）"
                    )
                elif WHITE_BASED.search(expr):
                    line_no = clean[:m.start()].count("\n") + 1
                    problems.append(
                        f"{path}:{line_no}: 带颜色过渡的状态色（{prop_name}）回落到白基透明，"
                        f"深色模式下悬停会插值出发白闪影；改用同色零透明（见 Theme.glassHoverIdle）"
                    )
    return problems


def main(argv: list[str]) -> int:
    roots = [pathlib.Path(a) for a in argv[1:]] or [pathlib.Path("qml")]
    problems: list[str] = []
    scanned = 0
    for root in roots:
        if not root.is_dir():
            print(f"QmlHoverTransitionGate：找不到目录 {root}", file=sys.stderr)
            return 2
        for path in sorted(root.rglob("*.qml")):
            scanned += 1
            problems.extend(check_file(path))
    if scanned == 0:
        print("QmlHoverTransitionGate：未扫描到任何 .qml 文件", file=sys.stderr)
        return 2
    if problems:
        print("\n".join(problems))
        print(f"\n共 {len(problems)} 处；已扫描 {scanned} 个 QML 文件。")
        return 1
    print(f"悬停过渡门禁通过：{scanned} 个 QML 文件。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
