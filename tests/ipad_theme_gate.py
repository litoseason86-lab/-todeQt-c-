#!/usr/bin/env python3
# 055-P3A：QML 与原生颜色共用数值；门禁读取两份实际资源，不在测试里再抄一份期望。
import ast
import json
import re
import sys
from pathlib import Path


def theme_values(path):
    source = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))
    expressions = dict(re.findall(
        r"readonly property color (\w+):\s*(.*?)(?=\n\s*(?:readonly )?property|\n\s*function|\n\s*})", source, re.S))
    arrays = dict(re.findall(r"readonly property var (chartColors|heatmapBandColors):\s*(.*?)(?=\n\s*readonly property)", source, re.S))

    def color(expression, dark):
        expression = expression.strip()
        if expression.startswith("darkMode"):
            match = re.fullmatch(r"darkMode\s*\?\s*(.*?)\s*:\s*(.*)", expression, re.S)
            if not match: raise ValueError("不支持的明暗表达式：" + expression)
            return color(match.group(1 if dark else 2), dark)
        if expression.startswith('"#'):
            text = json.loads(expression)
            if len(text) != 7: raise ValueError("不支持的十六进制颜色：" + text)
            return tuple(int(text[i:i+2], 16) / 255 for i in (1, 3, 5)) + (1.0,)
        if expression.startswith("Qt.rgba("):
            def number(text):
                node = ast.parse(text.strip(), mode="eval").body
                def compute(value):
                    if isinstance(value, ast.Constant) and isinstance(value.value, (int, float)): return value.value
                    if isinstance(value, ast.BinOp) and isinstance(value.op, ast.Div): return compute(value.left) / compute(value.right)
                    if isinstance(value, ast.Attribute) and isinstance(value.value, ast.Name) and value.attr in "rgba":
                        return color(expressions[value.value.id], dark)["rgba".index(value.attr)]
                    raise ValueError("不支持的颜色分量：" + text)
                return compute(node)
            return tuple(number(value) for value in expression[8:-1].split(","))
        match = re.fullmatch(r"(\w+)\[(\d+)\]", expression)
        if match:
            array = arrays[match.group(1)]
            parts = re.fullmatch(r"darkMode\s*\?\s*(.*?)\s*:\s*(.*)", array, re.S)
            return color(json.dumps(json.loads(parts.group(1 if dark else 2))[int(match.group(2))]), dark)
        if expression in expressions: return color(expressions[expression], dark)
        raise ValueError("未覆盖的颜色表达式：" + expression)

    result = {name: (color(value, False), color(value, True)) for name, value in expressions.items()}
    for name, value in arrays.items():
        parts = re.fullmatch(r"darkMode\s*\?\s*(.*?)\s*:\s*(.*)", value.strip(), re.S)
        light, dark = json.loads(parts.group(2)), json.loads(parts.group(1))
        for i in range(len(light)):
            result[name + str(i)] = (color(json.dumps(light[i]), False), color(json.dumps(dark[i]), True))
    return result


def strip_swift_comments(source: str) -> str:
    """移除 Swift 行注释与支持嵌套的块注释，保留或清空字符串字面量内容避免 URL 里的 // 吞掉同行后续代码。"""
    out = []
    i, n = 0, len(source)
    while i < n:
        if source.startswith("//", i):
            i += 2
            while i < n and source[i] != "\n":
                i += 1
        elif source.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth > 0:
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    if source[i] == "\n":
                        out.append("\n")
                    i += 1
        elif source.startswith('"""', i):
            out.append('""')
            i += 3
            while i < n and not source.startswith('"""', i):
                if source[i] == "\\" and i + 1 < n:
                    if source[i + 1] == "\n":
                        out.append("\n")
                    i += 2
                    continue
                if source[i] == "\n":
                    out.append("\n")
                i += 1
            i = min(n, i + 3)
        elif source[i] == '"':
            out.append('""')
            i += 1
            while i < n and source[i] != '"':
                if source[i] == "\\" and i + 1 < n:
                    i += 2
                    continue
                if source[i] == "\n":
                    out.append("\n")
                    break
                i += 1
            i = min(n, i + 1)
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


FORBIDDEN_SWIFT_COLOR_RE = re.compile(
    r"(?:\b(?:Color|UIColor)\.(?:white|black)\b"
    r"|\b(?:Color|UIColor)\(\s*white\s*:"
    r"|\.(?:foregroundColor|foregroundStyle|background|tint|fill|stroke)\(\s*\.(?:white|black)\b)"
)


def check_hardcoded_swift_colors(paths: list[Path]) -> list[str]:
    """检查 IPadUI SwiftUI 视图里不得直接写死 Color.white / Color.black 等纯色。"""
    violations: list[str] = []
    for path in paths:
        clean = strip_swift_comments(path.read_text(encoding="utf-8"))
        for match in FORBIDDEN_SWIFT_COLOR_RE.finditer(clean):
            line = clean[: match.start()].count("\n") + 1
            violations.append(f"{path}:{line}: 禁止在 iPad 视图中硬编码颜色 `{match.group(0)}`，请使用 ThemeColors 语义令牌")
    return violations


def main():
    root = Path(__file__).resolve().parent.parent
    values = theme_values(root / "qml/Theme.qml")
    theme_source = (root / "qml/Theme.qml").read_text(encoding="utf-8")
    definitions = {
        match[0]: (match[1], match[2], match[3])
        for match in re.findall(r'id:\s*"([^\"]+)",\s*name:\s*"([^\"]+)",\s*mode:\s*"([^\"]+)".*?base:\s*"([^\"]+)"', theme_source, re.S)
    }
    theme_bases = {}
    for name, (_, _, base) in definitions.items():
        channels = tuple(int(base[i:i+2], 16) / 255 for i in (1, 3, 5)) + (1.0,)
        theme_bases["themeBase_" + name] = (channels, channels)
    resource_values = values | theme_bases
    catalog = root / "src/ui/ipad/Sources/IPadUI/Resources/Colors.xcassets"
    if "--write" in sys.argv:
        catalog.mkdir(parents=True, exist_ok=True)
        (catalog / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
        for name, appearances in resource_values.items():
            directory = catalog / (name + ".colorset")
            directory.mkdir(exist_ok=True)
            colors = []
            for i, channels in enumerate(appearances):
                entry = {"idiom": "universal", "color": {"color-space": "srgb", "components": dict(zip(["red", "green", "blue", "alpha"], [f"{value:.9f}" for value in channels]))}}
                if i == 1: entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
                colors.append(entry)
            (directory / "Contents.json").write_text(json.dumps({"colors": colors, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
        return
    actual_names = {p.stem for p in catalog.glob("*.colorset")}
    if actual_names != set(resource_values): raise ValueError("颜色资源集合与 Theme.qml 不一致")
    for name, expected in resource_values.items():
        entries = json.loads((catalog / (name + ".colorset") / "Contents.json").read_text(encoding="utf-8"))["colors"]
        if len(entries) != 2: raise ValueError(name + " 必须提供浅深两套")
        actual = {}
        for entry in entries:
            mode = bool(entry.get("appearances"))
            components = entry["color"]["components"]
            actual[mode] = tuple(float(components[k]) for k in ["red", "green", "blue", "alpha"])
        for dark in (False, True):
            if dark not in actual or any(abs(a - b) > 1e-6 for a, b in zip(actual[dark], expected[dark])):
                raise ValueError(f"{name} 的{'深' if dark else '浅'}色值偏离 Theme.qml")
    swift = (root / "src/ui/ipad/Sources/IPadUI/Theme/ThemeColors.swift").read_text(encoding="utf-8")
    references = set(re.findall(r'(?:Color|semantic)\("(\w+)"', swift))
    references.discard("themeBase_")  # 动态资源前缀，七份具体 base 已由资源逐个核对。
    if references != set(values): raise ValueError("Swift 颜色入口与资源集合不一致")
    theme_ids = set(definitions)
    bridge_source = (root / "src/platform/ios/bridge/PTShellBridge.mm").read_text(encoding="utf-8")
    bridge_blocks = re.findall(r'const\s+QStringList\s+themes\s*=\s*\{([^}]*)\}', bridge_source, re.S)
    if not bridge_blocks:
        raise ValueError("未找到 PTShellBridge 的壁纸资源白名单")
    # 所有桥接壁纸白名单块均受门禁约束，避免后续新增入口漂移。
    for block in bridge_blocks:
        ids = set(re.findall(r'QStringLiteral\("([^\"]+)"\)', block))
        if ids != theme_ids:
            raise ValueError("PTShellBridge 壁纸白名单与 Theme.qml 不一致")
    settings_source = (root / "src/ui/ipad/Sources/IPadCore/Stores/SettingsAvailability.swift").read_text(encoding="utf-8")
    choices = {
        match[0]: (match[1], match[2], match[3])
        for match in re.findall(r'Theme\(id: "([^\"]+)", title: "([^\"]+)", mode: "([^\"]+)", base: "([^\"]+)"\)', settings_source)
    }
    if choices != definitions: raise ValueError("设置主题的名单、文案、明暗或 base 色与 Theme.qml 不一致")
    swift_views = sorted((root / "src/ui/ipad/Sources/IPadUI").rglob("*.swift"))
    swift_violations = check_hardcoded_swift_colors(swift_views)
    if swift_violations:
        raise ValueError("\n".join(swift_violations))
    print(f"iPad 颜色门禁通过：{len(values)} 个语义令牌，浅深两套；七主题文案、明暗、base 与壁纸名单同源核对通过，Swift 视图零硬编码纯色")


if __name__ == "__main__":
    try: main()
    except (ValueError, KeyError, OSError) as error:
        print("iPad 颜色门禁失败：" + str(error), file=sys.stderr)
        sys.exit(1)
