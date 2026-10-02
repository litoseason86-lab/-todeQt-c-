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
    // v18 加入设备间同步的结构（见 SyncSchema）；升级后 v17 的应用打不开这个库。
    // v19 同步第二期（计划 051）：课表、知识缺口、目标倒计时也参与同步；升级后 v18 的应用打不开这个库。
    // v20 新增备忘录。旧应用不认识这张表，必须拒绝打开已经升级的数据库。
    static constexpr int kCurrentSchemaVersion = 20;

    static DatabaseManager* instance();
    // 出厂的课表节次（开始、结束的分钟数，按节次先后）。建库时种入；同步据此判断节次是不是还没改过的默认值。
    static QList<QPair<int, int>> defaultSchedulePeriods();

    // 启动和备份检查共用：id 必须是 SQLite 自动生成编号的 INTEGER ROWID 别名。
    static bool hasGeneratedIntegerId(const QSqlDatabase& db, const QString& tableName);
    // 启动和备份检查共用：knowledge_gaps 的外键必须恰好是契约里的三条
    // （category_id → categories，source_task_id / linked_task_id → tasks），删除动作一律 SET NULL。
    // 只校验列和 CHECK 挡不住 ON DELETE CASCADE：那种表照样能用，直到用户删掉一条任务，
    // 关联它的手写缺口被连带删除，而且没有任何报错。
    static bool knowledgeGapForeignKeysAreValid(const QSqlDatabase& db);
    // 启动与备份共用备忘录契约：删科目只能归到未分类，不能连带删除正文。
    static bool memoForeignKeysAreValid(const QSqlDatabase& db);
    static bool memoSchemaIsValid(const QSqlDatabase& db);

    // 应用默认数据库路径。迁移快照（pomodoro_backup_*.db）与它同目录，
    // 所以启动失败时把这条路径给用户，就等于同时指出了数据库和快照的位置。
    // 可写位置拿不到时返回空串。
    static QString defaultDatabasePath();

    // 初始化会打开数据库、建表并执行必要迁移；dbPath 为空时使用应用默认路径。
    Q_INVOKABLE bool initialize(const QString& dbPath = QString());
    QSqlDatabase database() const;
    bool createTables();
    bool isOpen() const;
    // 本次成功打开数据库前磁盘文件是否已存在。仅用于决定是否展示迁移说明，
    // 不能拿它替代 schema 版本或用户历史内容判断。
    bool openedExistingDatabase() const;
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
    // v9 把会话开始时的科目写入历史快照，任务删除后统计仍有归属。
    bool migrateToVersion9();
    // v10：任务的「预估番茄数」改为「预计用时（分钟）」。
    bool migrateToVersion10();
    // v11 给 tasks 增加两列，合并成一次迁移是为了只建一份迁移快照、只重入一次：
    //   tasks.notes                  （任务备注）
    //   tasks.display_order          （任务手动排序）
    // 当年它还把长期目标的番茄数折成分钟；v17 删掉了长期目标表，那一步随之去掉。
    bool migrateToVersion11();
    // v12 将历史的 0 序号和同日重复序号按旧版可见顺序固化为正整数，
    // 使后续所有任务写路径共享同一个排序不变量。
    bool migrateToVersion12();
    // v13 新增课表两表（schedule_entries / schedule_periods）。纯新增，不触碰任何旧表：
    // 课表项按「星期几 + 时段」循环，与按具体日期存储的 tasks 是两套互不相干的数据。
    bool migrateToVersion13();
    // v14 新增 knowledge_gaps（知识缺口）。同样是纯新增表，不触碰任何旧表。
    //
    // 这里刻意没有沿用 rest_sessions 那种「不升版本、每次建表时幂等补上」的省事做法：
    // 那种表在恢复一个不含它的旧备份时会被建成空表，于是「数据丢了」会伪装成「恢复成功」。
    // 休息记录丢了还能从别处推断，知识缺口全是用户手写的原创内容，丢了不可再生，
    // 必须走版本链，让 BackupOperations 能按备份的 schema 版本要求这张表必须存在。
    bool migrateToVersion14();
    // v15 给 routines 增加重复日位掩码 weekdays：例行不再必须每天生成，
    // 可以只落在选中的星期。既有例行补默认值「每天」，行为与升级前一致。
    bool migrateToVersion15();
    // v16 给 tasks 增加完成记录 completion_note：用户点「完成」时写下这次具体做完了什么。
    // 它和 notes（做之前写的页码、要点）是两回事，分开存才不会互相覆盖。
    bool migrateToVersion16();
    // v17 删除长期目标表 long_goals：2026-09「目标」页连同数据一起删掉。
    // 删表会丢掉用户写下的目标，所以表存在时先走迁移快照；从来没用过目标页的库里本来就没有这张表，
    // 那种库只推版本号，不建快照。
    bool migrateToVersion17();
    // v18 设备间同步：同步表清单（SyncSchema::tables，第一期五张、第二期又加三张）里的业务表加 sync_id，
    // 新建字段版本、待发送队列、删除记录等附属表，给已有记录回填身份与初始版本、放进待发送队列，
    // 再装上维护它们的触发器。可以重复执行，半迁移、外部改库或清单里新加的表留下的缺口，下次启动会补齐。
    bool migrateToVersion18();
    // v19：结构上的活都在 v18 那一步里（它按 SyncSchema 的表清单处理，第二期的三张表加进清单后一并补齐），
    // 这一步只把版本号推到 19。必须推：v18 的应用不认识这三张表，打开库时会把它们的同步触发器当成
    // 过时的删掉，之后在 v18 里改的课表、知识缺口、倒计时就不会被记下来、永远发不出去。
    bool migrateToVersion19();
    // 先建备忘录表，再运行可重入的同步迁移，最后才推进版本号。
    bool createMemoTable();
    bool migrateToVersion20();
    // 目标倒计时表原来由倒计时服务第一次用到时才建（CountdownService::initializeDatabase）。
    // 它要参与同步，迁移时表必须已经在，所以建表流程里也建一次，结构与服务里的相同。
    bool createCountdownGoalsTable();
    bool syncSchemaIsComplete() const;
    // 每次启动都执行：补附属表的初始行、sync_id 唯一索引，并让同步触发器与规范文本一致。
    // 触发器随业务表存在，整表重建（v5）会把它们一起删掉，所以不能只在迁移时建一次。
    bool ensureSyncInfrastructure();
    bool ensureSyncTriggers();
    // 每次打开库、在任何迁移写入之前调用：名字是同步触发器、内容却与本版本生成的规范文本不一致的
    // （更早版本留下的、外部改过的、随备份带进来的伪造品），一律先拆掉，打开库的最后一步按规范重建。
    // 迁移链会写业务表（例如排序号坏了要重排），这些触发器若还挂着，就会带着不明的内容跑一遍。
    // 恢复备份因此可以放行任何内容的同步触发器，以后改了同步表或触发器写法，旧备份也照样能恢复。
    bool dropForeignSyncTriggers();
    // 库已是 v18、附属表或业务表上的同步列却缺了（外部改过库、恢复被打断）：先拆掉同步触发器。
    // 触发器引用的表或列不存在时，迁移链前面几步对业务表的写入会全部报错，应用就启动不了。
    // 随后的迁移会把缺的列补回来，v18 步骤再把触发器装上。
    bool dropSyncTriggersIfSchemaIncomplete();
    bool createRoutinesTable();
    // 课表项表与节次预设表。两者一起建：节次预设是课表录入的快捷填充来源，
    // 缺了它课表页的「按节次」显示模式就没有行可画。
    bool createScheduleTables();
    // 首次建表时种入一套默认节次（上午/下午/晚上）。仅在节次表为空时写入，
    // 避免用户清空或改写节次后，下次启动又被默认值填回来。
    bool insertDefaultSchedulePeriods();
    bool insertPresetCategories();
    bool migrateTaskCategories();
    QString generateColorForCategory(int index) const;
    bool backupDatabaseBeforeMigration() const;
    // keepPath 是本次迁移前刚拍的快照，无条件保留（见 SnapshotRetention::prune）。
    void pruneOldBackups(const QDir& databaseDir, const QString& keepPath) const;
    bool tableExists(const QString& tableName) const;
    bool indexExists(const QString& indexName) const;
    bool columnExists(const QString& tableName, const QString& columnName) const;
    // v13 是首个会被备份整库恢复的课表版本。CREATE TABLE IF NOT EXISTS
    // 不会修补已存在表的缺列、缺约束或错外键，所以必须显式验证。
    bool scheduleSchemaIsValid() const;
    // 知识缺口表。与课表同理：CREATE TABLE IF NOT EXISTS 不会修补已存在表的缺列，
    // 所以建表之后必须显式验证一次结构。
    bool createKnowledgeGapTable();
    bool knowledgeGapSchemaIsValid() const;
    // 表的当前列名集合。v5 整表重建需要它来确认自己认识 tasks 的每一列——
    // 重建用的是写死的列清单，遇到不认识的列必须拒绝执行而不是把它连同数据丢掉。
    QStringList tableColumns(const QString& tableName) const;
    // tasks.routine_id 的外键动作是否已经是 SET NULL。
    // checkSucceeded 用来区分「外键确实不对」和「这次查询没成功」：
    // 两者都返回 false，但只有前者才该触发 v5 的整表重建。
    bool routineForeignKeyUsesSetNull(bool* checkSucceeded = nullptr) const;

    // Qt 的数据库连接按名字管理，测试切换数据库路径时必须能精确关闭旧连接。
    QString m_connectionName;
    QSqlDatabase m_db;
    // 一次 createTables 可能连跨多级迁移；只允许第一级留下整链开始前的原始快照。
    mutable bool m_migrationSnapshotTaken = false;
    // 只在 initialize 成功后更新。失败或同路径重入不能篡改首次成功打开时的事实。
    bool m_openedExistingDatabase = false;
    // SQLite 打开成功但建表/迁移失败时，连接仍可能可用。保留这次打开前的事实，
    // 使修复问题后对同一路径重试时仍按最初启动语义提交，而不是把新库误判为旧库。
    bool m_currentDatabaseExistedBeforeOpen = false;
    bool m_currentDatabaseInitializationSucceeded = false;
};

#endif // DATABASEMANAGER_H
