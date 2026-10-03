#include <QCoreApplication>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QInputMethodEvent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QtQuickTest/quicktest.h>
#include "../src/models/PlainTextLayout.h"

// 模拟平台输入法。iPad 软键盘打的每个字、Mac 拼音选字后上屏的中文，都以 QInputMethodEvent
// 送到焦点对象，而不是按键事件；QML 测试只能发按键，发不了这类事件，所以从 C++ 补一个入口。
// 两个方法都只发给当前焦点对象（和平台插件一致），焦点不在预期的输入框上时返回 false，
// 让用例先确认「事件确实送到了要测的那个框」这个前置条件。
class InputMethodProbe : public QObject
{
    Q_OBJECT
public:
    using QObject::QObject;

    // 上屏一段文字：相当于在候选里选定了字。
    Q_INVOKABLE bool commit(QObject* expected, const QString& text)
    {
        QInputMethodEvent event;
        event.setCommitString(text);
        return sendToFocus(expected, &event);
    }

    // 只更新正在组合的预编辑串（例如还没选字的拼音），不上屏任何文字。
    Q_INVOKABLE bool compose(QObject* expected, const QString& preedit)
    {
        QInputMethodEvent event(preedit, {});
        return sendToFocus(expected, &event);
    }

private:
    static bool sendToFocus(QObject* expected, QInputMethodEvent* event)
    {
        QObject* focus = QGuiApplication::focusObject();
        if (!expected || focus != expected)
            return false;
        QCoreApplication::sendEvent(focus, event);
        return true;
    }
};

// 正式页面与离屏用例共用同一个排版实现，截图不使用另写的界面稿。
class MemoTestSetup : public QObject
{
    Q_OBJECT
public slots:
    void qmlEngineAvailable(QQmlEngine* engine)
    {
        // 用真机同款的系统界面字体排版。Qt Quick Test 默认的字族在这台机器上找不到，会回退成字宽全是整数的字体，
        // 测不出「字宽带小数、版面取整后被省略」这类只在真机出现的问题（组头「数学」曾显示成「数…」）。
        QGuiApplication::setFont(QFontDatabase::systemFont(QFontDatabase::GeneralFont));
        engine->rootContext()->setContextProperty(QStringLiteral("memoTextLayout"), new PlainTextLayout(engine));
        engine->rootContext()->setContextProperty(QStringLiteral("inputMethodProbe"), new InputMethodProbe(engine));
    }
};
QUICK_TEST_MAIN_WITH_SETUP(memo, MemoTestSetup)
#include "MemoQuickTests.moc"
