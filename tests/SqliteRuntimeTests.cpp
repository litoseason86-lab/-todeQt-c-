#include "platform/macos/SqliteRuntime.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QRegularExpression>
#include <QScopeGuard>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QtTest>

#include <sqlite3.h>
#include <cstdio>

namespace {
QString pluginPath()
{
    return QString::fromUtf8(POMODORO_SQLITE_TEST_PLUGIN_PATH);
}

QByteArray readFile(const QString& path)
{
    QFile file(path);
    return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
}
}

class SqliteRuntimeTests : public QObject
{
    Q_OBJECT
private slots:
    // 保证测试与应用使用确定的驱动工厂，不依赖机器插件搜索路径。
    void initTestCase()
    {
        QString error;
        QVERIFY2(MacSqliteRuntime::initialize(pluginPath(), &error), qPrintable(error));
        QCOMPARE(MacSqliteRuntime::loadedPluginPath(), QFileInfo(pluginPath()).canonicalFilePath());
    }

    // 保证项目插件只导入系统SQLite，包含应用架构，不内嵌第二套运行实例。
    void pluginBinaryUsesSharedSystemSqlite()
    {
        const auto run = [](const QString& command, const QStringList& arguments) {
            QProcess process;
            process.start(command, arguments);
            if (!process.waitForFinished(15000) || process.exitCode() != 0) return QByteArray();
            return process.readAllStandardOutput();
        };
        const QByteArray libraries = run(QStringLiteral("/usr/bin/otool"), {QStringLiteral("-L"), pluginPath()});
        QVERIFY(libraries.contains("/usr/lib/libsqlite3.dylib"));
        const QByteArray defined = run(QStringLiteral("/usr/bin/nm"), {QStringLiteral("-U"), pluginPath()});
        QVERIFY(!defined.isEmpty());
        QVERIFY(!defined.contains("_sqlite3_open_v2"));
        QVERIFY(!defined.contains("_sqlite3_step"));
        const QByteArray architectures = run(QStringLiteral("/usr/bin/lipo"), {QStringLiteral("-archs"), pluginPath()});
        QVERIFY(architectures.trimmed().split(' ').contains(QSysInfo::buildCpuArchitecture().toUtf8()));
    }

    // 保证随应用复制的插件与受验插件逐字节相同，避免只修测试目录而交付旧驱动。
    void applicationContainsVerifiedPlugin()
    {
        const QByteArray built = readFile(pluginPath());
        const QByteArray bundled = readFile(QString::fromUtf8(POMODORO_SQLITE_APP_PLUGIN_PATH));
        QVERIFY(!built.isEmpty());
        QVERIFY(!bundled.isEmpty());
        QCOMPARE(QCryptographicHash::hash(bundled, QCryptographicHash::Sha256),
                 QCryptographicHash::hash(built, QCryptographicHash::Sha256));
    }

    // 保证官方Qt驱动实际使用当前系统引擎，并保留插入编号与绑定的完整字节语义。
    void officialDriverKeepsQueryContract()
    {
        const QString name = QStringLiteral("runtime-contract");
        const auto cleanup = qScopeGuard([&] { QSqlDatabase::removeDatabase(name); });
        auto database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), name);
        database.setDatabaseName(QStringLiteral(":memory:"));
        QVERIFY(database.open());
        QSqlQuery query(database);
        QVERIFY(query.exec(QStringLiteral("SELECT sqlite_version()")) && query.next());
        QCOMPARE(query.value(0).toString(), QString::fromUtf8(sqlite3_libversion()));
        query.finish();
        QVERIFY(query.exec(QStringLiteral("CREATE TABLE values_test(id INTEGER PRIMARY KEY, text_value TEXT, bytes BLOB)")));
        QVERIFY(query.prepare(QStringLiteral("INSERT INTO values_test(text_value,bytes) VALUES(:text,:bytes)")));
        const QString text = QStringLiteral("中文") + QChar(u'\0') + QStringLiteral("尾部");
        const QByteArray bytes("a\0b", 3);
        query.bindValue(QStringLiteral(":text"), text);
        query.bindValue(QStringLiteral(":bytes"), bytes);
        QVERIFY(query.exec());
        QCOMPARE(query.lastInsertId().toLongLong(), qint64(1));
        QVERIFY(query.exec(QStringLiteral("SELECT text_value,bytes FROM values_test")) && query.next());
        QCOMPARE(query.value(0).toString(), text);
        QCOMPARE(query.value(1).toByteArray(), bytes);
    }

    // 保证重复装配幂等，任何已有连接不会被另一份插件替换。
    void repeatedInitializationKeepsFactory()
    {
        QString error;
        QVERIFY(MacSqliteRuntime::initialize(pluginPath(), &error));
        QVERIFY(error.isEmpty());
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        const QString wrong = directory.filePath(QStringLiteral("other.dylib"));
        QVERIFY(QFile::copy(pluginPath(), wrong));
        QVERIFY(!MacSqliteRuntime::initialize(wrong, &error));
        QVERIFY(error.contains(QStringLiteral("不能替换")));
        QCOMPARE(MacSqliteRuntime::loadedPluginPath(), QFileInfo(pluginPath()).canonicalFilePath());
    }

    // 保证缺失、损坏及装配过晚时启动失败，不把SDK插件回退当成装配成功。
    void failedInitializationBlocksStartup_data()
    {
        QTest::addColumn<QString>("kind");
        for (const char* kind : {"missing", "invalid", "late"}) QTest::newRow(kind) << QString::fromLatin1(kind);
    }

    // 保证失败路径在独立进程中验证，既有注册表不会掩盖第一次装配的错误。
    void failedInitializationBlocksStartup()
    {
        QFETCH(QString, kind);
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        QString path = directory.filePath(QStringLiteral("missing.dylib"));
        if (kind == QStringLiteral("invalid")) {
            QFile file(path);
            QVERIFY(file.open(QIODevice::WriteOnly));
            QCOMPARE(file.write("invalid plugin"), qint64(14));
        } else if (kind == QStringLiteral("late")) path = pluginPath();
        QProcess process;
        const auto cleanup = qScopeGuard([&] {
            if (process.state() != QProcess::NotRunning) { process.kill(); process.waitForFinished(1000); }
        });
        process.start(QCoreApplication::applicationFilePath(), {QStringLiteral("--initialize"), path, kind});
        QVERIFY(process.waitForFinished(10000));
        QCOMPARE(process.exitCode(), 0);
        const auto result = QJsonDocument::fromJson(process.readAllStandardOutput()).object();
        QVERIFY(result.contains(QStringLiteral("success")));
        QVERIFY(!result.value(QStringLiteral("success")).toBool());
        QVERIFY(!result.value(QStringLiteral("error")).toString().isEmpty());
        QVERIFY(result.value(QStringLiteral("installed")).toString().isEmpty());
    }
};

int main(int argc, char** argv)
{
    QCoreApplication app(argc, argv);
    if (argc == 4 && QString::fromUtf8(argv[1]) == QStringLiteral("--initialize")) {
        // 此目标不用公共自动装配，才能在全新进程中检验加载失败与错误时序。
        if (QString::fromUtf8(argv[3]) == QStringLiteral("late"))
            QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), QStringLiteral("early"));
        QString error;
        const bool success = MacSqliteRuntime::initialize(QString::fromUtf8(argv[2]), &error);
        const QJsonObject result{{QStringLiteral("success"), success}, {QStringLiteral("error"), error},
                                 {QStringLiteral("installed"), MacSqliteRuntime::loadedPluginPath()}};
        std::puts(QJsonDocument(result).toJson(QJsonDocument::Compact).constData());
        return 0;
    }
    SqliteRuntimeTests tests;
    return QTest::qExec(&tests, argc, argv);
}

#include "SqliteRuntimeTests.moc"
