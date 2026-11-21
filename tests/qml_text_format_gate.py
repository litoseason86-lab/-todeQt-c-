#!/usr/bin/env python3
"""每个非字面量的 text 绑定与命令式赋值都必须显式声明非 AutoText 的 textFormat。

起因：Qt 的 Text.textFormat 默认是 AutoText，它用 mightBeRichText() 猜——
一个标题写成 "<b>x</b>" 就会被当作富文本解析（实测 AutoText 的 contentWidth
与 RichText 一致、与 PlainText 不同）。任务标题、科目名、倒计时名称这些字段
的内容完全由用户提供，还能通过恢复备份绕过输入端约束。

加固后的检查覆盖：单行 Text/Label、同行分号多属性、显式 textFormat: Text.AutoText、
内联 component 派生子类，以及对 Text/Label id 执行的非字面量命令式 `.text = ...` 赋值。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

_SINGLE_OR_DOUBLE_STR = r'(?:"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\')'
LITERAL = re.compile(
    rf'^(?:qsTr\s*\(\s*{_SINGLE_OR_DOUBLE_STR}\s*\)|{_SINGLE_OR_DOUBLE_STR})\s*$'
)
DIRECT_PROP_RE = re.compile(r'^([a-zA-Z_][\w.]*)\s*:\s*(.+)$', re.S)
ALLOWED_TEXT_FORMATS = frozenset({
    'Text.PlainText',
    'Text.StyledText',
    'Label.PlainText',
    'Label.StyledText',
    'TextEdit.PlainText',
})


def strip_comments(src: str) -> str:
    """保留引号内字面量与换行行号，移除 // 与 /* ... */ 注释，防止注释里的花括号破坏块边界。"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            i += 2
            while i < n and src[i] != '\n':
                i += 1
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                if src[i] == '\n':
                    out.append('\n')
                i += 1
            i += 2
        elif c in ('"', "'"):
            q = c
            out.append(c)
            i += 1
            while i < n:
                ch = src[i]
                out.append(ch)
                if ch == '\\' and i + 1 < n:
                    out.append(src[i + 1])
                    i += 2
                    continue
                i += 1
                if ch == q:
                    break
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def find_matching_brace(src: str, open_idx: int) -> int:
    """跳过字符串字面量，找到与 open_idx 处 `{` 配对的 `}` 索引。"""
    depth = 0
    i, n = open_idx, len(src)
    while i < n:
        c = src[i]
        if c in ('"', "'"):
            q = c
            i += 1
            while i < n:
                if src[i] == '\\' and i + 1 < n:
                    i += 2
                    continue
                ch = src[i]
                i += 1
                if ch == q:
                    break
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n - 1


def split_top_level_statements(block_inner: str) -> list[str]:
    """切分对象块第一层级的属性声明（支持单行分号与跨行绑定，跳过子对象与绑定内花括号）。"""
    stmts: list[str] = []
    buf: list[str] = []
    brace_depth = 0
    paren_depth = 0
    i, n = 0, len(block_inner)
    while i < n:
        c = block_inner[i]
        if c in ('"', "'"):
            q = c
            buf.append(c)
            i += 1
            while i < n:
                ch = block_inner[i]
                buf.append(ch)
                if ch == '\\' and i + 1 < n:
                    buf.append(block_inner[i + 1])
                    i += 2
                    continue
                i += 1
                if ch == q:
                    break
            continue
        if c == '(':
            paren_depth += 1
            buf.append(c)
        elif c == ')':
            paren_depth = max(0, paren_depth - 1)
            buf.append(c)
        elif c == '{':
            brace_depth += 1
            buf.append(c)
        elif c == '}':
            brace_depth = max(0, brace_depth - 1)
            buf.append(c)
            if brace_depth == 0 and paren_depth == 0:
                stmt = ''.join(buf).strip()
                if stmt:
                    stmts.append(stmt)
                buf.clear()
        elif brace_depth == 0 and paren_depth == 0 and c in (';', '\n'):
            # 判断换行是否为表达式续行（当前行末尾为运算符，或下一非空行以 . / ? / : / 运算符开头）。
            if c == ';':
                stmt = ''.join(buf).strip()
                if stmt:
                    stmts.append(stmt)
                buf.clear()
            else:
                so_far = ''.join(buf).rstrip()
                j = i + 1
                while j < n and block_inner[j] in ' \t':
                    j += 1
                next_char = block_inner[j] if j < n else ''
                cont_prev = so_far.endswith(('+', '-', '*', '/', '?', ':', ',', '&&', '||', '(', '['))
                cont_next = next_char in ('.', '?', ':', '+', '-', ')', ']')
                if cont_prev or cont_next:
                    buf.append(' ')
                else:
                    stmt = ''.join(buf).strip()
                    if stmt:
                        stmts.append(stmt)
                    buf.clear()
        else:
            buf.append(c)
        i += 1
    tail = ''.join(buf).strip()
    if tail:
        stmts.append(tail)
    return stmts


def direct_props(block_with_braces: str) -> dict[str, str]:
    inner = block_with_braces[1:-1]
    props: dict[str, str] = {}
    for stmt in split_top_level_statements(inner):
        if stmt.startswith(('property ', 'signal ', 'function ', 'readonly ', 'default ', 'required ', 'Behavior ')):
            continue
        # 跳过子 QML 对象块，如 Rectangle { ... }（但保留 property: { ... } 块绑定）。
        m = DIRECT_PROP_RE.match(stmt)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if re.match(r'^[A-Z]\w*$', key):
            continue
        props[key] = val
    return props


def is_valid_text_format(val: str | None) -> bool:
    if not val:
        return False
    return val.strip() in ALLOWED_TEXT_FORMATS


def check_source(path: Path, raw_src: str) -> list[tuple[Path, int, str]]:
    src = strip_comments(raw_src)
    offenders: list[tuple[Path, int, str]] = []

    # 1. 收集内联 component 派生体系（含多级派生）与基类自带的 textFormat。
    inline_bases: dict[str, str] = {}
    inline_has_format: dict[str, bool] = {}

    comp_re = re.compile(r'\bcomponent\s+([A-Z]\w*)\s*:\s*([A-Z]\w*)\s*\{')
    for m in comp_re.finditer(src):
        name, base = m.group(1), m.group(2)
        open_idx = m.end() - 1
        close_idx = find_matching_brace(src, open_idx)
        inline_bases[name] = base
        props = direct_props(src[open_idx:close_idx + 1])
        tf = props.get('textFormat')
        inline_has_format[name] = is_valid_text_format(tf)

    def resolves_to_text_type(typ: str) -> bool:
        seen = set()
        cur = typ
        while cur and cur not in seen:
            if cur in ('Text', 'Label'):
                return True
            seen.add(cur)
            cur = inline_bases.get(cur, '')
        return False

    def inherited_has_format(typ: str) -> bool:
        seen = set()
        cur = typ
        while cur and cur not in seen:
            if inline_has_format.get(cur):
                return True
            seen.add(cur)
            cur = inline_bases.get(cur, '')
        return False

    text_types = {'Text', 'Label'} | {n for n in inline_bases if resolves_to_text_type(n)}
    type_pattern = re.compile(r'\b(' + '|'.join(sorted(map(re.escape, text_types), key=len, reverse=True)) + r')\s*\{')

    # 记录不带有效 textFormat 的 Text/Label id，供后续命令式赋值检查。
    unformatted_ids: dict[str, int] = {}

    for m in type_pattern.finditer(src):
        typ = m.group(1)
        open_idx = m.end() - 1
        close_idx = find_matching_brace(src, open_idx)
        line = src[:m.start()].count('\n') + 1
        props = direct_props(src[open_idx:close_idx + 1])
        tf = props.get('textFormat')

        if tf is not None and not is_valid_text_format(tf):
            offenders.append((path, line, f'textFormat: {tf[:60]}'))
            continue

        has_fmt = is_valid_text_format(tf) or inherited_has_format(typ)
        if 'text' in props and not LITERAL.match(props['text']) and not has_fmt:
            offenders.append((path, line, f'text: {props["text"][:65]}'))
            continue

        obj_id = props.get('id')
        if obj_id and re.fullmatch(r'[A-Za-z_]\w*', obj_id) and not has_fmt:
            unformatted_ids[obj_id] = line

    # 2. 检查对未声明 textFormat 的 Text/Label id 执行的非字面量命令式 `.text = ...` / `.text += ...` 赋值。
    if unformatted_ids:
        id_pat = '|'.join(sorted(map(re.escape, unformatted_ids), key=len, reverse=True))
        assign_re = re.compile(r'\b(' + id_pat + r')\.text\s*(\+?=)\s*([^\n;}]+)')
        for m in assign_re.finditer(src):
            op, rhs = m.group(2), m.group(3).strip()
            if op == '+=' or not LITERAL.match(rhs):
                line = src[:m.start()].count('\n') + 1
                offenders.append((path, line, f'{m.group(1)}.text {op} {rhs[:60]}'))

    return offenders


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else 'qml')
    if not root.is_dir():
        print(f'QmlTextFormatGate：找不到目录 {root}', file=sys.stderr)
        return 2
    qml_files = sorted(root.rglob('*.qml'))
    if not qml_files:
        print(f'QmlTextFormatGate：目录 {root} 下未找到任何 .qml 文件', file=sys.stderr)
        return 2
    offenders = []
    for path in qml_files:
        offenders.extend(check_source(path, path.read_text(encoding='utf-8')))

    if offenders:
        print('以下 text 绑定或命令式赋值未显式声明合法的 textFormat，会落到 AutoText 富文本解析：')
        for path, line, text in offenders:
            print(f'  {path}:{line}  {text}')
        print(f'\n共 {len(offenders)} 处。用户可控的文本一律要 Text.PlainText；')
        print('确实需要标记语言的，显式写 Text.StyledText 并说明原因。')
        return 1
    print('OK: 所有非字面量 text 绑定都显式声明了 textFormat')
    return 0


if __name__ == '__main__':
    sys.exit(main())
