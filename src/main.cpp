#include <QCoreApplication>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QUrl>

#include "services/DatabaseManager.h"
#include "services/CategoryManager.h"
#include "services/CountdownService.h"
#include "services/ExportService.h"
#include "services/FocusTimer.h"
#include "services/StatisticsService.h"
#include "services/TaskManager.h"

int main(int argc, char *argv[])
{
    // 固定运行时控件风格，避免平台原生控件差异影响布局和测试。
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    QGuiApplication app(argc, argv);

    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodo"));
    QCoreApplication::setApplicationName(QStringLiteral("PomodoroTodo"));

    if (!DatabaseManager::instance()->initialize()) {
        return -1;
    }

    QQmlApplicationEngine engine;
    // QML 通过单例上下文对象访问服务，视图层保持声明式和轻量。
    engine.rootContext()->setContextProperty(QStringLiteral("categoryManager"), CategoryManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("CategoryManager"), CategoryManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("exportService"), ExportService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("ExportService"), ExportService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("taskManager"), TaskManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("focusTimer"), FocusTimer::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("statisticsService"), StatisticsService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("countdownService"), CountdownService::instance());

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
