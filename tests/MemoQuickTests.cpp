#include <QQmlContext>
#include <QQmlEngine>
#include <QtQuickTest/quicktest.h>
#include "../src/models/PlainTextLayout.h"

// 正式页面与离屏用例共用同一个排版实现，截图不使用另写的界面稿。
class MemoTestSetup : public QObject
{
    Q_OBJECT
public slots:
    void qmlEngineAvailable(QQmlEngine* engine)
    {
        engine->rootContext()->setContextProperty(QStringLiteral("memoTextLayout"), new PlainTextLayout(engine));
    }
};
QUICK_TEST_MAIN_WITH_SETUP(memo, MemoTestSetup)
#include "MemoQuickTests.moc"
