#include <QCoreApplication>
#include <QQmlContext>
#include <QQmlEngine>
#include <QStandardPaths>
#include <QtQuickTest/quicktest.h>

#include "../src/services/ScheduleService.h"

class CaliberSetup : public QObject
{
    Q_OBJECT
public slots:
    void applicationAvailable()
    {
        // 宿主只给 QML 提供纯计算方法，不打开数据库；测试路径隔离真实用户偏好。
        QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoTests"));
        QCoreApplication::setApplicationName(QStringLiteral("CaliberQuickTests"));
        QStandardPaths::setTestModeEnabled(true);
    }
    void qmlEngineAvailable(QQmlEngine* engine)
    {
        engine->rootContext()->setContextProperty(QStringLiteral("scheduleCalibers"), ScheduleService::instance());
    }
};

QUICK_TEST_MAIN_WITH_SETUP(calibers, CaliberSetup)
#include "CaliberQuickTests.moc"
