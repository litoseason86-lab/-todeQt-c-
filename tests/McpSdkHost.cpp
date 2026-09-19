#include "../src/mcp/bridge/McpAccessController.h"
#include "../src/mcp/bridge/McpToolDispatcher.h"
#include "../src/mcp/helper/McpStdioDevice.h"
#include "../src/services/TaskInteractionCoordinator.h"
#include "../src/services/TaskManager.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/StatisticsService.h"
#include "../src/services/KnowledgeGapService.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/AppSettings.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <QSettings>
#include <QJsonDocument>
#include <QTimer>
#include <csignal>

// 独立客户端的无窗口宿主。目录始终由本进程创建，既不接受生产路径，也不打开生产偏好。
int main(int argc, char** argv)
{
    QCoreApplication app(argc, argv);
    std::signal(SIGPIPE, SIG_IGN);
    if (app.arguments().size() != 1) return 2;
    QTemporaryDir directory(QStringLiteral("/private/tmp/mcp-sdk-XXXXXX"));
    if (!directory.isValid()) return 2;
    QCoreApplication::setOrganizationName("McpSdkIsolatedTests");
    QCoreApplication::setApplicationName("McpSdkHost");
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, directory.path());
    AppSettings::instance()->setDayStartHour(4);
    if (!DatabaseManager::instance()->initialize(directory.filePath("test.sqlite"))) return 2;
    QSettings settings(directory.filePath("settings.ini"), QSettings::IniFormat);
    const auto endpoint = McpPaths::resolveForRoot(directory.filePath("endpoint"));
    McpAccessController access(endpoint, settings, [] {
        return QJsonObject{{"app_version", "isolated-sdk-test"}, {"logical_today", "2026-09-18"},
                           {"time_zone", "Asia/Shanghai"}, {"day_start_hour", 4}};
    });
    TaskInteractionCoordinator interactions(TaskManager::instance());
    McpToolDispatcher dispatcher(TaskManager::instance(), CategoryManager::instance(), StatisticsService::instance(),
        KnowledgeGapService::instance(), &interactions, [&access] {
            return McpToolDispatcher::Context{access.sessionId(), QDateTime::fromString("2026-09-18T12:00:00+08:00", Qt::ISODate), 4};
        });
    access.setDataHandler([&](McpContracts::Tool tool, const QJsonObject& args) { return dispatcher.dispatch(tool, args); });
    access.setBlockProvider([&] { return dispatcher.blocks(); });
    QObject::connect(&access, &McpAccessController::sessionChanged, &dispatcher, &McpToolDispatcher::resetCreationSession);
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &access, &McpAccessController::shutdown);
    McpStdioDevice io;
    if (!io.start()) return 2;
    QByteArray input;
    QObject owner;
    auto send = [&](const QJsonObject& value) { io.write(QJsonDocument(value).toJson(QJsonDocument::Compact) + '\n'); };
    QObject::connect(&io, &QIODevice::readyRead, &app, [&] {
        input += io.readAll();
        if (input.size() > 65536) { app.exit(2); return; }
        qsizetype end;
        while ((end = input.indexOf('\n')) >= 0) {
            const auto request = QJsonDocument::fromJson(input.left(end)).object();
            input.remove(0, end + 1);
            const auto command = request.value("command").toString();
            bool ok = true;
            if (command == "enable") ok = access.setEnabled(request.value("value").toBool());
            else if (command == "write") ok = access.setWriteEnabled(request.value("value").toBool());
            else if (command == "restore") { access.beginRestore(); access.setRestoreBlocked(false); }
            else if (command == "pending") interactions.setPendingDelete(&owner, request.value("task_id").toInt());
            else if (command == "editing") ok = !interactions.beginEdit(&owner, request.value("task_id").toInt(), "sdk.editor").isEmpty();
            else if (command == "end") interactions.end(&owner);
            else if (command == "delete") ok = TaskManager::instance()->deleteTask(request.value("task_id").toInt());
            else ok = false;
            send({{"id", request.value("id")}, {"ok", ok}});
        }
    });
    QObject::connect(&io, &McpStdioDevice::inputClosed, &app, &QCoreApplication::quit);
    QObject::connect(&io, &McpStdioDevice::transportFailed, &app, [&] { app.exit(2); });
    send({{"ready", true}, {"endpoint", endpoint.paths.rootDirectory}});
    const int result = app.exec();
    DatabaseManager::instance()->close();
    return result;
}
