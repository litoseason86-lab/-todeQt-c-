#pragma once

#include <QObject>

class QQuickTextDocument;

// 只负责纯文本的段落排版，不读取或保存业务内容。
class PlainTextLayout : public QObject
{
    Q_OBJECT
public:
    using QObject::QObject;
    Q_INVOKABLE void setLineHeight(QQuickTextDocument* document, qreal multiplier);
};
