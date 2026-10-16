#include "SqliteRuntime.h"

#include <QCoreApplication>
#include <QFileInfo>
#include <QLibrary>
#include <QPluginLoader>
#include <QSqlDatabase>
#include <QSqlDriver>
#include <QSqlDriverPlugin>
#include <QThread>

#include <memory>
#include <utility>

namespace {
QString installedPlugin;

class PluginDriverCreator final : public QSqlDriverCreatorBase
{
public:
    PluginDriverCreator(std::shared_ptr<QPluginLoader> loader, QSqlDriverPlugin* plugin)
        : m_loader(std::move(loader)), m_plugin(plugin) {}
    QSqlDriver* createObject() const override
    {
        return m_plugin->create(QStringLiteral("QSQLITE"));
    }
private:
    // 工厂随Qt的SQL注册表存活；PreventUnloadHint另保证所有结果对象析构前代码仍存在。
    std::shared_ptr<QPluginLoader> m_loader;
    QSqlDriverPlugin* m_plugin;
};
}

bool MacSqliteRuntime::initialize(const QString& pluginPath, QString* error)
{
    const auto fail = [error](const QString& message) {
        if (error) *error = message;
        return false;
    };
    if (!QCoreApplication::instance()
        || QThread::currentThread() != QCoreApplication::instance()->thread()) {
        return fail(QStringLiteral("SQLite运行时必须在应用主线程装配"));
    }
    const QFileInfo file(pluginPath);
    if (!file.isFile()) return fail(QStringLiteral("应用SQLite驱动缺失：") + pluginPath);
    const QString canonical = file.canonicalFilePath();
    if (!installedPlugin.isEmpty()) {
        if (canonical != installedPlugin) return fail(QStringLiteral("不能替换正在使用的SQLite运行时"));
        if (error) error->clear();
        return true;
    }
    if (!QSqlDatabase::connectionNames().isEmpty()) {
        return fail(QStringLiteral("数据库连接已经创建，拒绝切换SQLite运行时"));
    }
    auto loader = std::make_shared<QPluginLoader>(canonical);
    loader->setLoadHints(QLibrary::ResolveAllSymbolsHint | QLibrary::PreventUnloadHint);
    auto* plugin = qobject_cast<QSqlDriverPlugin*>(loader->instance());
    if (!plugin) return fail(QStringLiteral("无法加载应用SQLite驱动：") + loader->errorString());
    // 注册工厂优先于Qt的插件搜索，所有服务和工作线程的QSQLITE请求都经过同一装配。
    std::unique_ptr<QSqlDriver> probe(plugin->create(QStringLiteral("QSQLITE")));
    if (!probe) return fail(QStringLiteral("应用SQLite插件没有提供QSQLITE驱动"));
    QSqlDatabase::registerSqlDriver(QStringLiteral("QSQLITE"), new PluginDriverCreator(loader, plugin));
    installedPlugin = canonical;
    if (error) error->clear();
    return true;
}

QString MacSqliteRuntime::loadedPluginPath()
{
    return installedPlugin;
}
