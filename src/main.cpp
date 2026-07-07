#include <QCoreApplication>
#include <QDebug>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QUrl>

#include "services/DatabaseManager.h"
#include "services/AppSettings.h"
#include "services/CategoryManager.h"
#include "services/CountdownService.h"
#include "services/ExportService.h"
#include "services/FocusHistoryService.h"
#include "services/FocusTimer.h"
#include "services/PhaseSoundService.h"
#include "services/RoutineManager.h"
#include "services/StatisticsService.h"
#include "services/TaskManager.h"

int main(int argc, char *argv[])
{
    // 固定运行时控件风格，避免平台原生控件差异影响布局和测试。
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    QGuiApplication app(argc, argv);

    // 打包的数字字体：计时数字（Space Grotesk）与统计/倒计时数字（Bricolage）。
    // 注册失败仅告警、不阻断启动；字族解析不到时 Qt 会回退系统字，数字仍可读。
    const QStringList bundledFonts = {
        QStringLiteral(":/fonts/SpaceGrotesk-Light.ttf"),
        QStringLiteral(":/fonts/SpaceGrotesk-Medium.ttf"),
        QStringLiteral(":/fonts/SpaceGrotesk-Bold.ttf"),
        QStringLiteral(":/fonts/BricolageGrotesque-Bold.ttf"),
    };
    for (const QString& fontPath : bundledFonts) {
        if (QFontDatabase::addApplicationFont(fontPath) == -1) {
            qWarning() << "字体注册失败，将回退系统字:" << fontPath;
        }
    }

    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodo"));
    QCoreApplication::setApplicationName(QStringLiteral("PomodoroTodo"));

    if (!DatabaseManager::instance()->initialize()) {
        return -1;
    }

    // 启动即生成今天的例行任务，保证 QML 首次读取今日任务时已经能看到它们。
    RoutineManager::instance()->materializeToday();

    QQmlApplicationEngine engine;
    // QML 通过单例上下文对象访问服务，视图层保持声明式和轻量。
    engine.rootContext()->setContextProperty(QStringLiteral("categoryManager"), CategoryManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("CategoryManager"), CategoryManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("exportService"), ExportService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("ExportService"), ExportService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("taskManager"), TaskManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("focusTimer"), FocusTimer::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("statisticsService"), StatisticsService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("focusHistoryService"), FocusHistoryService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("countdownService"), CountdownService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("routineManager"), RoutineManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("appSettings"), AppSettings::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("phaseSoundService"), PhaseSoundService::instance());

    const QUrl url(QStringLiteral("qrc:/qml/main.qml"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [url](QObject *object, const QUrl &objectUrl) {
        if (!object && url == objectUrl) {
            QCoreApplication::exit(-1);
        }
    }, Qt::QueuedConnection);

    engine.load(url);
    return app.exec();
}
