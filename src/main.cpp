#include <QCoreApplication>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QUrl>

#include "services/DatabaseManager.h"
#include "services/CategoryManager.h"
#include "services/ExportService.h"
#include "services/FocusTimer.h"
#include "services/StatisticsService.h"
#include "services/TaskManager.h"

int main(int argc, char *argv[])
{
    QQuickStyle::setStyle(QStringLiteral("Basic"));

    QGuiApplication app(argc, argv);

    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodo"));
    QCoreApplication::setApplicationName(QStringLiteral("PomodoroTodo"));

    if (!DatabaseManager::instance()->initialize()) {
        return -1;
    }

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("categoryManager"), CategoryManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("CategoryManager"), CategoryManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("exportService"), ExportService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("ExportService"), ExportService::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("taskManager"), TaskManager::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("focusTimer"), FocusTimer::instance());
    engine.rootContext()->setContextProperty(QStringLiteral("statisticsService"), StatisticsService::instance());

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
