#!/usr/bin/env python3
"""悬停过渡门禁：带 `Behavior on color` 的对象，状态色分支不得回落到黑基透明。

Qt 的 `"transparent"` 与 `Qt.rgba(0, 0, 0, 0)` 都是**黑基**透明（rgb 全 0，alpha 0）。
ColorAnimation 从它插值到悬停色时，中间帧的 rgb 会停在灰色区间，界面上就是
「鼠标刚放上去，按钮下面闪过一道阴影」——2026-09-10 在今日专注页实测到。

写死白基（`Qt.rgba(1, 1, 1, 0)`）只是把浅色主题的问题挪到夜间主题。正确做法是
与悬停色同色、alpha 为 0，见 `Theme.glassHoverIdle`。

没有颜色过渡动画的静态 `color: "transparent"` 不在管辖范围内：不插值就没有中间帧。
"""

import pathlib
import re
import sys

BLACK_BASED = re.compile(r'"transparent"|Qt\.rgba\(\s*0\s*,\s*0\s*,\s*0\s*,\s*0\s*\)')
STATEFUL = re.compile(r"\bhovered\b|\bdown\b|\bpressed\b|containsMouse")
COMMENT = re.compile(r"//.*$")


def strip_noise(line: str) -> str:
    return COMMENT.sub("", line)


COLOR_BINDING = re.compile(r"^\s*color\s*:")
NEXT_BINDING = re.compile(r"^\s*(?:[\w.]+\s*:|[A-Z]\w*\s*\{|\}|//)")


def color_expression(lines: list[str]) -> str:
    """取出本对象自己的 `color:` 绑定文本（可能跨多行）。

    只看 `color:`，不看 `border.color:` 之类——`Behavior on color` 只作用于前者，
    后者用黑基透明不会产生插值，误报会让门禁失去意义。
    """
    collected: list[str] = []
    collecting = False
    for raw in lines:
        line = strip_noise(raw)
        if collecting:
            if NEXT_BINDING.match(line):
                collecting = False
            else:
                collected.append(line)
                continue
        if COLOR_BINDING.match(line):
            collecting = True
            collected.append(line)
    return "\n".join(collected)


def check_file(path: pathlib.Path) -> list[str]:
    problems: list[str] = []
    stack: list[dict] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = strip_noise(raw)
        if stack:
            stack[-1]["lines"].append(raw)
        for _ in range(line.count("{")):
            stack.append({"start": number, "lines": []})
        for _ in range(line.count("}")):
            if not stack:
                continue
            block = stack.pop()
            text = "\n".join(block["lines"])
            if "Behavior on color" not in text:
                continue
            expression = color_expression(block["lines"])
            if BLACK_BASED.search(expression) and STATEFUL.search(text):
                problems.append(
                    f"{path}:{block['start']}: 带颜色过渡的状态色回落到黑基透明，"
                    f"悬停时会插值出灰影；改用同色零透明（见 Theme.glassHoverIdle）")
    return problems


def main(argv: list[str]) -> int:
    roots = [pathlib.Path(a) for a in argv[1:]] or [pathlib.Path("qml")]
    problems: list[str] = []
    scanned = 0
    for root in roots:
        for path in sorted(root.rglob("*.qml")):
            scanned += 1
            problems.extend(check_file(path))
    if problems:
        print("\n".join(problems))
        print(f"\n共 {len(problems)} 处；已扫描 {scanned} 个 QML 文件。")
        return 1
    print(f"悬停过渡门禁通过：{scanned} 个 QML 文件。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
