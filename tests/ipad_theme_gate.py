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


def main():
    root = Path(__file__).resolve().parent.parent
    values = theme_values(root / "qml/Theme.qml")
    catalog = root / "src/ui/ipad/Sources/IPadUI/Resources/Colors.xcassets"
    if "--write" in sys.argv:
        catalog.mkdir(parents=True, exist_ok=True)
        (catalog / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
        for name, appearances in values.items():
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
    if actual_names != set(values): raise ValueError("颜色资源集合与 Theme.qml 不一致")
    for name, expected in values.items():
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
    references = set(re.findall(r'Color\("(\w+)"', swift))
    if references != set(values): raise ValueError("Swift 颜色入口与资源集合不一致")
    theme_source = (root / "qml/Theme.qml").read_text(encoding="utf-8")
    theme_ids = set(re.findall(r'\bid:\s*"([^"]+)"', theme_source))
    theme_blocks = re.findall(r'\{\s*id:.*?\n\s*\}', theme_source, re.S)
    dark_theme_ids = {
        match.group(1)
        for block in theme_blocks
        if 'mode: "dark"' in block
        for match in [re.search(r'id:\s*"([^"]+)"', block)]
        if match
    }
    shell_source = (root / "src/ui/ipad/Sources/IPadUI/Shell/ShellRootView.swift").read_text(encoding="utf-8")
    dark_match = re.search(r'\[([^\]]*)\]\.contains\(store\.snapshot\.backgroundTheme\)', shell_source)
    if not dark_match: raise ValueError("未找到 ShellRootView 的壁纸深色名单")
    dark_ids = set(re.findall(r'"([^"]+)"', dark_match.group(1)))
    bridge_source = (root / "src/platform/ios/bridge/PTShellBridge.mm").read_text(encoding="utf-8")
    bridge_match = re.search(r'const\s+QStringList\s+themes\s*=\s*\{([^}]*)\}', bridge_source, re.S)
    if not bridge_match: raise ValueError("未找到 PTShellBridge 的壁纸资源白名单")
    bridge_ids = set(re.findall(r'QStringLiteral\("([^"]+)"\)', bridge_match.group(1)))
    if not dark_ids.issubset(theme_ids): raise ValueError("ShellRootView 深色壁纸名单包含 Theme.qml 未定义的主题")
    if not bridge_ids.issubset(theme_ids): raise ValueError("PTShellBridge 壁纸白名单包含 Theme.qml 未定义的主题")
    if dark_ids != dark_theme_ids:
        raise ValueError("ShellRootView 深色壁纸名单与 Theme.qml 不一致")
    if bridge_ids != theme_ids:
        raise ValueError("PTShellBridge 壁纸白名单与 Theme.qml 不一致")
    settings_source = (root / "src/ui/ipad/Sources/IPadCore/Stores/SettingsAvailability.swift").read_text(encoding="utf-8")
    choices = set(re.findall(r'\("([^"]+)",\s*"[^"]+"\)', settings_source))
    if choices != theme_ids: raise ValueError("设置外观主题选项与 Theme.qml 不一致")
    print(f"iPad 颜色门禁通过：{len(values)} 个语义令牌，浅深两套；壁纸名单与 Theme.qml 同源核对通过")


if __name__ == "__main__":
    try: main()
    except (ValueError, KeyError, OSError) as error:
        print("iPad 颜色门禁失败：" + str(error), file=sys.stderr)
        sys.exit(1)
