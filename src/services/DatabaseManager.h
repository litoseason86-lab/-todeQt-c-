#ifndef DATABASEMANAGER_H
#define DATABASEMANAGER_H

#include <QObject>
#include <QDir>
#include <QSqlDatabase>
#include <QString>

class DatabaseManager : public QObject
{
    Q_OBJECT

public:
    static DatabaseManager* instance();

    // 初始化会打开数据库、建表并执行必要迁移；dbPath 为空时使用应用默认路径。
    Q_INVOKABLE bool initialize(const QString& dbPath = QString());
    QSqlDatabase database() const;
    bool createTables();
    bool isOpen() const;
    void close();

private:
    explicit DatabaseManager(QObject* parent = nullptr);
    ~DatabaseManager() override;

    // 数据库版本号记录在 user_version，用来判断旧用户数据是否需要升级。
    int getDatabaseVersion() const;
    bool setDatabaseVersion(int version);
    bool migrateToVersion2();
    // categories 是第二阶段加入的科目表，旧任务会在迁移时补上 category_id。
    bool createCategoriesTable();
    bool migrateToVersion3();
    bool createRoutinesTable();
    bool insertPresetCategories();
    bool migrateTaskCategories();
    QString generateColorForCategory(int index) const;
    bool backupDatabaseBeforeMigration() const;
    void pruneOldBackups(const QDir& databaseDir) const;
    bool tableExists(const QString& tableName) const;
    bool columnExists(const QString& tableName, const QString& columnName) const;

    // Qt 的数据库连接按名字管理，测试切换数据库路径时必须能精确关闭旧连接。
    QString m_connectionName;
    QSqlDatabase m_db;
};

#endif // DATABASEMANAGER_H
