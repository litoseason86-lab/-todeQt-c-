#include "DatabaseManager.h"

#include "SnapshotRetention.h"
#include "FocusSessionRules.h"
#include "RoutineRules.h"
#include "SyncSchema.h"

#include <QDebug>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QStringList>
#include <QMap>

#include <iterator>

namespace {
constexpr auto kConnectionName = "PomodoroTodoConnection";

QString normalizedCreateSql(QString sql)
{
    sql = sql.toLower();
    sql.remove(QRegularExpression(QStringLiteral("\\s+")));
    sql.remove(QLatin1Char('"'));
    sql.remove(QLatin1Char('`'));
    sql.remove(QLatin1Char('['));
    sql.remove(QLatin1Char(']'));
    return sql;
}
}

const DatabaseManager::PresetCategory DatabaseManager::kPresetCategories[] = {
    {"数学", "#d4a574"},
    {"英语", "#c9956e"},
    {"政治", "#be8568"},
    {"专业课", "#b37562"},
    {"其他", "#a8655c"}
};

QString DatabaseManager::pomodoroCycleStateTableSql()
{
    // 迁移与已升级库补表共用约束，避免两条建表路径对计数类型或范围的定义分叉。
    return QStringLiteral(
        "CREATE TABLE IF NOT EXISTS pomodoro_cycle_state (singleton_id INTEGER PRIMARY KEY CHECK(singleton_id=1), "
        "completed_pomodoros INTEGER NOT NULL CHECK(typeof(completed_pomodoros)='integer' "
        "AND completed_pomodoros BETWEEN 0 AND 2147483647))");
}

bool DatabaseManager::execSql(QSqlQuery& query, const QString& sql, const char* context)
{
    if (!query.exec(sql)) {
        qWarning() << context << query.lastError().text();
        return false;
    }
    return true;
}

DatabaseManager::DatabaseManager(QObject* parent)
    : QObject(parent)
    , m_connectionName(QLatin1String(kConnectionName))
{
}

DatabaseManager::~DatabaseManager()
{
    close();
}

DatabaseManager* DatabaseManager::instance()
{
    static DatabaseManager manager;
    return &manager;
}

QString DatabaseManager::defaultDatabasePath()
{
    const QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (dataDir.isEmpty()) {
        return QString();
    }
    return QDir(dataDir).absoluteFilePath(QStringLiteral("pomodoro.db"));
}

bool DatabaseManager::initialize(const QString& dbPath)
{
    QString path = dbPath.trimmed();
    if (path.isEmpty()) {
        path = defaultDatabasePath();
        if (path.isEmpty()) {
            qWarning() << "Failed to prepare application data directory";
            return false;
        }
    } else {
        path = QFileInfo(path).absoluteFilePath();
    }

    // 必须在创建目录、打开 SQLite 或迁移前记录事实。它只服务于一次性升级说明，
    // 不能根据迁移后的 schema 反推，否则全新安装也会被误判成旧用户。
    const bool existedBeforeOpen = QFileInfo::exists(path);
    const QDir parentDir = QFileInfo(path).absoluteDir();
    if (!parentDir.exists() && !QDir().mkpath(parentDir.absolutePath())) {
        qWarning() << "Failed to prepare database directory:" << parentDir.absolutePath();
        return false;
    }

    if (m_db.isOpen() && m_db.databaseName() == path) {
        if (!createTables()) {
            return false;
        }
        if (!m_currentDatabaseInitializationSucceeded) {
            m_openedExistingDatabase = m_currentDatabaseExistedBeforeOpen;
            m_currentDatabaseInitializationSucceeded = true;
        }
        emit databaseChanged();
        return true;
    }

    if (m_db.isValid()) {
        m_db.close();
    }

    if (QSqlDatabase::contains(m_connectionName)) {
        // Qt 要求 removeDatabase() 前清掉所有句柄，否则旧连接可能残留，
        // 使用临时数据库路径的测试会变得不稳定。
        m_db = QSqlDatabase();
        QSqlDatabase::removeDatabase(m_connectionName);
    }
    m_db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), m_connectionName);
    m_currentDatabaseExistedBeforeOpen = existedBeforeOpen;
    m_currentDatabaseInitializationSucceeded = false;

    m_db.setDatabaseName(path);
    if (!m_db.open()) {
        qWarning() << "Failed to open database:" << path << m_db.lastError().text();
        return false;
    }

    QSqlQuery pragmaQuery(m_db);
    if (!pragmaQuery.exec(QStringLiteral("PRAGMA foreign_keys = ON"))) {
        qWarning() << "Failed to enable SQLite foreign keys:" << pragmaQuery.lastError().text();
        return false;
    }

    // 导出走工作线程，会对同一个库文件另开一条连接（见 ExportService::acquireDatabase）。
    // SQLite 的 busy_timeout 默认是 0——撞上别的连接持锁就立刻返回 SQLITE_BUSY，
    // 于是导出期间主线程的一次提交（结束番茄、存会话）会当场失败，而调用方只有 qWarning。
    // 给足等待窗口，让并发访问退化成"慢一点"而不是"丢一次写入"。
    // 数值与 BackupOperations 里那条保持一致：同一个库出现两个不同超时值会让人以为有特殊含义。
    if (!pragmaQuery.exec(QStringLiteral("PRAGMA busy_timeout = 5000"))) {
        qWarning() << "Failed to set SQLite busy timeout:" << pragmaQuery.lastError().text();
        return false;
    }
    // busy_timeout 和 foreign_keys 不一样：它会**返回一行**（设置后的新值）。
    // 不收尾的话这条语句一直挂在连接上，后面迁移快照的 VACUUM INTO 会报
    // "cannot VACUUM - SQL statements in progress"，而且这条未完成的语句还会一直占着读锁。
    pragmaQuery.finish();

    if (!createTables()) {
        return false;
    }
    // 只有完整打开并迁移成功才提交本次启动的上下文；失败不能污染上一次成功结果。
    m_openedExistingDatabase = m_currentDatabaseExistedBeforeOpen;
    m_currentDatabaseInitializationSucceeded = true;
    emit databaseChanged();
    return true;
}

bool DatabaseManager::createTables()
{
    if (!m_db.isOpen()) {
        qWarning() << "Cannot create tables: database is not open";
        return false;
    }

    int version = getDatabaseVersion();
    if (version < 0) {
        return false;
    }
    if (version > kCurrentSchemaVersion) {
        // 必须在任何 CREATE/ALTER 之前拒绝未来 schema，旧程序不能先修改再宣布不兼容。
        qWarning() << "Database schema is newer than this application:"
                   << version << ">" << kCurrentSchemaVersion;
        return false;
    }

    // createTables 是一条完整迁移链的边界；每次进入都重置，使结构缺列触发的防御性迁移也能正确备份。
    m_migrationSnapshotTaken = false;

    // 不论版本，先拆掉内容与本版本规范不一致的同步触发器，再开始任何迁移写入（见 dropForeignSyncTriggers）。
    if (!dropForeignSyncTriggers()) {
        return false;
    }
    if (version >= 18 && !dropSyncTriggersIfSchemaIncomplete()) {
        return false;
    }

    QSqlQuery query(m_db);

    const QString createTasksTable = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL CHECK(length(trim(title)) > 0),
            category TEXT,
            category_id INTEGER REFERENCES categories(id),
            routine_id INTEGER REFERENCES routines(id) ON DELETE SET NULL,
            routine_generated INTEGER NOT NULL DEFAULT 0 CHECK(routine_generated IN (0, 1)),
            estimated_minutes INTEGER NOT NULL DEFAULT 0,
            notes TEXT NOT NULL DEFAULT '',
            display_order INTEGER NOT NULL DEFAULT 0,
            date TEXT NOT NULL,
            completed INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            completion_note TEXT NOT NULL DEFAULT ''
        )
    )SQL");
    if (!execSql(query, createTasksTable, "Failed to create tasks table:")) {
        return false;
    }

    const QString createSessionsTable = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS focus_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id INTEGER,
            start_time TEXT NOT NULL,
            end_time TEXT,
            duration INTEGER,
            mode INTEGER NOT NULL DEFAULT 1,
            pomodoro_completed INTEGER NOT NULL DEFAULT 0 CHECK(pomodoro_completed IN (0, 1)),
            category_id_snapshot INTEGER,
            category_name_snapshot TEXT NOT NULL DEFAULT '',
            category_color_snapshot TEXT NOT NULL DEFAULT '',
            FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
        )
    )SQL");
    if (!execSql(query, createSessionsTable, "Failed to create focus_sessions table:")) {
        return false;
    }

    // 休息独立存储，避免现有专注统计、任务进度和导出误把休息累计进去。
    // 纯新增表在每次初始化时幂等检查，旧数据库和旧备份无需改写专注数据。
    if (!execSql(query, QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS rest_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_time TEXT NOT NULL,
            end_time TEXT NOT NULL,
            duration INTEGER NOT NULL CHECK(duration > 0),
            manual INTEGER NOT NULL CHECK(manual IN (0, 1))
        )
    )SQL"), "Failed to create rest sessions table:")) {
        return false;
    }

    const QString createActiveFocusStateTable = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS active_focus_state (
            singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
            session_id INTEGER UNIQUE,
            task_id INTEGER,
            task_title TEXT NOT NULL DEFAULT '',
            elapsed_seconds INTEGER NOT NULL DEFAULT 0 CHECK(elapsed_seconds >= 0),
            mode INTEGER NOT NULL,
            phase INTEGER NOT NULL,
            target_seconds INTEGER NOT NULL DEFAULT 0 CHECK(target_seconds >= 0),
            completed_pomodoros INTEGER NOT NULL DEFAULT 0 CHECK(completed_pomodoros >= 0),
            updated_at TEXT NOT NULL,
            FOREIGN KEY (session_id) REFERENCES focus_sessions(id) ON DELETE CASCADE,
            FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
        )
    )SQL");
    // 历史表只保存已完成记录；活动状态独立存放，应用异常退出后才能恢复，而不是留下不可见的 NULL 占位行。
    if (!execSql(query, createActiveFocusStateTable, "Failed to create active_focus_state table:")) {
        return false;
    }

    // 活动会话表不参与 user_version 迁移链。旧用户可能已经有该表但缺少新列，
    // 必须在每次建表检查时补齐，否则恢复番茄轮次会静默退回 0。
    if (!columnExists(QStringLiteral("active_focus_state"),
                      QStringLiteral("completed_pomodoros"))) {
        if (!execSql(query,
                     QStringLiteral("ALTER TABLE active_focus_state ADD COLUMN "
                                    "completed_pomodoros INTEGER NOT NULL DEFAULT 0 "
                                    "CHECK(completed_pomodoros >= 0)"),
                     "Failed to add active focus pomodoro count:")) {
            return false;
        }
    }

    // 休息没有专注行可回查开始时间；新增快照字段保留暂停和重启前的真实起点。
    // 旧快照留空，由恢复逻辑使用最后检查点推算，不把升级后的离线时间计入休息。
    if (!columnExists(QStringLiteral("active_focus_state"), QStringLiteral("start_time"))
        && !execSql(query, QStringLiteral("ALTER TABLE active_focus_state ADD COLUMN start_time TEXT"),
                    "Failed to add active state start time:")) {
        return false;
    }

    // 恢复锚点：进程在后台被系统结束后，靠这几列把离线时段按单调时钟补回来。
    //   running          写入时是否在计时；
    //   accumulated_ms   本段运行之前已累计的毫秒数；
    //   segment_start_ns 本段开始时的单调时钟读数（暂停时为空）；
    //   segment_start_wall_ms 同一时刻的墙钟（UTC 毫秒），恢复时与单调时钟对账，
    //                    确认是同一次开机、期间没人改钟（iOS 读不到开机标识，靠它判断）；
    //   boot_id          写入时的开机会话标识，读得到时（macOS）作为额外的核对。
    // 旧快照补列后 running 为 0，恢复时按原语义「恢复为暂停」，不会凭空补算时间。
    const struct {
        const char* name;
        const char* definition;
    } anchorColumns[] = {
        {"running", "running INTEGER NOT NULL DEFAULT 0 CHECK(running IN (0, 1))"},
        {"accumulated_ms", "accumulated_ms INTEGER NOT NULL DEFAULT 0"},
        {"segment_start_ns", "segment_start_ns INTEGER"},
        {"segment_start_wall_ms", "segment_start_wall_ms INTEGER"},
        {"boot_id", "boot_id TEXT"},
    };
    for (const auto& column : anchorColumns) {
        if (!columnExists(QStringLiteral("active_focus_state"), QString::fromLatin1(column.name))
            && !execSql(query,
                        QStringLiteral("ALTER TABLE active_focus_state ADD COLUMN %1")
                            .arg(QString::fromLatin1(column.definition)),
                        "Failed to add active state recovery anchor:")) {
            return false;
        }
    }

    // 版本 2 引入 categories/category_id，同时保留旧版文本科目。
    if (version < 2
        || !tableExists(QStringLiteral("categories"))
        || !columnExists(QStringLiteral("tasks"), QStringLiteral("category_id"))) {
        if (!migrateToVersion2()) {
            return false;
        }
        version = 2;
    } else if (!createCategoriesTable() || !insertPresetCategories()) {
        return false;
    }

    // 版本 3 引入每日例行表 routines（纯新增，向后兼容）。
    if (version < 3 || !tableExists(QStringLiteral("routines"))) {
        if (!migrateToVersion3()) {
            return false;
        }
        version = 3;
    }

    // 版本 4 给 tasks 增加 routine_id 血缘列；列缺失时无论版本号都要补，防御半迁移状态。
    if (version < 4
        || !columnExists(QStringLiteral("tasks"), QStringLiteral("routine_id"))) {
        if (!migrateToVersion4()) {
            return false;
        }
        version = 4;
    }

    // v5 是整个迁移链里唯一会整表重建 tasks 的一步，代价最高、破坏力最大。
    // 结构检查失败时才重建，而「查询本身没跑成功」不算结构失败——否则一次瞬时的
    // PRAGMA 故障就会让一个已经迁移完成的库白白重建一次。
    bool foreignKeyCheckSucceeded = false;
    const bool foreignKeyIsCorrect = routineForeignKeyUsesSetNull(&foreignKeyCheckSucceeded);
    if (version < 5 || (foreignKeyCheckSucceeded && !foreignKeyIsCorrect)) {
        if (!migrateToVersion5()) {
            return false;
        }
        version = 5;
    } else if (!foreignKeyCheckSucceeded) {
        // 不重建，但也不能假装一切正常：下次启动查询成功时会再判一次。
        qWarning() << "跳过 v5 外键检查：无法读取 tasks 外键定义，本次不重建该表";
    }

    if (version < 6
        || !columnExists(QStringLiteral("tasks"), QStringLiteral("routine_generated"))) {
        if (!migrateToVersion6()) {
            return false;
        }
        version = 6;
    }

    // 版本 7 给 tasks 增加任务预估列，给 focus_sessions 增加专注模式列；
    // 任一列缺失都要补，防御半迁移或旧库缺列时实际番茄聚合静默失真。
    //
    // 这里的结构检查必须查 v10 之后的列名 estimated_minutes，不能查 v7 当年加的
    // estimated_pomodoros：v10 会在换算完成后删掉旧列，若仍按旧列名判断，
    // 一个已经迁到 v10 的库每次启动都会重跑 v7–v10 四步迁移（各建一次迁移快照），
    // 最终状态自愈、用户数据不丢（v10 的回填有 estimated_minutes = 0 守卫），
    // 但那是每次启动都白做一遍的重活。
    if (version < 7
        || !columnExists(QStringLiteral("tasks"), QStringLiteral("estimated_minutes"))
        || !columnExists(QStringLiteral("focus_sessions"), QStringLiteral("mode"))) {
        if (!migrateToVersion7()) {
            return false;
        }
        version = 7;
    }

    if (version < 8
        || !columnExists(QStringLiteral("focus_sessions"),
                         QStringLiteral("pomodoro_completed"))) {
        if (!migrateToVersion8()) {
            return false;
        }
        version = 8;
    }

    if (version < 9
        || !columnExists(QStringLiteral("focus_sessions"),
                         QStringLiteral("category_id_snapshot"))
        || !columnExists(QStringLiteral("focus_sessions"),
                         QStringLiteral("category_name_snapshot"))
        || !columnExists(QStringLiteral("focus_sessions"),
                         QStringLiteral("category_color_snapshot"))) {
        if (!migrateToVersion9()) {
            return false;
        }
        version = 9;
    }

    // v10 把「预估番茄数」换成「预计用时（分钟）」。列缺失时无论版本号都要补，
    // 与前面几步一样防御半迁移状态。
    if (version < 10
        || !columnExists(QStringLiteral("tasks"), QStringLiteral("estimated_minutes"))) {
        if (!migrateToVersion10()) {
            return false;
        }
        version = 10;
    }

    // v11：任务加备注与手动排序。两列缺任意一列都要补，与前面几步同理防御半迁移状态。
    if (version < 11
        || !columnExists(QStringLiteral("tasks"), QStringLiteral("notes"))
        || !columnExists(QStringLiteral("tasks"), QStringLiteral("display_order"))) {
        if (!migrateToVersion11()) {
            return false;
        }
        version = 11;
    }

    // 即使 user_version 已经是 12，也要识别恢复中断或外部写入留下的半迁移数据。
    // 查询失败与“不需要修复”是两种状态；前者必须让初始化失败，不能放过未知的不变量状态。
    QSqlQuery taskOrderInvariantQuery(m_db);
    if (!taskOrderInvariantQuery.exec(QStringLiteral(
            "SELECT 1 FROM tasks GROUP BY date "
            "HAVING MIN(display_order) <= 0 "
            "OR COUNT(DISTINCT display_order) != COUNT(*) LIMIT 1"))) {
        qWarning() << "Failed to inspect task display order invariant:"
                   << taskOrderInvariantQuery.lastError().text();
        return false;
    }
    const bool taskOrderNeedsNormalization = taskOrderInvariantQuery.next();
    // VACUUM INTO 迁移快照要求连接上没有仍在取数的语句；拿到布尔结论后立即释放游标。
    taskOrderInvariantQuery.finish();
    if (version < 12 || taskOrderNeedsNormalization) {
        if (!migrateToVersion12()) {
            return false;
        }
        version = 12;
    }

    // v13 引入课表两表。表缺失时无论版本号都要建，与前面几步同理防御半迁移状态。
    // 注意这里不能只判 schedule_entries：节次表是独立的一张，
    // 只建了课表项而节次表缺失时，「按节次」显示模式会没有任何行可画。
    if (version < 13
        || !tableExists(QStringLiteral("schedule_entries"))
        || !tableExists(QStringLiteral("schedule_periods"))) {
        if (!migrateToVersion13()) {
            return false;
        }
        version = 13;
    }

    // 仅判断表名存在是假安全：缺列的 v13 备份也会通过 IF NOT EXISTS，
    // 随后恢复流程会报成功，直到用户真正打开课表才查询失败。
    if (!scheduleSchemaIsValid()) {
        qWarning() << "Schedule schema is incomplete or incompatible";
        return false;
    }

    // v14 引入知识缺口表。与前面几步同理：表缺失时无论版本号都要建，防御半迁移状态。
    if (version < 14 || !tableExists(QStringLiteral("knowledge_gaps"))) {
        if (!migrateToVersion14()) {
            return false;
        }
        version = 14;
    }

    // 同样不能只判表名存在：缺列的库也会通过 IF NOT EXISTS，
    // 之后要等用户真的打开知识缺口页才查询失败，那时已经看不出是结构问题。
    if (!knowledgeGapSchemaIsValid()) {
        qWarning() << "Knowledge gap schema is incomplete or incompatible";
        return false;
    }

    // v15 给 routines 增加重复日位掩码。列缺失时无论版本号都要补，与前面几步同理防御半迁移状态：
    // 缺了这一列，例行生成查询会直接报错，整张今日清单都不再自动补例行任务。
    if (version < 15 || !columnExists(QStringLiteral("routines"), QStringLiteral("weekdays"))) {
        if (!migrateToVersion15()) {
            return false;
        }
        version = 15;
    }

    // v16 给 tasks 增加完成记录列。与前面几步同理，列缺失时无论版本号都要补：
    // 任务查询会直接读这一列，缺了它今日任务、周计划整页都加载失败。
    if (version < 16 || !columnExists(QStringLiteral("tasks"), QStringLiteral("completion_note"))) {
        if (!migrateToVersion16()) {
            return false;
        }
        version = 16;
    }

    // v17 删除长期目标表。表还在时无论版本号都要删，与前面几步同理防御半迁移状态。
    // 恢复 v16 及更早的备份会把表带回来，那时版本号本来就小于 17；版本号已是 17 而表还在，
    // 只可能是外部改过库或恢复中途被打断。旧版本不会把表重新建出来：它打不开 v17 的库
    // （见本函数开头对未来 schema 的拒绝），目标服务也就没有机会按「懒建」再建一张。
    if (version < 17 || tableExists(QStringLiteral("long_goals"))) {
        if (!migrateToVersion17()) {
            return false;
        }
        version = 17;
    }

    // 倒计时表要参与同步，下面的同步迁移要给它加列、回填、装触发器，所以先确保它在。
    if (!createCountdownGoalsTable()) {
        return false;
    }

    // 新增表前先拍快照，保存真正的升级前数据；表先于同步迁移建立，
    // 阶段 2 加入同步清单后可复用原来的身份回填与触发器安装，不另写一套迁移。
    if (version < 20 || !tableExists(QStringLiteral("memos"))) {
        // 表已完整、只是版本号被调低时没有新结构改动，不占用快照保留名额。
        if ((!tableExists(QStringLiteral("memos")) && !backupDatabaseBeforeMigration())
            || !createMemoTable()) {
            return false;
        }
    }
    if (!memoSchemaIsValid(m_db)) {
        qWarning() << "备忘录表结构不完整或不兼容";
        return false;
    }

    // 废纸篓表（v21）。与备忘录同理：新增表前先拍迁移快照，保存真正的升级前数据；
    // 表已完整、只是版本号被调低时没有结构改动，不占快照保留名额（backupDatabaseBeforeMigration 一次启动只拍一份）。
    // 废纸篓已登记进同步清单：这里新建的表还没有 sync_id，在同一次打开里由后面的 v18 那一步
    // 按清单补齐 sync_id、回填、入队和触发器（syncSchemaIsComplete 逐表检查，缺列就重跑）；
    // 已经是 v21、废纸篓表却还没有同步列的库（计划 054 阶段 1 留下的）也走同一条路，版本号不变。
    // 补出来的列不属于业务契约（见 trashSchemaIsValid）。
    if (version < 21 || !tableExists(QStringLiteral("trash_items"))) {
        if ((!tableExists(QStringLiteral("trash_items")) && !backupDatabaseBeforeMigration())
            || !createTrashTable()) {
            return false;
        }
    }
    if (!trashSchemaIsValid(m_db)) {
        qWarning() << "废纸篓表结构不完整或不兼容";
        return false;
    }

    // v18 设备间同步。缺任何一部分（半迁移、外部改库、v5 整表重建带走了唯一索引）都重跑一遍，
    // 迁移本身可以重复执行，已经有的身份和版本保持不动。第二期加进同步清单的三张表也由这一步补齐
    // （备忘录、废纸篓同理）：v18 的库里它们还没有 sync_id，结构判为不完整，
    // 这一步就会给它们加列、回填并放进待发送队列。
    if (version < 18 || !syncSchemaIsComplete()) {
        if (!migrateToVersion18()) {
            return false;
        }
        version = 18;
    }
    if (version < 19) {
        if (!migrateToVersion19()) {
            return false;
        }
        version = 19;
    }
    if (!ensureSyncInfrastructure()) {
        return false;
    }
    if (version < 20 && !migrateToVersion20()) {
        return false;
    }
    if (version < 21 && !migrateToVersion21()) {
        return false;
    }
    if (version < 22 && !migrateToVersion22()) {
        return false;
    }
    // 已升级库丢失或损坏的循环计数只影响长休息节奏，告警后从零重新开始；
    // 不从可能陈旧的活动镜像猜测计数。外部备份仍由恢复入口严格校验，不在这里放宽。
    if (!ensurePomodoroCycleState()) {
        return false;
    }

    // 节次表存在但一行都没有，同样是「按节次」版式画不出任何行的那种坏状态
    // （中断的恢复、外部编辑都会留下它）。上面的守卫只看表在不在，治不了这种；
    // 这里无条件补种一次。insertDefaultSchedulePeriods 自己按「表为空」加了守卫，
    // 所以用户改过或删过节次之后再启动，不会被默认值覆盖回去。
    if (!m_db.transaction()) {
        qWarning() << "Failed to start default schedule period transaction:"
                   << m_db.lastError().text();
        return false;
    }
    if (!insertDefaultSchedulePeriods() || !m_db.commit()) {
        qWarning() << "Failed to commit default schedule periods:"
                   << m_db.lastError().text();
        m_db.rollback();
        return false;
    }

    const QStringList indexes = {
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_tasks_date ON tasks(date)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_tasks_completed ON tasks(completed)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_tasks_category_id ON tasks(category_id)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_sessions_task ON focus_sessions(task_id)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_sessions_category_snapshot "
                       "ON focus_sessions(category_id_snapshot)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_sessions_start ON focus_sessions(start_time)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_routines_active ON routines(active)"),
        // 课表网格每次渲染都按「星期几 + 开始时间」取数，这条复合索引让一周七列
        // 各自的查询直接走索引顺序，省掉每次切周都要做的排序。
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_schedule_entries_weekday "
                       "ON schedule_entries(weekday, start_minutes)"),
        // 知识缺口的每次查询都先按状态筛（待处理/已安排/已解决），再按到期日排；
        // 提示条的「今天到期 / 已逾期」统计也走同一条路径，所以按这两列建复合索引。
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_knowledge_gaps_status_due "
                       "ON knowledge_gaps(status, due_date)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_memos_category_order "
                       "ON memos(category_id, sort_order, created_at)"),
        // 清理过期项按 deleted_at 范围扫，列表也按它排序；去重与「删同一原记录的全部行」按 origin_sync_id 查。
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_trash_items_deleted ON trash_items(deleted_at)"),
        QStringLiteral("CREATE INDEX IF NOT EXISTS idx_trash_items_origin ON trash_items(origin_sync_id)")
    };

    for (const QString& indexSql : indexes) {
        if (!execSql(query, indexSql, "Failed to create database index:")) {
            return false;
        }
    }

    return true;
}

int DatabaseManager::getDatabaseVersion() const
{
    if (!m_db.isOpen()) {
        qWarning() << "Failed to read database version: database is not open";
        return -1;
    }

    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("PRAGMA user_version"))) {
        qWarning() << "Failed to read database version:" << query.lastError().text();
        return -1;
    }

    if (!query.next()) {
        qWarning() << "Failed to read database version: query returned no row";
        return -1;
    }
    return query.value(0).toInt();
}

bool DatabaseManager::createCategoriesTable()
{
    QSqlQuery query(m_db);
    const QString createCategories = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE CHECK(length(trim(name)) > 0),
            color TEXT NOT NULL,
            is_preset INTEGER NOT NULL DEFAULT 0,
            display_order INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    )SQL");

    if (!execSql(query, createCategories, "Failed to create categories table:")) {
        return false;
    }

    return execSql(query,
                   QStringLiteral("CREATE INDEX IF NOT EXISTS idx_categories_display_order ON categories(display_order, name)"),
                   "Failed to create categories display_order index:");
}

bool DatabaseManager::createRoutinesTable()
{
    QSqlQuery query(m_db);
    // weekdays 是重复日位掩码（第 0 位周一 … 第 6 位周日），默认「每天」。
    // 它写在 created_at 之后，是为了和 v15 用 ALTER TABLE ADD COLUMN 追加的位置一致：
    // 新建库与升级库的列顺序必须相同，否则任何按位置取值的读法都会在两条路径上分叉。
    const QString createRoutines = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS routines (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL CHECK(length(trim(title)) > 0),
            category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
            active INTEGER NOT NULL DEFAULT 1,
            display_order INTEGER NOT NULL DEFAULT 0,
            last_generated_date TEXT,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            weekdays INTEGER NOT NULL DEFAULT %1 CHECK(weekdays BETWEEN %2 AND %3)
        )
    )SQL")
                                       .arg(RoutineRules::kEveryDayMask)
                                       .arg(RoutineRules::kMinWeekdayMask)
                                       .arg(RoutineRules::kMaxWeekdayMask);
    return execSql(query, createRoutines, "Failed to create routines table:");
}

bool DatabaseManager::createScheduleTables()
{
    QSqlQuery query(m_db);

    // 课表项：按「星期几 + 时段」循环，不锚定具体日期，因此没有 date 也没有 completed 列。
    // week_start/week_end 是生效周次区间（如第 1–8 周），week_parity 是单双周规则。
    // end_minutes > start_minutes 表示课表项不跨零点——课表场景不存在跨夜条目，
    // 用 CHECK 在库层挡住，比在服务层每个写入路径重复判断更可靠。
    const QString createEntries = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS schedule_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL CHECK(length(trim(title)) > 0),
            location TEXT NOT NULL DEFAULT '',
            weekday INTEGER NOT NULL CHECK(weekday BETWEEN 1 AND 7),
            start_minutes INTEGER NOT NULL CHECK(start_minutes BETWEEN 0 AND 1439),
            end_minutes INTEGER NOT NULL CHECK(end_minutes BETWEEN 1 AND 1440),
            week_start INTEGER NOT NULL DEFAULT 1 CHECK(week_start >= 1),
            week_end INTEGER NOT NULL DEFAULT 30 CHECK(week_end >= 1),
            week_parity INTEGER NOT NULL DEFAULT 0 CHECK(week_parity IN (0, 1, 2)),
            category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            CHECK(end_minutes > start_minutes),
            CHECK(week_end >= week_start)
        )
    )SQL");
    if (!execSql(query, createEntries, "Failed to create schedule_entries table:")) {
        return false;
    }

    // 节次预设：课表录入时的快捷填充来源，也是「按节次」显示模式的行定义。
    // period_index 唯一，保证「第 3 节」在全表只有一个时间定义。
    const QString createPeriods = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS schedule_periods (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            period_index INTEGER NOT NULL UNIQUE CHECK(period_index >= 1),
            start_minutes INTEGER NOT NULL CHECK(start_minutes BETWEEN 0 AND 1439),
            end_minutes INTEGER NOT NULL CHECK(end_minutes BETWEEN 1 AND 1440),
            CHECK(end_minutes > start_minutes)
        )
    )SQL");
    return execSql(query, createPeriods, "Failed to create schedule_periods table:");
}

bool DatabaseManager::insertDefaultSchedulePeriods()
{
    QSqlQuery probe(m_db);
    if (!probe.exec(QStringLiteral("SELECT 1 FROM schedule_periods LIMIT 1"))) {
        qWarning() << "Failed to inspect schedule periods:" << probe.lastError().text();
        return false;
    }
    // 表里已经有节次就不再写默认值。用户把节次改过或清空后，
    // 下次启动不能又被默认值填回来——那等于每次启动都撤销一次用户的编辑。
    const bool alreadySeeded = probe.next();
    probe.finish();
    if (alreadySeeded) {
        return true;
    }

    QSqlQuery insert(m_db);
    if (!insert.prepare(QStringLiteral(
            "INSERT INTO schedule_periods (period_index, start_minutes, end_minutes) "
            "VALUES (?, ?, ?)"))) {
        qWarning() << "Failed to prepare default schedule period insert:"
                   << insert.lastError().text();
        return false;
    }
    const QList<QPair<int, int>> defaults = defaultSchedulePeriods();
    for (qsizetype index = 0; index < defaults.size(); ++index) {
        insert.addBindValue(int(index) + 1);
        insert.addBindValue(defaults.at(index).first);
        insert.addBindValue(defaults.at(index).second);
        if (!insert.exec()) {
            qWarning() << "Failed to insert default schedule period:"
                       << insert.lastError().text();
            return false;
        }
    }
    return true;
}

QList<QPair<int, int>> DatabaseManager::defaultSchedulePeriods()
{
    // 默认节次：上午 4 节、下午 4 节、晚上 3 节，每节 45 分钟。
    // 这只是一份能直接用的起始值，用户可在「课表设置」里整表改写。
    return {
        {8 * 60, 8 * 60 + 45},   {8 * 60 + 55, 9 * 60 + 40},   {10 * 60, 10 * 60 + 45},
        {10 * 60 + 55, 11 * 60 + 40}, {14 * 60, 14 * 60 + 45},  {14 * 60 + 55, 15 * 60 + 40},
        {16 * 60, 16 * 60 + 45}, {16 * 60 + 55, 17 * 60 + 40}, {19 * 60, 19 * 60 + 45},
        {19 * 60 + 55, 20 * 60 + 40}, {21 * 60, 21 * 60 + 45},
    };
}

bool DatabaseManager::hasGeneratedIntegerId(const QSqlDatabase& db, const QString& tableName)
{
    // 表名来自内部契约；仍转义标识符，避免未来调用方把外部输入拼进 SQL。
    QString quotedName = tableName;
    quotedName.replace(QLatin1Char('"'), QStringLiteral("\"\""));
    quotedName = QLatin1Char('"') + quotedName + QLatin1Char('"');
    QSqlQuery query(db);
    if (!query.exec(QStringLiteral("PRAGMA table_info(%1)").arg(quotedName))) {
        return false;
    }
    int primaryKeyColumns = 0;
    bool integerId = false;
    while (query.next()) {
        if (query.value(5).toInt() > 0) {
            ++primaryKeyColumns;
            integerId = query.value(1).toString() == QStringLiteral("id")
                && query.value(2).toString().compare(QStringLiteral("INTEGER"), Qt::CaseInsensitive) == 0;
        }
    }
    if (primaryKeyColumns != 1 || !integerId) {
        return false;
    }
    // INT PRIMARY KEY、复合主键、WITHOUT ROWID 和列级 PRIMARY KEY DESC
    // 都不具备所需语义。后两种会创建独立主键索引，而 ROWID 别名不会。
    if (!query.exec(QStringLiteral("PRAGMA index_list(%1)").arg(quotedName))) {
        return false;
    }
    while (query.next()) {
        if (query.value(3).toString() == QStringLiteral("pk")) {
            return false;
        }
    }
    return true;
}

bool DatabaseManager::scheduleSchemaIsValid() const
{
    struct TableContract {
        QString name;
        QStringList columns;
        QStringList sqlFragments;
    };

    const QList<TableContract> contracts = {
        {QStringLiteral("schedule_entries"),
         {QStringLiteral("id"), QStringLiteral("title"), QStringLiteral("location"),
          QStringLiteral("weekday"), QStringLiteral("start_minutes"),
          QStringLiteral("end_minutes"), QStringLiteral("week_start"),
          QStringLiteral("week_end"), QStringLiteral("week_parity"),
          QStringLiteral("category_id"), QStringLiteral("created_at")},
         {QStringLiteral("check(length(trim(title))>0)"),
          QStringLiteral("check(weekdaybetween1and7)"),
          QStringLiteral("check(start_minutesbetween0and1439)"),
          QStringLiteral("check(end_minutesbetween1and1440)"),
          QStringLiteral("check(week_start>=1)"),
          QStringLiteral("check(week_end>=1)"),
          QStringLiteral("check(week_parityin(0,1,2))"),
          QStringLiteral("check(end_minutes>start_minutes)"),
          QStringLiteral("check(week_end>=week_start)")}},
        {QStringLiteral("schedule_periods"),
         {QStringLiteral("id"), QStringLiteral("period_index"),
          QStringLiteral("start_minutes"), QStringLiteral("end_minutes")},
         {QStringLiteral("period_indexintegernotnullunique"),
          QStringLiteral("check(period_index>=1)"),
          QStringLiteral("check(start_minutesbetween0and1439)"),
          QStringLiteral("check(end_minutesbetween1and1440)"),
          QStringLiteral("check(end_minutes>start_minutes)")}},
    };

    for (const TableContract& contract : contracts) {
        if (!hasGeneratedIntegerId(m_db, contract.name)) {
            return false;
        }
        const QStringList actualColumns = tableColumns(contract.name);
        for (const QString& column : contract.columns) {
            if (!actualColumns.contains(column)) {
                return false;
            }
        }

        QSqlQuery sqlQuery(m_db);
        sqlQuery.prepare(QStringLiteral(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = :name"));
        sqlQuery.bindValue(QStringLiteral(":name"), contract.name);
        if (!sqlQuery.exec() || !sqlQuery.next()) {
            return false;
        }
        const QString createSql = normalizedCreateSql(sqlQuery.value(0).toString());
        for (const QString& fragment : contract.sqlFragments) {
            if (!createSql.contains(fragment)) {
                return false;
            }
        }
    }

    QSqlQuery foreignKey(m_db);
    if (!foreignKey.exec(QStringLiteral("PRAGMA foreign_key_list(schedule_entries)"))) {
        return false;
    }
    while (foreignKey.next()) {
        if (foreignKey.value(2).toString() == QStringLiteral("categories")
            && foreignKey.value(3).toString() == QStringLiteral("category_id")
            && foreignKey.value(4).toString() == QStringLiteral("id")
            && foreignKey.value(6).toString().compare(
                   QStringLiteral("SET NULL"), Qt::CaseInsensitive) == 0) {
            return true;
        }
    }
    return false;
}

bool DatabaseManager::routineForeignKeyUsesSetNull(bool* checkSucceeded) const
{
    if (checkSucceeded) {
        *checkSucceeded = false;
    }
    if (!m_db.isOpen()) {
        return false;
    }

    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("PRAGMA foreign_key_list(tasks)"))) {
        qWarning() << "无法读取 tasks 外键定义:" << query.lastError().text();
        return false;
    }
    if (checkSucceeded) {
        *checkSucceeded = true;
    }

    while (query.next()) {
        const QString referencedTable = query.value(2).toString();
        const QString fromColumn = query.value(3).toString();
        const QString onDelete = query.value(6).toString();
        if (referencedTable == QStringLiteral("routines")
            && fromColumn == QStringLiteral("routine_id")) {
            return onDelete.compare(QStringLiteral("SET NULL"), Qt::CaseInsensitive) == 0;
        }
    }
    return false;
}

bool DatabaseManager::insertPresetCategories()
{
    QSqlQuery existingQuery(m_db);
    existingQuery.prepare(QStringLiteral(
        "SELECT 1 FROM categories WHERE is_preset = 1 AND display_order = :displayOrder LIMIT 1"));

    QSqlQuery insertQuery(m_db);
    insertQuery.prepare(QStringLiteral(
        "INSERT OR IGNORE INTO categories (name, color, is_preset, display_order) "
        "VALUES (:name, :color, 1, :displayOrder)"));

    for (int index = 0; index < int(std::size(kPresetCategories)); ++index) {
        const int displayOrder = index + 1;
        existingQuery.bindValue(QStringLiteral(":displayOrder"), displayOrder);
        if (!existingQuery.exec()) {
            qWarning() << "Failed to inspect preset category:" << existingQuery.lastError().text();
            return false;
        }
        if (existingQuery.next()) {
            // display_order 是预设科目的稳定身份。用户可修改名称和颜色，启动时不能按旧名称再复制一行。
            continue;
        }

        insertQuery.bindValue(QStringLiteral(":name"), QString::fromUtf8(kPresetCategories[index].name));
        insertQuery.bindValue(QStringLiteral(":color"), QString::fromLatin1(kPresetCategories[index].color));
        insertQuery.bindValue(QStringLiteral(":displayOrder"), displayOrder);
        if (!insertQuery.exec()) {
            qWarning() << "Failed to insert preset category:" << insertQuery.lastError().text();
            return false;
        }
    }

    return true;
}

bool DatabaseManager::createMemoTable()
{
    QSqlQuery query(m_db);
    // 标题与正文都允许空串，供新建后直接编辑；是否丢弃空白草稿由编辑页决定。
    return execSql(query, QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS memos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL DEFAULT '' CHECK(length(title) <= 60),
            body TEXT NOT NULL DEFAULT '' CHECK(length(body) <= 10000),
            category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
            sort_order INTEGER NOT NULL CHECK(sort_order >= 1),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
    )SQL"), "创建备忘录表失败：");
}

bool DatabaseManager::createTrashTable()
{
    QSqlQuery query(m_db);
    // kind 只要求非空、不限制取值：以后新增类型时，旧版收到（同步或备份）仍能插入并列出，
    // 显示为「需要更新应用才能恢复」，而不是整行写不进去。
    // payload 是删除前的完整内容（JSON，带 v 版本号），引用一律存 sync_id。
    return execSql(query, QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS trash_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL CHECK(length(kind) > 0),
            origin_sync_id TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            payload TEXT NOT NULL,
            deleted_at TEXT NOT NULL
        )
    )SQL"), "创建废纸篓表失败：");
}

bool DatabaseManager::trashSchemaIsValid(const QSqlDatabase& db)
{
    if (!hasGeneratedIntegerId(db, QStringLiteral("trash_items"))) {
        return false;
    }
    const QMap<QString, QString> required = {
        {QStringLiteral("id"), QStringLiteral("INTEGER")},
        {QStringLiteral("kind"), QStringLiteral("TEXT")},
        {QStringLiteral("origin_sync_id"), QStringLiteral("TEXT")},
        {QStringLiteral("title"), QStringLiteral("TEXT")},
        {QStringLiteral("payload"), QStringLiteral("TEXT")},
        {QStringLiteral("deleted_at"), QStringLiteral("TEXT")}
    };
    QSqlQuery query(db);
    if (!query.exec(QStringLiteral("PRAGMA table_info(trash_items)"))) {
        return false;
    }
    QStringList found;
    while (query.next()) {
        const QString column = query.value(1).toString();
        if (!required.contains(column)) {
            continue; // 后续同步迁移添加的列不属于业务结构契约。
        }
        const bool mustBeNotNull = column != QStringLiteral("id");
        if (query.value(2).toString().toUpper() != required.value(column)
            || (query.value(3).toInt() != 0) != mustBeNotNull) {
            return false;
        }
        found.append(column);
    }
    if (found.size() != required.size()) {
        return false;
    }
    if (!query.exec(QStringLiteral("PRAGMA foreign_key_list(trash_items)")) || query.next()) {
        return false;
    }
    if (!query.exec(QStringLiteral("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'trash_items'"))
        || !query.next()) {
        return false;
    }
    return normalizedCreateSql(query.value(0).toString()).contains(QStringLiteral("check(length(kind)>0)"));
}

bool DatabaseManager::memoForeignKeysAreValid(const QSqlDatabase& db)
{
    QSqlQuery query(db);
    if (!query.exec(QStringLiteral("PRAGMA foreign_key_list(memos)")) || !query.next()) {
        return false;
    }
    // 恰好一条单列外键；额外外键、复合外键或 CASCADE 都会改变删科目时保留正文的规则。
    const bool valid = query.value(1).toInt() == 0
        && query.value(2).toString() == QStringLiteral("categories")
        && query.value(3).toString() == QStringLiteral("category_id")
        && query.value(4).toString() == QStringLiteral("id")
        && query.value(6).toString().compare(QStringLiteral("SET NULL"), Qt::CaseInsensitive) == 0;
    return valid && !query.next();
}

bool DatabaseManager::memoSchemaIsValid(const QSqlDatabase& db)
{
    if (!hasGeneratedIntegerId(db, QStringLiteral("memos"))) {
        return false;
    }
    const QMap<QString, QString> required = {
        {QStringLiteral("id"), QStringLiteral("INTEGER")},
        {QStringLiteral("title"), QStringLiteral("TEXT")},
        {QStringLiteral("body"), QStringLiteral("TEXT")},
        {QStringLiteral("category_id"), QStringLiteral("INTEGER")},
        {QStringLiteral("sort_order"), QStringLiteral("INTEGER")},
        {QStringLiteral("created_at"), QStringLiteral("TEXT")},
        {QStringLiteral("updated_at"), QStringLiteral("TEXT")}
    };
    QSqlQuery query(db);
    if (!query.exec(QStringLiteral("PRAGMA table_info(memos)"))) {
        return false;
    }
    QStringList found;
    while (query.next()) {
        const QString column = query.value(1).toString();
        if (!required.contains(column)) {
            continue; // 后续同步迁移添加的列不属于业务结构契约。
        }
        const bool mustBeNotNull = column != QStringLiteral("id") && column != QStringLiteral("category_id");
        if (query.value(2).toString().toUpper() != required.value(column)
            || (query.value(3).toInt() != 0) != mustBeNotNull) {
            return false;
        }
        found.append(column);
    }
    if (found.size() != required.size()) {
        return false;
    }
    if (!query.exec(QStringLiteral("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'memos'"))
        || !query.next()) {
        return false;
    }
    const QString sql = normalizedCreateSql(query.value(0).toString());
    return sql.contains(QStringLiteral("check(length(title)<=60)"))
        && sql.contains(QStringLiteral("check(length(body)<=10000)"))
        && sql.contains(QStringLiteral("check(sort_order>=1)"))
        && memoForeignKeysAreValid(db);
}

bool DatabaseManager::createCountdownGoalsTable()
{
    QSqlQuery query(m_db);
    // 与 CountdownService::initializeDatabase 的结构一致；两边都是 IF NOT EXISTS，谁先建都一样。
    // 只建表：同步迁移要的只是这张表在。排序索引仍由倒计时服务自己建，它坏了只影响倒计时，不挡住整个库打开。
    return execSql(query,
                   QStringLiteral("CREATE TABLE IF NOT EXISTS countdown_goals ("
                                  "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                                  "name TEXT NOT NULL, "
                                  "target_date TEXT NOT NULL, "
                                  "display_order INTEGER NOT NULL, "
                                  "created_at TEXT NOT NULL, "
                                  "updated_at TEXT NOT NULL)"),
                   "Failed to create countdown_goals table:");
}

bool DatabaseManager::syncSchemaIsComplete() const
{
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        if (!columnExists(table.name, QStringLiteral("sync_id"))
            || !indexExists(QStringLiteral("idx_%1_sync_id").arg(table.name))) {
            return false;
        }
    }
    for (const QString& name : SyncSchema::infrastructureTableNames()) {
        if (!tableExists(name)) {
            return false;
        }
    }
    return true;
}

bool DatabaseManager::ensureSyncInfrastructure()
{
    // 平时这里全是空操作（行已存在、索引已存在、触发器与规范一致）；放在一个事务里，
    // 真要重建触发器时「删旧的、建新的」要么都成、要么都不成。
    if (!m_db.transaction()) {
        qWarning() << "Failed to start sync infrastructure check:" << m_db.lastError().text();
        return false;
    }
    QSqlQuery query(m_db);
    for (const QString& sql : SyncSchema::seedStatements() + SyncSchema::indexStatements()) {
        if (!query.exec(sql)) {
            qWarning() << "Failed to ensure sync infrastructure:" << query.lastError().text();
            m_db.rollback();
            return false;
        }
    }
    if (!ensureSyncTriggers() || !m_db.commit()) {
        qWarning() << "Failed to commit sync infrastructure check:" << m_db.lastError().text();
        m_db.rollback();
        return false;
    }
    return true;
}

bool DatabaseManager::ensureSyncTriggers()
{
    const QHash<QString, QString> canonical = SyncSchema::canonicalTriggerSql();
    const QList<QPair<QString, QString>> triggers = SyncSchema::triggers();
    // 规范文本是在临时内存库里建一遍得来的；数目对不上说明那一步失败了，这时宁可启动失败，
    // 也不能拿一份不完整的清单去删、建触发器。
    if (canonical.size() != triggers.size()) {
        qWarning() << "Failed to prepare canonical sync triggers:" << canonical.size() << "of" << triggers.size();
        return false;
    }

    QHash<QString, QString> existing;
    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'"))) {
        qWarning() << "Failed to inspect sync triggers:" << query.lastError().text();
        return false;
    }
    while (query.next()) {
        existing.insert(query.value(0).toString(), query.value(1).toString());
    }
    query.finish();

    // 旧版本留下、现在已经不用的同步触发器一并删掉；别人建的触发器（名字不符合约定）不碰。
    for (auto it = existing.cbegin(); it != existing.cend(); ++it) {
        if (SyncSchema::isSyncTriggerName(it.key()) && !canonical.contains(it.key())
            && !query.exec(QStringLiteral("DROP TRIGGER IF EXISTS \"%1\"").arg(it.key()))) {
            qWarning() << "Failed to drop obsolete sync trigger:" << query.lastError().text();
            return false;
        }
    }
    for (const auto& trigger : triggers) {
        if (existing.value(trigger.first) == canonical.value(trigger.first)) {
            continue;
        }
        // 缺失或内容不一致（旧版本、外部改过）：删掉重建。
        if (!query.exec(QStringLiteral("DROP TRIGGER IF EXISTS \"%1\"").arg(trigger.first))
            || !query.exec(trigger.second)) {
            qWarning() << "Failed to create sync trigger" << trigger.first << query.lastError().text();
            return false;
        }
    }
    return true;
}

bool DatabaseManager::dropForeignSyncTriggers()
{
    const QHash<QString, QString> canonical = SyncSchema::canonicalTriggerSql();
    // 规范文本是在临时内存库里建一遍得来的；数目对不上说明那一步失败了，这时宁可打不开库，
    // 也不能把正常的触发器当成外来的拆掉、或者放过外来的。
    if (canonical.size() != SyncSchema::triggers().size()) {
        qWarning() << "Failed to prepare canonical sync triggers:" << canonical.size() << "of"
                   << SyncSchema::triggers().size();
        return false;
    }
    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'"))) {
        qWarning() << "Failed to inspect sync triggers:" << query.lastError().text();
        return false;
    }
    QStringList foreign;
    while (query.next()) {
        const QString name = query.value(0).toString();
        if (SyncSchema::isSyncTriggerName(name) && canonical.value(name) != query.value(1).toString()) {
            foreign.append(name);
        }
    }
    query.finish();
    for (const QString& name : std::as_const(foreign)) {
        if (!query.exec(QStringLiteral("DROP TRIGGER IF EXISTS \"%1\"").arg(name))) {
            qWarning() << "Failed to drop foreign sync trigger:" << query.lastError().text();
            return false;
        }
    }
    if (!foreign.isEmpty()) {
        qWarning() << "已拆掉内容与本版本不一致的同步触发器，打开库的最后一步会重建：" << foreign;
    }
    return true;
}

bool DatabaseManager::dropSyncTriggersIfSchemaIncomplete()
{
    bool missing = false;
    for (const QString& name : SyncSchema::infrastructureTableNames()) {
        missing = missing || !tableExists(name);
    }
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        if (missing || !tableExists(table.name)) {
            continue;
        }
        const QStringList columns = tableColumns(table.name);
        missing = !columns.contains(QStringLiteral("sync_id"));
        for (const SyncSchema::Field& field : table.fields) {
            missing = missing || !columns.contains(field.column);
        }
    }
    if (!missing) {
        return true;
    }

    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("SELECT name FROM sqlite_master WHERE type = 'trigger'"))) {
        qWarning() << "Failed to inspect sync triggers:" << query.lastError().text();
        return false;
    }
    QStringList names;
    while (query.next()) {
        const QString name = query.value(0).toString();
        if (SyncSchema::isSyncTriggerName(name)) {
            names.append(name);
        }
    }
    query.finish();
    for (const QString& name : names) {
        if (!query.exec(QStringLiteral("DROP TRIGGER IF EXISTS \"%1\"").arg(name))) {
            qWarning() << "Failed to drop sync trigger:" << query.lastError().text();
            return false;
        }
    }
    qWarning() << "同步结构不完整，已先拆掉同步触发器，随后由迁移补齐";
    return true;
}

bool DatabaseManager::createKnowledgeGapTable()
{
    QSqlQuery query(m_db);

    // 知识缺口：专注过程中发现、当下没条件处理、之后要专门腾时间补的条目。
    // 它和 tasks 的分界在于「有没有日期」：tasks.date 是 NOT NULL，而知识缺口的常态
    // 恰恰是「现在还定不了什么时候处理」，所以 due_date 允许为 NULL（= 未排期）。
    //
    // source_task_title 存的是写这条时的现场快照。外键是 ON DELETE SET NULL，
    // 任务被删后 source_task_id 会变空，但「这条是在复习线代第 3 章时记的」这个信息
    // 属于当时的上下文，不该跟着任务一起消失——与 focus_sessions 存科目快照同理。
    //
    // detail 与 resolution 刻意分成两列：前者是「我当时遇到了什么」，后者是
    // 「我后来想明白了什么」。混在一个字段里，回看时分不清哪句是问题哪句是答案。
    const QString createKnowledgeGaps = QStringLiteral(R"SQL(
        CREATE TABLE IF NOT EXISTS knowledge_gaps (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL CHECK(length(trim(title)) > 0),
            detail TEXT NOT NULL DEFAULT '',
            category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
            source_task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL,
            source_task_title TEXT NOT NULL DEFAULT '',
            priority INTEGER NOT NULL DEFAULT 1 CHECK(priority IN (0, 1, 2)),
            status INTEGER NOT NULL DEFAULT 0 CHECK(status IN (0, 1, 2)),
            due_date TEXT,
            resolution TEXT NOT NULL DEFAULT '',
            linked_task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            resolved_at TEXT
        )
    )SQL");
    return execSql(query, createKnowledgeGaps, "Failed to create knowledge_gaps table:");
}

bool DatabaseManager::knowledgeGapSchemaIsValid() const
{
    if (!hasGeneratedIntegerId(m_db, QStringLiteral("knowledge_gaps"))) {
        return false;
    }

    const QStringList requiredColumns = {
        QStringLiteral("id"), QStringLiteral("title"), QStringLiteral("detail"),
        QStringLiteral("category_id"), QStringLiteral("source_task_id"),
        QStringLiteral("source_task_title"), QStringLiteral("priority"),
        QStringLiteral("status"), QStringLiteral("due_date"),
        QStringLiteral("resolution"), QStringLiteral("linked_task_id"),
        QStringLiteral("created_at"), QStringLiteral("updated_at"),
        QStringLiteral("resolved_at")
    };
    const QStringList actualColumns = tableColumns(QStringLiteral("knowledge_gaps"));
    for (const QString& column : requiredColumns) {
        if (!actualColumns.contains(column)) {
            return false;
        }
    }

    QSqlQuery sqlQuery(m_db);
    if (!sqlQuery.exec(QStringLiteral(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'knowledge_gaps'"))
        || !sqlQuery.next()) {
        return false;
    }
    // 状态与优先级的取值域靠库层 CHECK 兜底：服务层虽然也校验，但外部编辑过的库
    // 只有这里能挡住。缺了 CHECK 的表要当作结构不合法，而不是默默接受。
    const QString createSql = normalizedCreateSql(sqlQuery.value(0).toString());
    const QStringList requiredFragments = {
        QStringLiteral("check(length(trim(title))>0)"),
        QStringLiteral("check(priorityin(0,1,2))"),
        QStringLiteral("check(statusin(0,1,2))")
    };
    for (const QString& fragment : requiredFragments) {
        if (!createSql.contains(fragment)) {
            return false;
        }
    }
    return knowledgeGapForeignKeysAreValid(m_db);
}

bool DatabaseManager::knowledgeGapForeignKeysAreValid(const QSqlDatabase& db)
{
    struct ForeignKeyContract {
        QString fromColumn;
        QString referencedTable;
    };
    const QList<ForeignKeyContract> contracts = {
        {QStringLiteral("category_id"), QStringLiteral("categories")},
        {QStringLiteral("source_task_id"), QStringLiteral("tasks")},
        {QStringLiteral("linked_task_id"), QStringLiteral("tasks")},
    };

    QSqlQuery query(db);
    // 每行依次是 id, seq, table, from, to, on_update, on_delete, match。
    // id 是约束编号，seq 是该约束内部的列序号：一条复合外键会用同一个 id 排出 seq 0、1、2……
    if (!query.exec(QStringLiteral("PRAGMA foreign_key_list(knowledge_gaps)"))) {
        return false;
    }

    // 按「恰好等于」而不是「至少包含」校验：同一列再挂一条 CASCADE，或者别的列多一条
    // 指向 tasks 的约束，都会让删除和写入出现契约之外的行为，同样要当作结构不合法。
    //
    // 逐行看 from/to/on_delete 还不够。把两列并成一条
    // FOREIGN KEY (source_task_id, linked_task_id) REFERENCES tasks(id, id) ON DELETE SET NULL，
    // PRAGMA 排出来的每一行都「对」——目标表、目标列、删除动作全部符合契约，只有 id 和 seq
    // 能看出它们其实是同一条约束。代价不是理论上的：tasks 上没有 (id, id) 的复合唯一索引，
    // 这样的库能通过备份校验、能正常启动，但用户新增任何一条知识缺口都会被 SQLite 以
    // foreign key mismatch 拒绝。所以还要求每条约束只管一列（seq 恒为 0）、约束编号互不重复，
    // 也就是三条互相独立的单列外键。
    QStringList matchedColumns;
    QList<int> constraintIds;
    while (query.next()) {
        const int constraintId = query.value(0).toInt();
        const int columnSeq = query.value(1).toInt();
        const QString referencedTable = query.value(2).toString();
        const QString fromColumn = query.value(3).toString();
        const QString toColumn = query.value(4).toString();
        const QString onDelete = query.value(6).toString();

        bool expected = false;
        for (const ForeignKeyContract& contract : contracts) {
            if (contract.fromColumn == fromColumn
                && contract.referencedTable.compare(referencedTable, Qt::CaseInsensitive) == 0) {
                expected = true;
                break;
            }
        }
        if (!expected
            || columnSeq != 0
            || constraintIds.contains(constraintId)
            || toColumn != QStringLiteral("id")
            || onDelete.compare(QStringLiteral("SET NULL"), Qt::CaseInsensitive) != 0
            || matchedColumns.contains(fromColumn)) {
            return false;
        }
        constraintIds.append(constraintId);
        matchedColumns.append(fromColumn);
    }
    return matchedColumns.size() == contracts.size();
}

bool DatabaseManager::ensurePomodoroCycleState()
{
    const bool missingTable = !tableExists(QStringLiteral("pomodoro_cycle_state"));
    // VACUUM 快照必须在事务外、建表前拍下，且复用本次启动只拍一份的守卫。
    if (missingTable && !backupDatabaseBeforeMigration()) {
        return false;
    }
    if (!m_db.transaction()) {
        qWarning() << "无法开始番茄循环状态修补事务" << m_db.lastError().text();
        return false;
    }
    QSqlQuery query(m_db);
    if ((missingTable && !query.exec(pomodoroCycleStateTableSql()))
        || !query.exec(QStringLiteral("SELECT singleton_id, completed_pomodoros, typeof(singleton_id), "
                                      "typeof(completed_pomodoros) FROM pomodoro_cycle_state"))) {
        // 缺列等不可读结构不做猜测性重建；回滚本步，保留原库供用户排查。
        qWarning() << "读取番茄循环状态失败" << query.lastError().text();
        m_db.rollback();
        return false;
    }
    const bool valid = query.next()
        && query.value(2).toString() == QLatin1String("integer") && query.value(0).toLongLong() == 1
        && query.value(3).toString() == QLatin1String("integer")
        && query.value(1).toLongLong() >= 0 && query.value(1).toLongLong() <= 2147483647
        && !query.next();
    if (query.lastError().isValid()) {
        qWarning() << "读取番茄循环状态失败" << query.lastError().text();
        m_db.rollback();
        return false;
    }
    query.finish();
    // 无行、多行、类型或范围错误都只能恢复为单行零计数；清空与补种必须原子提交，
    // 插入或提交失败时不能把旧内容留成已清空的半修补状态。
    const bool repaired = valid || (query.exec(QStringLiteral("DELETE FROM pomodoro_cycle_state"))
        && query.exec(QStringLiteral("INSERT INTO pomodoro_cycle_state (singleton_id, completed_pomodoros) VALUES (1, 0)")));
    if (!repaired || !m_db.commit()) {
        qWarning() << "番茄循环状态修补失败" << query.lastError().text() << m_db.lastError().text();
        m_db.rollback();
        return false;
    }
    if (missingTable) {
        qWarning() << "番茄循环状态表缺失，已补建并将计数重置为 0";
    } else if (!valid) {
        qWarning() << "番茄循环状态缺失或无效，已重置为 0";
    }
    return true;
}

bool DatabaseManager::backupDatabaseBeforeMigration() const
{
    if (m_migrationSnapshotTaken) {
        return true;
    }

    const QString databaseName = m_db.databaseName();
    if (databaseName.isEmpty() || databaseName == QStringLiteral(":memory:")) {
        return true;
    }

    const QFileInfo databaseInfo(databaseName);
    if (!databaseInfo.exists() || !databaseInfo.isFile()) {
        return true;
    }

    const QDir databaseDir = databaseInfo.absoluteDir();
    // UTC 加 Z 标记，避免本地时区变化打乱新旧迁移快照的保留顺序。
    const QString timestamp = QDateTime::currentDateTimeUtc().toString(QStringLiteral("yyyyMMdd_HHmmss_zzz'Z'"));
    QString backupPath = databaseDir.filePath(QStringLiteral("pomodoro_backup_%1.db").arg(timestamp));
    int suffix = 1;
    while (QFileInfo::exists(backupPath)) {
        backupPath = databaseDir.filePath(QStringLiteral("pomodoro_backup_%1_%2.db").arg(timestamp).arg(suffix++));
    }

    // SQLite 的 WAL 文件可能还保存着已提交、但未回写到主库的页。
    // 直接复制 .db 会丢数据，VACUUM INTO 则从当前连接生成一致性快照。
    QString escapedBackupPath = backupPath;
    escapedBackupPath.replace(QLatin1Char('\''), QStringLiteral("''"));
    QSqlQuery snapshotQuery(m_db);
    if (!snapshotQuery.exec(QStringLiteral("VACUUM main INTO '%1'").arg(escapedBackupPath))) {
        QFile::remove(backupPath);
        qWarning() << "Failed to create database migration snapshot:"
                   << backupPath << snapshotQuery.lastError().text();
        return false;
    }

    // 一次启动可能连跨多级迁移。若每级都 VACUUM INTO，保留最近三份的策略
    // 会删掉唯一早于所有破坏性回填的原始快照，还会无意义地逐页重建整库多次。
    m_migrationSnapshotTaken = true;
    pruneOldBackups(databaseDir, backupPath);
    return true;
}

void DatabaseManager::pruneOldBackups(const QDir& databaseDir, const QString& keepPath) const
{
    // 只保留最近三个迁移备份，避免反复测试或启动应用时悄悄塞满数据目录。
    SnapshotRetention::prune(databaseDir, QStringLiteral("pomodoro_backup_*.db"), 3, keepPath);
}

bool DatabaseManager::indexExists(const QString& indexName) const
{
    if (!m_db.isOpen()) {
        return false;
    }

    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("SELECT name FROM sqlite_master WHERE type = 'index' AND name = :name"));
    query.bindValue(QStringLiteral(":name"), indexName);
    if (!query.exec()) {
        qWarning() << "Failed to inspect database index:" << query.lastError().text();
        return false;
    }
    return query.next();
}

bool DatabaseManager::tableExists(const QString& tableName) const
{
    if (!m_db.isOpen()) {
        return false;
    }

    QSqlQuery query(m_db);
    query.prepare(QStringLiteral("SELECT name FROM sqlite_master WHERE type = 'table' AND name = :name"));
    query.bindValue(QStringLiteral(":name"), tableName);
    if (!query.exec()) {
        qWarning() << "Failed to inspect database table:" << query.lastError().text();
        return false;
    }

    return query.next();
}

QStringList DatabaseManager::tableColumns(const QString& tableName) const
{
    QStringList columns;
    if (!m_db.isOpen()) {
        return columns;
    }
    QSqlQuery query(m_db);
    // 表名来自代码内的字面量，不接受外部输入，因此这里直接拼接是安全的
    // （PRAGMA 也不支持绑定参数）。
    if (!query.exec(QStringLiteral("PRAGMA table_info(%1)").arg(tableName))) {
        qWarning() << "无法读取表结构:" << tableName << query.lastError().text();
        return columns;
    }
    while (query.next()) {
        columns.append(query.value(1).toString());
    }
    return columns;
}

bool DatabaseManager::columnExists(const QString& tableName, const QString& columnName) const
{
    if (!m_db.isOpen() || !tableExists(tableName)) {
        return false;
    }

    // PRAGMA table_info 是 SQLite 查看表结构的命令，不能绑定表名，
    // 所以调用方必须传入可信的内部表名。
    QSqlQuery query(m_db);
    if (!query.exec(QStringLiteral("PRAGMA table_info(%1)").arg(tableName))) {
        qWarning() << "Failed to inspect database columns:" << query.lastError().text();
        return false;
    }

    while (query.next()) {
        if (query.value(1).toString() == columnName) {
            return true;
        }
    }

    return false;
}

QSqlDatabase DatabaseManager::database() const
{
    return m_db;
}

bool DatabaseManager::isOpen() const
{
    return m_db.isOpen();
}

bool DatabaseManager::openedExistingDatabase() const
{
    return m_openedExistingDatabase;
}

void DatabaseManager::close()
{
    const QString connectionName = m_connectionName;
    if (m_db.isValid()) {
        m_db.close();
    }
    // removeDatabase() 前必须释放成员句柄。仅 close() 会把命名连接永久留在 Qt 全局池中，
    // 测试换库和应用退出时都可能继续持有旧路径或打印连接仍在使用的警告。
    m_db = QSqlDatabase();
    // 函数静态单例的析构可能晚于 QCoreApplication；Qt SQL 全局注册表此时已不可访问。
    // 正常运行由 aboutToQuit 主动 close，析构路径只做安全兜底。
    if (QCoreApplication::instance() && QSqlDatabase::contains(connectionName)) {
        QSqlDatabase::removeDatabase(connectionName);
    }
}
