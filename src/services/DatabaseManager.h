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
    // 当前 schema 版本（user_version 迁移链的最高版本）。备份/恢复据此判断兼容性：
    // 高于此值的备份由更高版本应用创建，拒绝恢复。
    static constexpr int kCurrentSchemaVersion = 9;

    static DatabaseManager* instance();

    // 初始化会打开数据库、建表并执行必要迁移；dbPath 为空时使用应用默认路径。
    Q_INVOKABLE bool initialize(const QString& dbPath = QString());
    QSqlDatabase database() const;
    bool createTables();
    bool isOpen() const;
    void close();

signals:
    // 每次成功初始化（含同路径重开与换库）都会发出；持有模型缓存的服务
    // 依赖它整体重载，避免在每次业务操作前防御性地全量刷新。
    void databaseChanged();

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
    // v4 给 tasks 增加 routine_id；该版本曾按标题猜测血缘，v6 会清理不可信关联。
    bool migrateToVersion4();
    // v5 重建 tasks 外键，使删除例行规则时既有任务只解除血缘，不被删除也不阻塞删除。
    bool migrateToVersion5();
    // v6 引入可信来源标记；只有新版本实际生成的例行任务才可退出逾期结转。
    bool migrateToVersion6();
    // v7 给 tasks 增加预估番茄数、给 focus_sessions 增加专注模式；后者用来把正向计时
    // 与番茄工作段区分开，实际番茄数聚合时只计番茄模式，避免把自由计时误折算成番茄。
    bool migrateToVersion7();
    // v8 持久化“自然到点”事实，手动停止的番茄段不再被误算为完整番茄。
    bool migrateToVersion8();
    // v9 把会话开始时的科目写入历史快照，任务删除后统计与长期目标仍有归属。
    bool migrateToVersion9();
    bool createRoutinesTable();
    bool insertPresetCategories();
    bool migrateTaskCategories();
    QString generateColorForCategory(int index) const;
    bool backupDatabaseBeforeMigration() const;
    void pruneOldBackups(const QDir& databaseDir) const;
    bool tableExists(const QString& tableName) const;
    bool columnExists(const QString& tableName, const QString& columnName) const;
    bool routineForeignKeyUsesSetNull() const;

    // Qt 的数据库连接按名字管理，测试切换数据库路径时必须能精确关闭旧连接。
    QString m_connectionName;
    QSqlDatabase m_db;
    // 一次 createTables 可能连跨多级迁移；只允许第一级留下整链开始前的原始快照。
    mutable bool m_migrationSnapshotTaken = false;
};

#endif // DATABASEMANAGER_H
