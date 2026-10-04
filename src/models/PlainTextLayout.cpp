#include "PlainTextLayout.h"

#include <QQuickTextDocument>
#include <QScopedValueRollback>
#include <memory>
#include <QTextBlock>
#include <QTextBlockFormat>
#include <QTextCursor>
#include <QTextDocument>

void PlainTextLayout::setLineHeight(QQuickTextDocument* wrapper, qreal multiplier)
{
    if (!wrapper || !wrapper->textDocument() || multiplier <= 0) return;
    auto* document = wrapper->textDocument();
    const auto applying = std::make_shared<bool>(false);
    const auto apply = [document, multiplier, applying] {
        // 格式本身也会触发 contentsChanged，必须阻止重入；否则大量换行会逐段递归耗尽栈。
        if (*applying) return;
        QScopedValueRollback<bool> guard(*applying, true);
        QTextCursor cursor(document);
        // 将排版合入上一次文字编辑，避免用户按撤销时只撤销行高而没有撤销文字。
        cursor.joinPreviousEditBlock();
        for (auto block = document->begin(); block.isValid(); block = block.next()) {
            auto format = block.blockFormat();
            if (format.lineHeightType() == QTextBlockFormat::ProportionalHeight
                && qFuzzyCompare(format.lineHeight(), multiplier * 100)) continue;
            format.setLineHeight(multiplier * 100, QTextBlockFormat::ProportionalHeight);
            cursor.setPosition(block.position());
            cursor.setBlockFormat(format);
        }
        cursor.endEditBlock();
    };
    connect(document, &QTextDocument::contentsChanged, document, apply);
    apply();
}
