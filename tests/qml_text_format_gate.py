#!/usr/bin/env python3
"""每个非字面量的 text 绑定都必须显式声明 textFormat。

起因：Qt 的 Text.textFormat 默认是 AutoText，它用 mightBeRichText() 猜——
一个标题写成 "<b>x</b>" 就会被当作富文本解析（实测 AutoText 的 contentWidth
与 RichText 一致、与 PlainText 不同）。任务标题、科目名、倒计时名称这些字段
的内容完全由用户提供，还能通过恢复备份绕过输入端约束。

判据刻意不做「这是不是用户数据」的判断——那种判断我们已经错过一次：
上一轮按"数一数文件里有几个 textFormat"就下了"都是 PlainText"的结论，
漏掉了任务标题本身。现在规则是机械的：text 不是纯字面量，就必须写明格式。
"""
import re
import sys
from pathlib import Path

LITERAL = re.compile(r'text:\s*(qsTr\()?"[^"]*"\)?\s*$')


def blocks(src, typ):
    for m in re.finditer(r'\b' + typ + r'\s*\{', src):
        i = src.index('{', m.start())
        depth = 0
        j = i
        while j < len(src):
            if src[j] == '{':
                depth += 1
            elif src[j] == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        yield src[:m.start()].count('\n') + 1, src[i:j + 1]


def direct_props(block):
    props, depth = [], 0
    for line in block.split('\n'):
        if depth == 1 and re.match(r'\s*[a-zA-Z_][\w.]*\s*:', line):
            props.append(line.strip())
        depth += line.count('{') - line.count('}')
    return props


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else 'qml')
    offenders = []
    for path in sorted(root.rglob('*.qml')):
        src = path.read_text()
        for typ in ('Text', 'Label'):
            for line, block in blocks(src, typ):
                props = direct_props(block)
                text = next((p for p in props if p.startswith('text:')), None)
                if text is None or LITERAL.match(text):
                    continue
                if any(p.startswith('textFormat:') for p in props):
                    continue
                offenders.append((path, line, text[:70]))

    if offenders:
        print('以下 text 绑定没有显式 textFormat，会落到 AutoText 富文本解析：')
        for path, line, text in offenders:
            print(f'  {path}:{line}  {text}')
        print(f'\n共 {len(offenders)} 处。用户可控的文本一律要 Text.PlainText；')
        print('确实需要标记语言的，显式写 Text.StyledText 并说明原因。')
        return 1
    print('OK: 所有非字面量 text 绑定都显式声明了 textFormat')
    return 0


if __name__ == '__main__':
    sys.exit(main())
