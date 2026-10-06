#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSettings>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QTimeZone>
#include <QtTest>

#include <functional>
#include <memory>

#include "../src/services/AppSettings.h"
#include "../src/services/CategoryManager.h"
#include "../src/services/CountdownService.h"
#include "../src/services/DatabaseManager.h"
#include "../src/services/FocusHistoryService.h"
// FocusTimer 声明 friend class SyncTests，用例之间据此复位单例计时器。
#include "../src/services/FocusTimer.h"
#include "../src/services/KnowledgeGapService.h"
#include "../src/services/LogicalDay.h"
#include "../src/services/MemoService.h"
#include "../src/services/RoutineManager.h"
#include "../src/services/RoutineRules.h"
#include "../src/services/ScheduleService.h"
#include "../src/services/SyncNotifier.h"
#include "../src/services/SyncRecord.h"
#include "../src/services/SyncSchema.h"
#include "../src/services/SyncStore.h"
#include "../src/services/TaskManager.h"
#include "../src/services/TrashService.h"

// 设备间同步（050 阶段 2）的测试。
//
// 2a 部分只看一台设备：v18 的表结构，以及本机经由各服务的增删改是否被触发器正确记成
// 「字段版本 + 待发送」。触发器只认数据库里的写入，所以有些用例直接写 SQL，
// 那等于覆盖了所有不经过服务、却同样会写这些表的路径。
//
// 时钟：往 sync_runtime.test_now_ms 写值就能固定「此刻」，再把 sync_state.hlc 拨回 0，
// 版本号就完全由用例决定，不受跑测试时的真实时间影响。
namespace {

QSqlDatabase db()
{
    return DatabaseManager::instance()->database();
}

QVariant scalar(const QString& sql)
{
    QSqlQuery query(db());
    if (!query.exec(sql)) {
        qWarning() << sql << query.lastError().text();
        return {};
    }
    return query.next() ? query.value(0) : QVariant();
}

int count(const QString& sql)
{
    return scalar(sql).toInt();
}

bool exec(const QString& sql)
{
    QSqlQuery query(db());
    if (!query.exec(sql)) {
        qWarning() << sql << query.lastError().text();
        return false;
    }
    return true;
}

// 固定时钟：此后本机改动的逻辑时间 = max(nowMs, 上一次 + 1)。
bool setClock(qint64 nowMs, bool resetLogicalTime = false)
{
    return exec(QStringLiteral("UPDATE sync_runtime SET test_now_ms = %1 WHERE singleton_id = 1").arg(nowMs))
        && (!resetLogicalTime || exec(QStringLiteral("UPDATE sync_state SET value = '0' WHERE key = 'hlc'")));
}

QString deviceId()
{
    return scalar(QStringLiteral("SELECT value FROM sync_state WHERE key = 'device_id'")).toString();
}

QString syncIdOf(const QString& table, int id)
{
    return scalar(QStringLiteral("SELECT sync_id FROM %1 WHERE id = %2").arg(table).arg(id)).toString();
}

struct FieldVersion {
    bool exists = false;
    qint64 time = 0;
    QString device;
    qint64 baseTime = 0;
    QString baseDevice;
    bool pending = false;
};

FieldVersion versionOf(const QString& table, const QString& syncId, const QString& field)
{
    FieldVersion version;
    QSqlQuery query(db());
    query.prepare(QStringLiteral(
        "SELECT v_time, v_device, base_time, base_device, pending FROM sync_field_versions "
        "WHERE tbl = :tbl AND sync_id = :id AND field = :field"));
    query.bindValue(QStringLiteral(":tbl"), table);
    query.bindValue(QStringLiteral(":id"), syncId);
    query.bindValue(QStringLiteral(":field"), field);
    if (query.exec() && query.next()) {
        version.exists = true;
        version.time = query.value(0).toLongLong();
        version.device = query.value(1).toString();
        version.baseTime = query.value(2).toLongLong();
        version.baseDevice = query.value(3).toString();
        version.pending = query.value(4).toInt() == 1;
    }
    return version;
}

int versionCount(const QString& table, const QString& syncId)
{
    return count(QStringLiteral("SELECT COUNT(*) FROM sync_field_versions WHERE tbl = '%1' AND sync_id = '%2'")
                     .arg(table, syncId));
}

bool queued(const QString& table, const QString& syncId)
{
    return count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox WHERE tbl = '%1' AND sync_id = '%2'")
                     .arg(table, syncId)) == 1;
}

QString tombstoneKind(const QString& table, const QString& syncId)
{
    return scalar(QStringLiteral("SELECT kind FROM sync_tombstones WHERE tbl = '%1' AND sync_id = '%2'")
                      .arg(table, syncId)).toString();
}

// 模拟「这批已经写进同步文件」：清空待发送标记。2b 以后由 SyncStore 的确认发送完成，这里先直接改表。
bool markEverythingSent()
{
    return exec(QStringLiteral("UPDATE sync_field_versions SET pending = 0"))
        && exec(QStringLiteral("DELETE FROM sync_outbox"));
}

QHash<QString, QString> triggerSql()
{
    QHash<QString, QString> result;
    QSqlQuery query(db());
    query.exec(QStringLiteral("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'"));
    while (query.next()) {
        result.insert(query.value(0).toString(), query.value(1).toString());
    }
    return result;
}

QDate today()
{
    return LogicalDay::today(AppSettings::instance()->dayStartHour());
}

// ── 两台设备（2b 起） ──
//
// 每台设备一个临时库：先用应用自己的初始化建出完整结构（含 v18 同步表与触发器，各自一个设备标识），
// 再单独开一条连接当作这台设备。本机的增删改大多直接写 SQL：同步只依赖数据库里的触发器，
// 任何写入路径都会被它兜住。需要服务层语义（删除科目、收回例行……）的用例用 withServices 临时切过去。
struct Device {
    QString path;
    QString connection;
    QString id;
};

QSqlDatabase deviceDb(const Device& device)
{
    return QSqlDatabase::database(device.connection);
}

bool exec(const Device& device, const QString& sql)
{
    QSqlQuery query(deviceDb(device));
    if (!query.exec(sql)) {
        qWarning() << sql << query.lastError().text();
        return false;
    }
    return true;
}

QVariant scalar(const Device& device, const QString& sql)
{
    QSqlQuery query(deviceDb(device));
    if (!query.exec(sql)) {
        qWarning() << sql << query.lastError().text();
        return {};
    }
    return query.next() ? query.value(0) : QVariant();
}

int count(const Device& device, const QString& sql)
{
    return scalar(device, sql).toInt();
}

bool setClock(const Device& device, qint64 nowMs)
{
    return exec(device, QStringLiteral("UPDATE sync_runtime SET test_now_ms = %1 WHERE singleton_id = 1").arg(nowMs));
}

// 新建一条任务（排在当天末尾，与服务层一致），返回它的 sync_id。
QString addTask(const Device& device, const QString& title, const QString& date = QStringLiteral("2026-09-30"))
{
    QSqlQuery query(deviceDb(device));
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, date, completed, display_order) VALUES (:title, :date, 0, "
        "(SELECT COALESCE(MAX(display_order), 0) + 1 FROM tasks WHERE date = :orderDate))"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":date"), date);
    query.bindValue(QStringLiteral(":orderDate"), date);
    if (!query.exec()) {
        qWarning() << query.lastError().text();
        return {};
    }
    return scalar(device, QStringLiteral("SELECT sync_id FROM tasks WHERE id = %1")
                              .arg(query.lastInsertId().toLongLong())).toString();
}

QVariant taskValue(const Device& device, const QString& syncId, const QString& column)
{
    return scalar(device, QStringLiteral("SELECT %1 FROM tasks WHERE sync_id = '%2'").arg(column, syncId));
}

QStringList taskTitles(const Device& device)
{
    QStringList titles;
    QSqlQuery query(deviceDb(device));
    query.exec(QStringLiteral("SELECT title FROM tasks ORDER BY title, id"));
    while (query.next()) {
        titles.append(query.value(0).toString());
    }
    return titles;
}

// syncId 为空时由触发器分配随机身份；需要固定「谁并进谁」的用例自己指定身份。
QString addCategory(const Device& device, const QString& name, const QString& syncId = QString())
{
    QSqlQuery query(deviceDb(device));
    query.prepare(QStringLiteral(
        "INSERT INTO categories (name, color, is_preset, display_order, sync_id) "
        "VALUES (:name, '#123456', 0, (SELECT COALESCE(MAX(display_order), 0) + 1 FROM categories), :syncId)"));
    query.bindValue(QStringLiteral(":name"), name);
    query.bindValue(QStringLiteral(":syncId"), syncId.isEmpty() ? QVariant() : QVariant(syncId));
    if (!query.exec()) {
        qWarning() << query.lastError().text();
        return {};
    }
    return scalar(device, QStringLiteral("SELECT sync_id FROM categories WHERE id = %1")
                              .arg(query.lastInsertId().toLongLong())).toString();
}

qint64 localIdOf(const Device& device, const QString& table, const QString& syncId)
{
    return scalar(device, QStringLiteral("SELECT id FROM %1 WHERE sync_id = '%2'").arg(table, syncId)).toLongLong();
}

// 把任务挂到某个科目下（按服务层的写法，同时写科目名文本）。
bool setTaskCategory(const Device& device, const QString& taskSyncId, const QString& categorySyncId)
{
    return exec(device, QStringLiteral(
        "UPDATE tasks SET category_id = c.id, category = c.name FROM categories c "
        "WHERE c.sync_id = '%1' AND tasks.sync_id = '%2'").arg(categorySyncId, taskSyncId));
}

// 任务所属科目的 sync_id（没有科目时为空）。
QString taskCategory(const Device& device, const QString& taskSyncId)
{
    return scalar(device, QStringLiteral("SELECT c.sync_id FROM tasks t LEFT JOIN categories c ON c.id = t.category_id "
                                         "WHERE t.sync_id = '%1'").arg(taskSyncId)).toString();
}

// ── 第二期（051）的三张表 ──

// 新建一条课表项（周一 08:00–08:45，第 1–16 周），返回它的 sync_id。
QString addScheduleEntry(const Device& device, const QString& title, const QString& categorySyncId = QString())
{
    QSqlQuery query(deviceDb(device));
    query.prepare(QStringLiteral(
        "INSERT INTO schedule_entries (title, location, weekday, start_minutes, end_minutes, week_start, week_end, "
        "week_parity, category_id) VALUES (:title, '教一 101', 1, 480, 525, 1, 16, 0, "
        "(SELECT id FROM categories WHERE sync_id = :category))"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":category"), categorySyncId);
    if (!query.exec()) {
        qWarning() << query.lastError().text();
        return {};
    }
    return scalar(device, QStringLiteral("SELECT sync_id FROM schedule_entries WHERE id = %1")
                              .arg(query.lastInsertId().toLongLong())).toString();
}

// 新建一条知识缺口，返回它的 sync_id。科目、来源任务、关联任务都按 sync_id 指定，空串表示不指。
QString addGap(const Device& device, const QString& title, const QString& categorySyncId = QString(),
               const QString& sourceTaskSyncId = QString(), const QString& linkedTaskSyncId = QString())
{
    QSqlQuery query(deviceDb(device));
    query.prepare(QStringLiteral(
        "INSERT INTO knowledge_gaps (title, category_id, source_task_id, source_task_title, linked_task_id, "
        "created_at, updated_at) VALUES (:title, (SELECT id FROM categories WHERE sync_id = :category), "
        "(SELECT id FROM tasks WHERE sync_id = :source), "
        "COALESCE((SELECT title FROM tasks WHERE sync_id = :sourceTitle), ''), "
        "(SELECT id FROM tasks WHERE sync_id = :linked), '2026-09-30T08:00:00', '2026-09-30T08:00:00')"));
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":category"), categorySyncId);
    query.bindValue(QStringLiteral(":source"), sourceTaskSyncId);
    query.bindValue(QStringLiteral(":sourceTitle"), sourceTaskSyncId);
    query.bindValue(QStringLiteral(":linked"), linkedTaskSyncId);
    if (!query.exec()) {
        qWarning() << query.lastError().text();
        return {};
    }
    return scalar(device, QStringLiteral("SELECT sync_id FROM knowledge_gaps WHERE id = %1")
                              .arg(query.lastInsertId().toLongLong())).toString();
}

// 新建一个倒计时，返回它的 sync_id。
QString addCountdown(const Device& device, const QString& name, int displayOrder, const QString& createdAt)
{
    QSqlQuery query(deviceDb(device));
    query.prepare(QStringLiteral(
        "INSERT INTO countdown_goals (name, target_date, display_order, created_at, updated_at) "
        "VALUES (:name, '2027-01-10', :order, :created, :created)"));
    query.bindValue(QStringLiteral(":name"), name);
    query.bindValue(QStringLiteral(":order"), displayOrder);
    query.bindValue(QStringLiteral(":created"), createdAt);
    if (!query.exec()) {
        qWarning() << query.lastError().text();
        return {};
    }
    return scalar(device, QStringLiteral("SELECT sync_id FROM countdown_goals WHERE id = %1")
                              .arg(query.lastInsertId().toLongLong())).toString();
}

QVariant valueOf(const Device& device, const QString& table, const QString& syncId, const QString& column)
{
    return scalar(device, QStringLiteral("SELECT %1 FROM %2 WHERE sync_id = '%3'").arg(column, table, syncId));
}

// 052：用真实触发器生成版本；固定创建时间和身份，使排序能抓住误用本机 id 的实现。
QString addMemo(const Device& device, const QString& title, const QString& body,
                const QString& category = QString(), const QString& identity = QString())
{
    QSqlQuery query(deviceDb(device));
    query.prepare(QStringLiteral(
        "INSERT INTO memos(title,body,category_id,sort_order,created_at,updated_at,sync_id) "
        "VALUES(:title,:body,(SELECT id FROM categories WHERE sync_id=:cat),"
        "(SELECT COALESCE(MAX(sort_order),0)+1 FROM memos WHERE category_id IS "
        "(SELECT id FROM categories WHERE sync_id=:cat2)),"
        "'2026-10-02T12:51:46.728Z','2026-10-02T12:51:46.728Z',:identity)"));
    query.bindValue(QStringLiteral(":title"), title.isNull() ? QStringLiteral("") : title);
    query.bindValue(QStringLiteral(":body"), body);
    query.bindValue(QStringLiteral(":cat"), category);
    query.bindValue(QStringLiteral(":cat2"), category);
    query.bindValue(QStringLiteral(":identity"), identity.isEmpty() ? QVariant() : QVariant(identity));
    if (!query.exec()) {
        qWarning() << query.lastError().text();
        return {};
    }
    return scalar(device, QStringLiteral("SELECT sync_id FROM memos WHERE id=%1")
                              .arg(query.lastInsertId().toLongLong())).toString();
}

QString memoCategory(const Device& device, const QString& id)
{
    return scalar(device, QStringLiteral("SELECT c.sync_id FROM memos m LEFT JOIN categories c "
                                         "ON c.id=m.category_id WHERE m.sync_id='%1'").arg(id)).toString();
}

QString memoStamp(qint64 milliseconds)
{
    return QDateTime::fromMSecsSinceEpoch(milliseconds, QTimeZone::UTC).toString(Qt::ISODateWithMs);
}

SyncRecord memoRecord(const SyncBatch& batch, const QString& identity)
{
    for (const SyncRecord& record : batch.records) {
        if (record.table == QLatin1String("memos") && record.syncId == identity) {
            return record;
        }
    }
    return {};
}

// 倒计时按界面的顺序（排序号、本机编号）排出来的名字与排序号。
QStringList countdownOrder(const Device& device)
{
    QStringList order;
    QSqlQuery query(deviceDb(device));
    query.exec(QStringLiteral("SELECT name, display_order FROM countdown_goals ORDER BY display_order, id"));
    while (query.next()) {
        order.append(QStringLiteral("%1:%2").arg(query.value(1).toInt()).arg(query.value(0).toString()));
    }
    return order;
}

QStringList customCategoryNames(const Device& device)
{
    QStringList names;
    QSqlQuery query(deviceDb(device));
    query.exec(QStringLiteral("SELECT name FROM categories WHERE is_preset = 0 ORDER BY name"));
    while (query.next()) {
        names.append(query.value(0).toString());
    }
    return names;
}

// 一天里的任务按显示顺序排出来的 sync_id，比较两台设备的顺序是否一致。
QStringList dayOrder(const Device& device, const QString& date)
{
    QStringList ids;
    QSqlQuery query(deviceDb(device));
    query.exec(QStringLiteral("SELECT sync_id FROM tasks WHERE date = '%1' ORDER BY completed, display_order, id")
                   .arg(date));
    while (query.next()) {
        ids.append(query.value(0).toString());
    }
    return ids;
}

// ── 054：废纸篓（两台设备共用）──

// 同步字段的列名：逐列比较两台设备上的同一行。
const QStringList kTrashColumns = {QStringLiteral("kind"), QStringLiteral("origin_sync_id"),
                                   QStringLiteral("title"), QStringLiteral("payload"),
                                   QStringLiteral("deleted_at")};

int trashRows(const Device& device)
{
    return count(device, QStringLiteral("SELECT COUNT(*) FROM trash_items"));
}

// 标题为 title 的那一行在这台设备上的本机编号，没有则为 0。
int trashIdOf(const Device& device, const QString& title)
{
    return scalar(device, QStringLiteral("SELECT id FROM trash_items WHERE title = '%1'").arg(title)).toInt();
}

QString trashValue(const Device& device, const QString& trashSyncId, const QString& column)
{
    return scalar(device, QStringLiteral("SELECT %1 FROM trash_items WHERE sync_id = '%2'")
                              .arg(column, trashSyncId)).toString();
}

// 废纸篓里全部标题，排好序，比较「到底剩下哪几项」用。
QStringList trashTitles(const Device& device)
{
    QStringList titles;
    QSqlQuery query(deviceDb(device));
    query.exec(QStringLiteral("SELECT title FROM trash_items"));
    while (query.next()) {
        titles.append(query.value(0).toString());
    }
    titles.sort();
    return titles;
}

// 废纸篓的完整内容（身份加全部同步字段），每行一条、排好序：两台设备一模一样就说明废纸篓整体一致。
QStringList trashDump(const Device& device)
{
    QStringList lines;
    QSqlQuery query(deviceDb(device));
    query.exec(QStringLiteral("SELECT sync_id, kind, origin_sync_id, title, payload, deleted_at FROM trash_items"));
    while (query.next()) {
        QStringList parts;
        for (int column = 0; column < 6; ++column) {
            parts.append(query.value(column).toString());
        }
        lines.append(parts.join(QLatin1Char('|')));
    }
    lines.sort();
    return lines;
}

// 直接写一行废纸篓记录（走 SQL，触发器照常补身份、版本和待发送），返回它的 sync_id。
QString addTrashRow(const Device& device, const QString& kind, const QString& origin, const QString& title,
                    const QString& payload, const QString& deletedAt)
{
    QSqlQuery query(deviceDb(device));
    query.prepare(QStringLiteral("INSERT INTO trash_items (kind, origin_sync_id, title, payload, deleted_at) "
                                 "VALUES (:kind, :origin, :title, :payload, :deletedAt)"));
    query.bindValue(QStringLiteral(":kind"), kind);
    query.bindValue(QStringLiteral(":origin"), origin);
    query.bindValue(QStringLiteral(":title"), title);
    query.bindValue(QStringLiteral(":payload"), payload);
    query.bindValue(QStringLiteral(":deletedAt"), deletedAt);
    if (!query.exec()) {
        qWarning() << query.lastError().text();
        return {};
    }
    return scalar(device, QStringLiteral("SELECT sync_id FROM trash_items WHERE id = %1")
                              .arg(query.lastInsertId().toLongLong())).toString();
}

// 把某一行废纸篓记录的「现在」定在它的逻辑删除日再过 days 天的中午，给 TrashService::setNowForTesting 用。
// 删除时刻是写入那一刻的系统时间，测试没法注入，所以「到期与否」只能靠拨「现在」来造：
// days = 30 时这一行刚好到期（D+30 清掉），days = 29 时还剩 1 天。
QDateTime trashNowAfter(const Device& device, const QString& trashSyncId, int days)
{
    const QDateTime deletedAt = QDateTime::fromString(trashValue(device, trashSyncId, QStringLiteral("deleted_at")),
                                                      Qt::ISODateWithMs);
    const QDate day = LogicalDay::dateOf(deletedAt.toLocalTime(), AppSettings::instance()->dayStartHour());
    return QDateTime(day.addDays(days), QTime(12, 0));
}

// 把一份快照写成可比较的文字：每条记录一行，字段按名字排序，带上值和版本（不带 base，它只影响日志）。
// 两台设备导出的快照文字相同，就说明它们的同步数据完全一致。
QStringList describe(const SyncBatch& snapshot)
{
    QStringList lines;
    for (const SyncRecord& record : snapshot.records) {
        QStringList parts{record.table, record.syncId};
        if (record.deleted) {
            parts << QStringLiteral("deleted:%1:%2@%3/%4")
                         .arg(record.deleteKind, record.mergedInto)
                         .arg(record.deleteVersion.time)
                         .arg(record.deleteVersion.device);
        }
        QStringList fields = record.fields.keys();
        fields.sort();
        for (const QString& field : fields) {
            const SyncFieldValue value = record.fields.value(field);
            parts << QStringLiteral("%1=%2@%3/%4")
                         .arg(field, SyncJson::canonicalValue(value.value))
                         .arg(value.version.time)
                         .arg(value.version.device);
        }
        lines << parts.join(QLatin1Char('|'));
    }
    for (const SyncSettingRecord& setting : snapshot.settings) {
        lines << QStringLiteral("setting|%1=%2@%3/%4")
                     .arg(setting.key, setting.value)
                     .arg(setting.version.time)
                     .arg(setting.version.device);
    }
    lines.sort();
    return lines;
}

// 快照经过一次 JSON：写进云盘文件再读回来，确认文件格式带得全。
SyncBatch throughJson(const SyncBatch& batch)
{
    SyncBatch parsed;
    QString error;
    const QByteArray bytes = QJsonDocument(SyncJson::toJson(batch)).toJson(QJsonDocument::Compact);
    if (!SyncJson::fromJson(QJsonDocument::fromJson(bytes).object(), &parsed, &error)) {
        qWarning() << "snapshot json failed:" << error;
    }
    return parsed;
}

// 按发生顺序记下各服务发出的刷新信号。它是连接的上下文对象，析构时连接自动断开，不会漏到别的用例。
class SignalRecorder : public QObject
{
public:
    QStringList events;

    SignalRecorder()
    {
        connect(TaskManager::instance(), &TaskManager::taskDeleted, this,
                [this](int taskId) { events << QStringLiteral("taskDeleted:%1").arg(taskId); });
        connect(TaskManager::instance(), &TaskManager::tasksChanged, this,
                [this] { events << QStringLiteral("tasksChanged"); });
        connect(CategoryManager::instance(), &CategoryManager::categoriesChanged, this,
                [this] { events << QStringLiteral("categoriesChanged"); });
        connect(RoutineManager::instance(), &RoutineManager::routinesChanged, this,
                [this] { events << QStringLiteral("routinesChanged"); });
        connect(FocusHistoryService::instance(), &FocusHistoryService::historyChanged, this,
                [this] { events << QStringLiteral("historyChanged"); });
        connect(AppSettings::instance(), &AppSettings::dayStartHourChanged, this,
                [this] { events << QStringLiteral("dayStartHourChanged"); });
        connect(ScheduleService::instance(), &ScheduleService::scheduleChanged, this,
                [this] { events << QStringLiteral("scheduleChanged"); });
        connect(KnowledgeGapService::instance(), &KnowledgeGapService::gapsChanged, this,
                [this] { events << QStringLiteral("gapsChanged"); });
        connect(CountdownService::instance(), &CountdownService::goalsReloaded, this,
                [this] { events << QStringLiteral("goalsReloaded"); });
    }
};

// 对方（另一台设备）发来的一条删除记录。
SyncRecord remoteDeletion(const QString& table, const QString& syncId, const SyncVersion& version)
{
    SyncRecord record;
    record.table = table;
    record.syncId = syncId;
    record.deleted = true;
    record.deleteVersion = version;
    record.deleteKind = QStringLiteral("delete");
    return record;
}

int logCount(const Device& device, const QString& kind = QString())
{
    return kind.isEmpty() ? count(device, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log"))
                          : count(device, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log WHERE kind = '%1'")
                                              .arg(kind));
}

// 假云盘：临时文件夹。每台设备只写自己的子目录 devices/<设备>/changes/<序号>.json（与正式方案同一布局），
// 读对方目录里本机还没应用过的文件。游标记在内存里，改它就能模拟「确认丢了、再读一遍」。
class FakeCloud
{
public:
    explicit FakeCloud(QString root) : m_root(std::move(root)) {}

    // 把这台设备的待发送改动写成一个文件并确认发送，返回写出的记录数。
    int publish(const Device& device)
    {
        SyncStore store(device.connection);
        const SyncBatch batch = store.collectPending();
        if (batch.isEmpty()) {
            return 0;
        }
        const QString dir = QStringLiteral("%1/devices/%2/changes").arg(m_root, batch.device);
        QDir().mkpath(dir);
        const int sequence = ++m_sequence[batch.device];
        QFile file(QStringLiteral("%1/%2.json").arg(dir).arg(sequence, 8, 10, QLatin1Char('0')));
        if (!file.open(QIODevice::WriteOnly)) {
            return -1;
        }
        file.write(QJsonDocument(SyncJson::toJson(batch)).toJson(QJsonDocument::Compact));
        file.close();
        return store.acknowledge(batch) ? int(batch.records.size() + batch.settings.size()) : -1;
    }

    // 按序应用对方写出、本机还没应用过的文件。某个文件应用失败就停在那里，下次从它重试。
    QList<SyncStore::ApplyResult> pull(const Device& device)
    {
        SyncStore store(device.connection);
        QList<SyncStore::ApplyResult> results;
        const QDir devices(m_root + QStringLiteral("/devices"));
        for (const QString& source : devices.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name)) {
            if (source == device.id) {
                continue;
            }
            const QDir changes(devices.filePath(source + QStringLiteral("/changes")));
            for (const QString& name : changes.entryList({QStringLiteral("*.json")}, QDir::Files, QDir::Name)) {
                const int sequence = name.section(QLatin1Char('.'), 0, 0).toInt();
                if (sequence <= m_cursor[device.id].value(source)) {
                    continue;
                }
                QFile file(changes.filePath(name));
                SyncBatch batch;
                QString error = QStringLiteral("读不开同步文件");
                if (!file.open(QIODevice::ReadOnly)
                    || !SyncJson::fromJson(QJsonDocument::fromJson(file.readAll()).object(), &batch, &error)) {
                    SyncStore::ApplyResult failed;
                    failed.error = error;
                    results.append(failed);
                    break;
                }
                const SyncStore::ApplyResult result = store.applyRemote(batch);
                results.append(result);
                if (!result.ok) {
                    break;
                }
                m_cursor[device.id][source] = sequence;
            }
        }
        return results;
    }

    // 模拟「应用了但确认丢了」（断线、被系统挂起）：把 reader 对 source 的游标退回，下次会重读这些文件。
    void rewind(const Device& reader, const Device& source, int sequence = 0)
    {
        m_cursor[reader.id][source.id] = sequence;
    }

private:
    QString m_root;
    QHash<QString, int> m_sequence;
    QHash<QString, QHash<QString, int>> m_cursor;
};

} // namespace

class SyncTests : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void cleanup();

    // 2a：表结构与触发器
    void freshDatabaseHasSyncInfrastructure();
    void serviceWritesAreVersionedPerField();
    void logicalClockNeverGoesBackwards();
    void presetCategoriesUseSlotIdentityAndMinimalVersions();
    void routineInstanceUsesDeterministicIdentityAndMinimalVersions();
    void focusSessionIsPublishedOnlyAfterItEnds();
    void applyingRemoteChangesSuppressesTriggers();
    void migrationFromV17BackfillsIdentitiesAndQueuesRecords();
    void v5RebuildKeepsSyncIdsAndDoesNotRequeue();
    void tamperedTriggerIsRebuiltOnStartup();
    void foreignSyncTriggerIsDroppedBeforeMigrationsWrite();
    void missingSyncTableDoesNotBlockStartup();

    // 2b：读出与应用（两台设备）
    void batchSurvivesJsonRoundTrip();
    void insertUpdateDeleteReachOtherDevice();
    void editsOfDifferentFieldsAreBothKept();
    void fieldLevelEditKeepsOtherDevicesChanges();
    void concurrentEditsOfSameFieldConvergeAndAreLogged();
    void sequentialEditsAcrossDevicesAreNotConflicts();
    void deleteWinsOverConcurrentEdit_deleteArrivesFirst();
    void deleteWinsOverConcurrentEdit_editArrivesFirst();
    void concurrentCreatesStayTwoRecords();
    void redeliveredBatchesChangeNothing();
    void editDuringSendIsNotLost();
    void causalEditWinsDespiteClockSkew();
    void sameLogicalTimeConvergesByDevice();
    void badRecordIsSkippedWithoutBlockingBatch();
    void remoteTaskDeletionKeepsItsSessions();
    void runningSessionIsNeverSent();
    void batchFromOtherEpochOrSameDeviceIsRejected();

    // 2c：引用与去重（sol6 审查复现过的卡死、冲突场景）
    void sessionOnRemotelyDeletedTaskIsKeptDetached();
    void taskUnderRemotelyDeletedCategoryBecomesUncategorized();
    void renamedCategoryThenRecreatedNameSyncs();
    void renameCollidingWithOtherSidesNewCategoryMerges();
    void sameNameCategoriesCreatedOnBothSidesMerge();
    void swappedCategoryNamesAreNotMerged();
    void mergeReachesSideThatDidNotCollide();
    void presetsRenamedToSameNameGetSuffix();
    void sameDayTasksAreRenumberedWithoutMigration();
    void corruptMergeChainDoesNotHang();

    // 2d：例行与逻辑日起点
    void reclaimedInstanceIsSoftDeletedAndRegenerates();
    void bothDevicesGenerateOneInstanceAndKeepCompletion();
    void remoteReclaimKeepsTouchedInstanceOnBothSides();
    void republishedInstanceOutranksAFastClocksReclaim();
    void regeneratedInstanceReachesOtherDevice();
    void userDeletedInstanceStaysDeletedOnBothDevices();
    void userDeletionOutranksConcurrentReclaimOnBothDevices();
    void dayStartHourSyncsWithDefaultsAndLatestWins();
    void referenceArrivingBeforeItsTargetIsRelinked();
    void derivedEmptyReferenceIsNotSentBack();
    void pendingReferenceRelinksWhenTargetIsRegeneratedLocally();
    void gapLinkToReclaimedInstanceComesBackOnBothDevices();
    void pendingReferenceTravelsAsItsTarget();

    // 2e：快照、首次加入与全局回滚
    void firstJoinReplacesJoiningDeviceWithSnapshot();
    void globalRollbackReplacesOtherDeviceAndRejectsOldEpoch();
    void publishedSnapshotAcknowledgesQueuedChanges();

    // 2f：提交后的精确通知
    void notificationsFollowChangedTablesInOrder();
    void failedApplyPublishesNothing();
    void remoteDeletionUnbindsRunningTimer();

    // 051 阶段 1：课表、知识缺口、目标倒计时按条目同步
    void phaseTwoTablesTravelWithLocalReferences();
    void phaseTwoConcurrentEditsMergeFieldByField();
    void deletedTaskDetachesKnowledgeGaps();
    void deletedCategoryClearsScheduleAndGapCategories();
    void countdownOrderConvergesAfterConcurrentInserts();
    void phaseTwoNotificationsRefreshOnlyTheirServices();
    void migrationFromV18QueuesPhaseTwoRows();

    // 051 阶段 2：设置
    void snapshotReplacementReportsSettingsItLacks();
    void settingConflictsReadAsPlainText();

    // 052 阶段 2：产品保证写在各用例的第一行，前置断言防止数据没有触发目标场景。
    void memosTravelWithContentTimeAndNullableCategory();
    void memoEditsMergeAndKeepFullLosingBody();
    void memoSortingAndLosingEditsKeepContentTime();
    void memoCategoryEditsAdvanceContentTime();
    void memoDeletionWinsAndPreservesLosingBody();
    void memoDeletedElsewhereKeepsCopyWithoutCallingItConflict();
    void memoOrderCollisionsConverge_data();
    void memoOrderCollisionsConverge();
    void memoCategoryDeletionKeepsConcurrentContent();
    void memoCategoryMergeRepointsOnBothPaths();
    void memoSnapshotsPreserveContentTimeDuringJoinAndRollback();
    void memoPendingCategoryRelinksWithoutEcho();
    void phaseOneV20MemosAcquireSyncWithoutVersionBump();
    void memoNotificationsCoverContentAndCategoryDeletion();

    // 054 阶段 2：废纸篓两台共用。产品保证写在各用例的第一行，前置断言防止数据没有触发目标场景。
    void trashDeletedOnOneDeviceAppearsOnTheOtherWithoutBeingWrittenTwice();
    void trashRestoredOnOneDeviceCreatesTheRecordOnTheOtherAndClearsBothTrashes();
    void trashDeleteItemAndEmptyTrashFollowToTheOtherDevice();
    void trashBothDevicesDeletingTheSameRecordListsOneAndRestoresOnce();
    void trashExpiryPurgeConvergesWhetherBothDevicesOrOnlyOneExpireIt();
    void trashChangesFromSyncNotifyTheTrashPage();
    void phaseOneV21TrashAcquiresSyncWithoutVersionBump();
    void trashSnapshotsReplaceTheTrashOnJoinAndRollback();

private:
    Device openDevice(const QString& name);
    // 临时把服务层（TaskManager 等单例）切到这台设备的库上执行一段操作，用完关掉。
    void withServices(const Device& device, const std::function<void()>& action);
    // 两台设备来回同步，直到一轮下来谁也没有新改动要发。
    void syncAll(FakeCloud& cloud, const QList<Device>& devices);

    // 废纸篓用例的公共起点：A 建一个自定义科目和带它的任务，同步之后两台都有；
    // B 先占一个科目编号，让同一个科目在两台设备上的本机编号不同（废纸篓的内容只能靠 sync_id 对应）。
    struct TrashScenario {
        Device a;
        Device b;
        QString category; // 科目的 sync_id
        QString task;     // 任务的 sync_id（A 上建的）
    };
    void setUpTrashScenario(FakeCloud& cloud, const QString& title, TrashScenario* scenario);
    // 经服务层在 device 上建任务 / 删任务：删除要走 TaskManager::deleteTask 才会写废纸篓。
    QString createTaskOn(const Device& device, const QString& title, const QString& categorySyncId,
                         int estimatedMinutes, const QString& notes);
    void deleteTaskOn(const Device& device, const QString& taskSyncId);
    // 在 device 上把「现在」定在 now 再清理过期项，返回清掉的条数；用完还原。
    int purgeExpiredOn(const Device& device, const QDateTime& now);

    QTemporaryDir m_preferences;
    std::unique_ptr<QTemporaryDir> m_data;
    QStringList m_connections;
};

void SyncTests::initTestCase()
{
    QVERIFY(m_preferences.isValid());
    // AppSettings 单例只落到临时 INI：例行生成要读日界点，不能读写真实偏好。
    QCoreApplication::setOrganizationName(QStringLiteral("PomodoroTodoSyncTests"));
    QCoreApplication::setApplicationName(QStringLiteral("SyncTests"));
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, m_preferences.path());
    AppSettings::instance()->setDayStartHour(4);
}

void SyncTests::init()
{
    m_data = std::make_unique<QTemporaryDir>();
    QVERIFY(m_data->isValid());
    QVERIFY(DatabaseManager::instance()->initialize(m_data->filePath(QStringLiteral("sync.sqlite"))));
}

void SyncTests::cleanup()
{
    // 单例计时器与设置跨用例共享：复位，免得上一条用例的计时或逻辑日起点漏到下一条。
    // TrashService 也是单例，废纸篓用例会把它的「现在」拨到几十天后来造到期项，这里必须还原。
    FocusTimer::instance()->resetSession();
    AppSettings::instance()->setDayStartHour(4);
    TrashService::instance()->setNowForTesting(QDateTime());
    DatabaseManager::instance()->close();
    for (const QString& connection : m_connections) {
        {
            QSqlDatabase database = QSqlDatabase::database(connection);
            database.close();
        }
        QSqlDatabase::removeDatabase(connection);
    }
    m_connections.clear();
    m_data.reset();
}

Device SyncTests::openDevice(const QString& name)
{
    Device device;
    device.path = m_data->filePath(name + QStringLiteral(".sqlite"));
    if (!DatabaseManager::instance()->initialize(device.path)) {
        qWarning() << "initialize failed" << device.path;
    }
    DatabaseManager::instance()->close();
    device.connection = QStringLiteral("sync-device-") + name;
    QSqlDatabase database = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), device.connection);
    database.setDatabaseName(device.path);
    database.open();
    QSqlQuery(database).exec(QStringLiteral("PRAGMA foreign_keys = ON"));
    QSqlQuery(database).exec(QStringLiteral("PRAGMA busy_timeout = 5000"));
    m_connections.append(device.connection);
    device.id = SyncStore(device.connection).deviceId();
    return device;
}

void SyncTests::withServices(const Device& device, const std::function<void()>& action)
{
    QVERIFY(DatabaseManager::instance()->initialize(device.path));
    action();
    DatabaseManager::instance()->close();
}

void SyncTests::syncAll(FakeCloud& cloud, const QList<Device>& devices)
{
    // 应用对方的改动之后本机可能产生新的改动（例如排序归一），所以要来回几轮，直到安静下来。
    for (int round = 0; round < 6; ++round) {
        int published = 0;
        for (const Device& device : devices) {
            published += cloud.publish(device);
        }
        for (const Device& device : devices) {
            for (const SyncStore::ApplyResult& result : cloud.pull(device)) {
                QVERIFY2(result.ok, qPrintable(result.error));
            }
        }
        if (published == 0) {
            return;
        }
    }
    QFAIL("来回同步六轮后仍有新改动，没有收敛");
}

void SyncTests::setUpTrashScenario(FakeCloud& cloud, const QString& title, TrashScenario* scenario)
{
    scenario->a = openDevice(QStringLiteral("trash-a"));
    scenario->b = openDevice(QStringLiteral("trash-b"));
    // B 先占一个科目编号：A 建的科目同步到 B 之后，在 B 上拿到的本机编号就和在 A 上的不同。
    QVERIFY(!addCategory(scenario->b, QStringLiteral("B 先建的科目")).isEmpty());
    scenario->category = addCategory(scenario->a, QStringLiteral("线性代数"));
    QVERIFY(!scenario->category.isEmpty());
    scenario->task = createTaskOn(scenario->a, title, scenario->category, 45, QStringLiteral("第二遍"));
    QVERIFY(!scenario->task.isEmpty());
    syncAll(cloud, {scenario->a, scenario->b});
    // 前提：B 也有这个科目和这条任务，而且同一个科目在两台设备上的本机编号不同；两台的废纸篓都是空的。
    QVERIFY(localIdOf(scenario->b, QStringLiteral("categories"), scenario->category) > 0);
    QVERIFY(localIdOf(scenario->b, QStringLiteral("tasks"), scenario->task) > 0);
    QVERIFY(localIdOf(scenario->a, QStringLiteral("categories"), scenario->category)
            != localIdOf(scenario->b, QStringLiteral("categories"), scenario->category));
    QCOMPARE(trashRows(scenario->a), 0);
    QCOMPARE(trashRows(scenario->b), 0);
}

QString SyncTests::createTaskOn(const Device& device, const QString& title, const QString& categorySyncId,
                                int estimatedMinutes, const QString& notes)
{
    QString syncId;
    withServices(device, [&] {
        const qint64 categoryId = categorySyncId.isEmpty()
            ? -1 : localIdOf(device, QStringLiteral("categories"), categorySyncId);
        const int id = TaskManager::instance()->createTask(title, today(), static_cast<int>(categoryId),
                                                           estimatedMinutes, notes);
        QVERIFY(id > 0);
        syncId = syncIdOf(QStringLiteral("tasks"), id);
    });
    return syncId;
}

void SyncTests::deleteTaskOn(const Device& device, const QString& taskSyncId)
{
    const qint64 localId = localIdOf(device, QStringLiteral("tasks"), taskSyncId);
    QVERIFY2(localId > 0, "要删的任务不在这台设备上");
    withServices(device, [&] { QVERIFY(TaskManager::instance()->deleteTask(static_cast<int>(localId))); });
}

int SyncTests::purgeExpiredOn(const Device& device, const QDateTime& now)
{
    int purged = -2;
    withServices(device, [&] {
        TrashService::instance()->setNowForTesting(now);
        purged = TrashService::instance()->purgeExpired();
        TrashService::instance()->setNowForTesting(QDateTime());
    });
    return purged;
}

void SyncTests::freshDatabaseHasSyncInfrastructure()
{
    QCOMPARE(scalar(QStringLiteral("PRAGMA user_version")).toInt(), DatabaseManager::kCurrentSchemaVersion);
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        QVERIFY2(count(QStringLiteral("SELECT COUNT(*) FROM pragma_table_info('%1') WHERE name = 'sync_id'")
                           .arg(table.name)) == 1, qPrintable(table.name));
        QVERIFY2(count(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' "
                                      "AND name = 'idx_%1_sync_id'").arg(table.name)) == 1,
                 qPrintable(table.name));
    }
    for (const QString& name : SyncSchema::infrastructureTableNames()) {
        QVERIFY2(count(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '%1'")
                           .arg(name)) == 1, qPrintable(name));
    }

    // 设备标识是 32 位小写十六进制；纪元从 0 开始；运行标记默认「不在应用远端改动」。
    QVERIFY(QRegularExpression(QStringLiteral("^[0-9a-f]{32}$")).match(deviceId()).hasMatch());
    QCOMPARE(scalar(QStringLiteral("SELECT value FROM sync_state WHERE key = 'epoch'")).toString(),
             QStringLiteral("0"));
    QVERIFY(scalar(QStringLiteral("SELECT value FROM sync_state WHERE key = 'hlc'")).toLongLong() > 0);
    QCOMPARE(scalar(QStringLiteral("SELECT applying FROM sync_runtime WHERE singleton_id = 1")).toInt(), 0);

    // 库里的触发器恰好是规范的那一组，文本逐字一致。
    const QHash<QString, QString> canonical = SyncSchema::canonicalTriggerSql();
    QCOMPARE(canonical.size(), SyncSchema::triggers().size());
    QCOMPARE(triggerSql(), canonical);
}

void SyncTests::serviceWritesAreVersionedPerField()
{
    QVERIFY(setClock(1000, true));
    const QString me = deviceId();
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("写论文"), today(), -1, 30,
                                                           QStringLiteral("第一章"));
    QVERIFY(taskId > 0);
    const QString id = syncIdOf(QStringLiteral("tasks"), taskId);
    QVERIFY(QRegularExpression(QStringLiteral("^[0-9a-f]{32}$")).match(id).hasMatch());

    // 新建：每个同步列一行版本，都是这一次的逻辑时间和本机，等着发出去。
    const SyncSchema::Table* tasks = SyncSchema::table(QStringLiteral("tasks"));
    QVERIFY(tasks);
    QCOMPARE(versionCount(QStringLiteral("tasks"), id), int(tasks->fields.size()));
    for (const SyncSchema::Field& field : tasks->fields) {
        const FieldVersion version = versionOf(QStringLiteral("tasks"), id, field.column);
        QVERIFY2(version.time == 1000 && version.device == me && version.pending, qPrintable(field.column));
        QCOMPARE(version.baseTime, 0);
    }
    QVERIFY(queued(QStringLiteral("tasks"), id));

    // 发出去之后只改标题：只有标题记新版本，base 记下对方已经见过的那一版；其余列不动。
    QVERIFY(markEverythingSent());
    QVERIFY(setClock(2000));
    QVERIFY(TaskManager::instance()->updateTask(taskId, QStringLiteral("写论文（第二稿）"), -1, today()));
    FieldVersion title = versionOf(QStringLiteral("tasks"), id, QStringLiteral("title"));
    QCOMPARE(title.time, 2000);
    QCOMPARE(title.baseTime, 1000);
    QCOMPARE(title.baseDevice, me);
    QVERIFY(title.pending);
    const FieldVersion notes = versionOf(QStringLiteral("tasks"), id, QStringLiteral("notes"));
    QCOMPARE(notes.time, 1000);
    QVERIFY(!notes.pending);
    QVERIFY(queued(QStringLiteral("tasks"), id));

    // 还没发出去又改一次：对方见过的仍是 1000 那一版，base 保持不动。
    QVERIFY(setClock(3000));
    QVERIFY(TaskManager::instance()->updateTask(taskId, QStringLiteral("写论文（第三稿）"), -1, today()));
    title = versionOf(QStringLiteral("tasks"), id, QStringLiteral("title"));
    QCOMPARE(title.time, 3000);
    QCOMPARE(title.baseTime, 1000);

    // 值没变的更新（同一天内再「改期」到同一天）不产生新版本。
    QVERIFY(markEverythingSent());
    QVERIFY(TaskManager::instance()->moveTasksToDate({taskId}, today()));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), 0);

    // 删除：留下删除记录（普通删除），版本行清掉，记录重新进待发送队列。
    // 删除任务的同一个事务里先把它写进废纸篓（计划 054）：那一行用掉逻辑时间 4000，
    // 任务的删除记录紧接着取 4001。两者都在同一次删除里，顺序是先废纸篓、后删除记录。
    QVERIFY(setClock(4000));
    QVERIFY(TaskManager::instance()->deleteTask(taskId));
    QCOMPARE(tombstoneKind(QStringLiteral("tasks"), id), QStringLiteral("delete"));
    QCOMPARE(scalar(QStringLiteral("SELECT v_time FROM sync_tombstones WHERE sync_id = '%1'").arg(id)).toLongLong(),
             4001);
    const QString trashSyncId =
        scalar(QStringLiteral("SELECT sync_id FROM trash_items WHERE origin_sync_id = '%1'").arg(id)).toString();
    QVERIFY(!trashSyncId.isEmpty());
    QCOMPARE(versionOf(QStringLiteral("trash_items"), trashSyncId, QStringLiteral("kind")).time, 4000);
    QCOMPARE(versionCount(QStringLiteral("tasks"), id), 0);
    QVERIFY(queued(QStringLiteral("tasks"), id));
}

void SyncTests::logicalClockNeverGoesBackwards()
{
    QVERIFY(setClock(5000, true));
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("时钟"), today(), -1, 0, QString());
    QVERIFY(taskId > 0);
    const QString id = syncIdOf(QStringLiteral("tasks"), taskId);
    QCOMPARE(versionOf(QStringLiteral("tasks"), id, QStringLiteral("title")).time, 5000);

    // 系统时钟被往回拨：新版本仍然排在旧版本后面（取「上一次 + 1」），不会因为改了钟就输给自己的旧值。
    QVERIFY(setClock(100));
    QVERIFY(TaskManager::instance()->setTaskCompleted(taskId, true));
    QCOMPARE(versionOf(QStringLiteral("tasks"), id, QStringLiteral("completed")).time, 5001);
    QVERIFY(TaskManager::instance()->setTaskCompleted(taskId, false));
    QCOMPARE(versionOf(QStringLiteral("tasks"), id, QStringLiteral("completed")).time, 5002);
}

void SyncTests::presetCategoriesUseSlotIdentityAndMinimalVersions()
{
    // 两台设备建库时各自预置同一组科目：按位置取身份，版本取最小值，谁也不覆盖谁改过的名字。
    for (int slot = 1; slot <= 5; ++slot) {
        const QString id = SyncSchema::presetCategorySyncId(slot);
        QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM categories WHERE is_preset = 1 "
                                      "AND display_order = %1 AND sync_id = '%2'").arg(slot).arg(id)), 1);
        const FieldVersion name = versionOf(QStringLiteral("categories"), id, QStringLiteral("name"));
        QVERIFY(name.exists);
        QCOMPARE(name.time, 0);
        QCOMPARE(name.device, QString());
    }

    // 改名是真实修改，用真实版本；自定义科目用随机身份和真实版本。
    QVERIFY(setClock(7000, true));
    const int mathId = scalar(QStringLiteral("SELECT id FROM categories WHERE sync_id = 'preset-1'")).toInt();
    QVERIFY(CategoryManager::instance()->updateCategory(mathId, QStringLiteral("高等数学"),
                                                        QStringLiteral("#d4a574")));
    const FieldVersion renamed = versionOf(QStringLiteral("categories"), QStringLiteral("preset-1"),
                                           QStringLiteral("name"));
    QCOMPARE(renamed.time, 7000);
    QCOMPARE(renamed.device, deviceId());
    QCOMPARE(versionOf(QStringLiteral("categories"), QStringLiteral("preset-1"), QStringLiteral("color")).time, 0);

    const int customId = CategoryManager::instance()->addCategory(QStringLiteral("编程"), QStringLiteral("#123456"));
    QVERIFY(customId > 0);
    const QString custom = syncIdOf(QStringLiteral("categories"), customId);
    QVERIFY(QRegularExpression(QStringLiteral("^[0-9a-f]{32}$")).match(custom).hasMatch());
    QCOMPARE(versionOf(QStringLiteral("categories"), custom, QStringLiteral("name")).time, 7001);
}

void SyncTests::routineInstanceUsesDeterministicIdentityAndMinimalVersions()
{
    QVERIFY(setClock(9000, true));
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
    const QString routine = scalar(QStringLiteral("SELECT sync_id FROM routines WHERE title = '背单词'")).toString();
    QVERIFY(!routine.isEmpty());

    QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    const int taskId = scalar(QStringLiteral("SELECT id FROM tasks WHERE routine_generated = 1")).toInt();
    const QString id = syncIdOf(QStringLiteral("tasks"), taskId);
    // 两台设备各自生成的同一天实例，身份相同。
    QCOMPARE(id, SyncSchema::routineInstanceSyncId(routine, today().toString(Qt::ISODate)));
    // 生成出来的默认值版本取最小值：另一台上已经完成的同一条不会被这份盖掉。
    const SyncSchema::Table* tasks = SyncSchema::table(QStringLiteral("tasks"));
    for (const SyncSchema::Field& field : tasks->fields) {
        const FieldVersion version = versionOf(QStringLiteral("tasks"), id, field.column);
        QVERIFY2(version.exists && version.time == 0 && version.device.isEmpty(), qPrintable(field.column));
    }
    // 仍然要发出去：另一台那天没打开过应用，就只能靠这一份补上当天的实例。
    QVERIFY(queued(QStringLiteral("tasks"), id));

    // 在实例上的真实操作用真实版本，赢过另一台生成的默认值。
    QVERIFY(TaskManager::instance()->setTaskCompleted(taskId, true));
    QVERIFY(versionOf(QStringLiteral("tasks"), id, QStringLiteral("completed")).time > 9000);
    QCOMPARE(versionOf(QStringLiteral("tasks"), id, QStringLiteral("title")).time, 0);
}

void SyncTests::focusSessionIsPublishedOnlyAfterItEnds()
{
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("专注"), today(), -1, 0, QString());
    QVERIFY(taskId > 0);
    QVERIFY(markEverythingSent());

    // 开始专注时落库的那一行：有身份，但不记版本、不进队列。它只属于本机的计时器。
    QVERIFY(exec(QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, mode) "
                                "VALUES (%1, '2026-09-30T10:00:00', 1)").arg(taskId)));
    const int running = scalar(QStringLiteral("SELECT MAX(id) FROM focus_sessions")).toInt();
    const QString runningId = syncIdOf(QStringLiteral("focus_sessions"), running);
    QVERIFY(!runningId.isEmpty());
    QCOMPARE(versionCount(QStringLiteral("focus_sessions"), runningId), 0);
    QVERIFY(!queued(QStringLiteral("focus_sessions"), runningId));

    // 丢弃或清理进行中的行（FocusTimer 的 discard 与孤儿清理都是这样删的）：不留删除记录。
    // 对方从来没见过它，发一条删除过去没有意义。
    QVERIFY(exec(QStringLiteral("DELETE FROM focus_sessions WHERE id = %1").arg(running)));
    QVERIFY(tombstoneKind(QStringLiteral("focus_sessions"), runningId).isEmpty());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), 0);

    // 结束的那一刻（FocusTimer 一条 UPDATE 写结束时刻、时长和完整番茄）才整条发布。
    QVERIFY(exec(QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, mode) "
                                "VALUES (%1, '2026-09-30T11:00:00', 1)").arg(taskId)));
    const int finished = scalar(QStringLiteral("SELECT MAX(id) FROM focus_sessions")).toInt();
    const QString finishedId = syncIdOf(QStringLiteral("focus_sessions"), finished);
    QVERIFY(setClock(12000, true));
    QVERIFY(exec(QStringLiteral("UPDATE focus_sessions SET end_time = '2026-09-30T11:25:00', duration = 1500, "
                                "pomodoro_completed = 1 WHERE id = %1").arg(finished)));
    const SyncSchema::Table* sessions = SyncSchema::table(QStringLiteral("focus_sessions"));
    QCOMPARE(versionCount(QStringLiteral("focus_sessions"), finishedId), int(sessions->fields.size()));
    QCOMPARE(versionOf(QStringLiteral("focus_sessions"), finishedId, QStringLiteral("task_id")).time, 12000);
    QVERIFY(queued(QStringLiteral("focus_sessions"), finishedId));

    // 之后在历史里改时长：只记这一列。
    QVERIFY(markEverythingSent());
    QVERIFY(setClock(13000));
    QVERIFY(exec(QStringLiteral("UPDATE focus_sessions SET duration = 1200 WHERE id = %1").arg(finished)));
    QCOMPARE(versionOf(QStringLiteral("focus_sessions"), finishedId, QStringLiteral("duration")).time, 13000);
    QCOMPARE(versionOf(QStringLiteral("focus_sessions"), finishedId, QStringLiteral("start_time")).time, 12000);

    // 删掉已结束的记录：留删除记录，发给对方。
    QVERIFY(exec(QStringLiteral("DELETE FROM focus_sessions WHERE id = %1").arg(finished)));
    QCOMPARE(tombstoneKind(QStringLiteral("focus_sessions"), finishedId), QStringLiteral("delete"));

    // 休息记录落库时就是完整的，立即发布。
    QVERIFY(exec(QStringLiteral("INSERT INTO rest_sessions (start_time, end_time, duration, manual) "
                                "VALUES ('2026-09-30T11:25:00', '2026-09-30T11:30:00', 300, 0)")));
    const QString restId = syncIdOf(QStringLiteral("rest_sessions"),
                                    scalar(QStringLiteral("SELECT MAX(id) FROM rest_sessions")).toInt());
    QCOMPARE(versionCount(QStringLiteral("rest_sessions"), restId), 4);
    QVERIFY(queued(QStringLiteral("rest_sessions"), restId));
}

void SyncTests::applyingRemoteChangesSuppressesTriggers()
{
    QVERIFY(markEverythingSent());
    // 应用远端改动时同一事务里置位：收到的改动不能被当成本机修改再发回去。
    QVERIFY(exec(QStringLiteral("UPDATE sync_runtime SET applying = 1 WHERE singleton_id = 1")));
    QVERIFY(exec(QStringLiteral("INSERT INTO tasks (title, date, completed, display_order, sync_id) "
                                "VALUES ('远端来的', '2026-09-30', 0, 1, 'remote-task')")));
    QVERIFY(exec(QStringLiteral("UPDATE tasks SET title = '远端改的' WHERE sync_id = 'remote-task'")));
    QVERIFY(exec(QStringLiteral("DELETE FROM tasks WHERE sync_id = 'remote-task'")));
    QVERIFY(exec(QStringLiteral("UPDATE sync_runtime SET applying = 0 WHERE singleton_id = 1")));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_field_versions WHERE sync_id = 'remote-task'")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_tombstones")), 0);
}

void SyncTests::migrationFromV17BackfillsIdentitiesAndQueuesRecords()
{
    // 用当前代码建出数据，再把同步结构整个拆掉、版本号退回 17，就是一份 v17 的库。
    const QString date = today().toString(Qt::ISODate);
    const int englishId = scalar(QStringLiteral("SELECT id FROM categories WHERE sync_id = 'preset-2'")).toInt();
    QVERIFY(CategoryManager::instance()->updateCategory(englishId, QStringLiteral("英语阅读"),
                                                        QStringLiteral("#c9956e")));
    const int customId = CategoryManager::instance()->addCategory(QStringLiteral("编程"), QStringLiteral("#123456"));
    QVERIFY(customId > 0);
    QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), customId, RoutineRules::kEveryDayMask));
    QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("写代码"), today(), customId, 0, QString());
    QVERIFY(exec(QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                "VALUES (%1, '%2T09:00:00', '%2T09:25:00', 1500, 1)").arg(taskId).arg(date)));
    QVERIFY(exec(QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, mode) "
                                "VALUES (%1, '%2T10:00:00', 1)").arg(taskId).arg(date)));
    QVERIFY(exec(QStringLiteral("INSERT INTO rest_sessions (start_time, end_time, duration, manual) "
                                "VALUES ('%1T09:25:00', '%1T09:30:00', 300, 0)").arg(date)));

    for (const auto& trigger : SyncSchema::triggers()) {
        QVERIFY(exec(QStringLiteral("DROP TRIGGER %1").arg(trigger.first)));
    }
    for (const QString& name : SyncSchema::infrastructureTableNames()) {
        QVERIFY(exec(QStringLiteral("DROP TABLE %1").arg(name)));
    }
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        QVERIFY(exec(QStringLiteral("DROP INDEX idx_%1_sync_id").arg(table.name)));
        QVERIFY(exec(QStringLiteral("ALTER TABLE %1 DROP COLUMN sync_id").arg(table.name)));
    }
    QVERIFY(exec(QStringLiteral("PRAGMA user_version = 17")));

    const QDir dir = QFileInfo(db().databaseName()).absoluteDir();
    const QStringList pattern{QStringLiteral("pomodoro_backup_*.db")};
    const qsizetype snapshotsBefore = dir.entryList(pattern, QDir::Files).size();
    QVERIFY(DatabaseManager::instance()->createTables());

    // 升级前留了一份快照：v18 之后旧版本应用打不开这个库，想退回只能靠它。一路升到当前版本。
    QCOMPARE(dir.entryList(pattern, QDir::Files).size(), snapshotsBefore + 1);
    QCOMPARE(scalar(QStringLiteral("PRAGMA user_version")).toInt(), DatabaseManager::kCurrentSchemaVersion);
    QCOMPARE(triggerSql(), SyncSchema::canonicalTriggerSql());

    // 每一行都有身份，且互不相同。
    for (const SyncSchema::Table& table : SyncSchema::tables()) {
        QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM %1 WHERE sync_id IS NULL OR sync_id = ''")
                           .arg(table.name)), 0);
        QCOMPARE(count(QStringLiteral("SELECT COUNT(DISTINCT sync_id) FROM %1").arg(table.name)),
                 count(QStringLiteral("SELECT COUNT(*) FROM %1").arg(table.name)));
    }

    // 预置科目按位置取固定身份。没改过的名字版本取最小值；改过的（英语 → 英语阅读）用真实版本，
    // 同步时才不会被另一台上没改过的默认名盖掉。
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM categories WHERE sync_id LIKE 'preset-%'")), 5);
    QCOMPARE(versionOf(QStringLiteral("categories"), QStringLiteral("preset-1"), QStringLiteral("name")).time, 0);
    QVERIFY(versionOf(QStringLiteral("categories"), QStringLiteral("preset-2"), QStringLiteral("name")).time > 0);
    QCOMPARE(versionOf(QStringLiteral("categories"), QStringLiteral("preset-2"), QStringLiteral("color")).time, 0);

    // 例行实例按「例行身份 + 日期」回填。
    const QString routine = scalar(QStringLiteral("SELECT sync_id FROM routines")).toString();
    QCOMPARE(scalar(QStringLiteral("SELECT sync_id FROM tasks WHERE routine_generated = 1")).toString(),
             SyncSchema::routineInstanceSyncId(routine, date));

    // 首次全量发送：发布条件满足的记录全部入队；进行中的专注不入队、也没有版本。
    const int published = count(QStringLiteral("SELECT COUNT(*) FROM categories"))
        + count(QStringLiteral("SELECT COUNT(*) FROM routines")) + count(QStringLiteral("SELECT COUNT(*) FROM tasks"))
        + count(QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE end_time IS NOT NULL"))
        + count(QStringLiteral("SELECT COUNT(*) FROM rest_sessions"));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), published);
    const QString running = scalar(QStringLiteral("SELECT sync_id FROM focus_sessions WHERE end_time IS NULL")).toString();
    QVERIFY(!queued(QStringLiteral("focus_sessions"), running));
    QCOMPARE(versionCount(QStringLiteral("focus_sessions"), running), 0);

    // 升级后本机的修改照常记版本。
    QVERIFY(markEverythingSent());
    QVERIFY(TaskManager::instance()->setTaskCompleted(taskId, true));
    QVERIFY(queued(QStringLiteral("tasks"), syncIdOf(QStringLiteral("tasks"), taskId)));
}

void SyncTests::v5RebuildKeepsSyncIdsAndDoesNotRequeue()
{
    const int first = TaskManager::instance()->createTask(QStringLiteral("第一条"), today(), -1, 0, QString());
    const int second = TaskManager::instance()->createTask(QStringLiteral("第二条"), today(), -1, 0, QString());
    QVERIFY(first > 0 && second > 0);
    const QString firstId = syncIdOf(QStringLiteral("tasks"), first);
    const QString secondId = syncIdOf(QStringLiteral("tasks"), second);
    QVERIFY(markEverythingSent());

    // 版本号拨回 4 会触发 v5 整表重建（createTables 的结构守卫同样会在外键不对时触发它）。
    QVERIFY(exec(QStringLiteral("PRAGMA user_version = 4")));
    QVERIFY(DatabaseManager::instance()->createTables());

    // 身份原样搬过去；唯一索引和触发器被重建带走后又补了回来。
    QCOMPARE(syncIdOf(QStringLiteral("tasks"), first), firstId);
    QCOMPARE(syncIdOf(QStringLiteral("tasks"), second), secondId);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_tasks_sync_id'")), 1);
    QCOMPARE(triggerSql(), SyncSchema::canonicalTriggerSql());
    // 早已发出去的记录不会因为重跑 v18 再整库排一遍队。
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), 0);

    QVERIFY(TaskManager::instance()->setTaskCompleted(first, true));
    QVERIFY(queued(QStringLiteral("tasks"), firstId));
}

void SyncTests::tamperedTriggerIsRebuiltOnStartup()
{
    // 触发器被换成空壳（旧版本留下的、或外部改过的）：启动时按规范文本比较，不一致就重建。
    QVERIFY(exec(QStringLiteral("DROP TRIGGER tasks_sync_au")));
    QVERIFY(exec(QStringLiteral("CREATE TRIGGER tasks_sync_au AFTER UPDATE ON tasks BEGIN SELECT 1; END")));
    QVERIFY(exec(QStringLiteral("CREATE TRIGGER tasks_sync_obsolete AFTER DELETE ON tasks BEGIN SELECT 1; END")));
    QVERIFY(exec(QStringLiteral("CREATE TRIGGER someone_elses AFTER DELETE ON tasks BEGIN SELECT 1; END")));
    QVERIFY(DatabaseManager::instance()->createTables());

    QHash<QString, QString> expected = SyncSchema::canonicalTriggerSql();
    // 不符合本应用命名约定的触发器不归我们管，原样留着。
    expected.insert(QStringLiteral("someone_elses"), triggerSql().value(QStringLiteral("someone_elses")));
    QCOMPARE(triggerSql(), expected);
    QVERIFY(exec(QStringLiteral("DROP TRIGGER someone_elses")));

    const int taskId = TaskManager::instance()->createTask(QStringLiteral("重建后"), today(), -1, 0, QString());
    QVERIFY(markEverythingSent());
    QVERIFY(TaskManager::instance()->setTaskCompleted(taskId, true));
    QVERIFY(queued(QStringLiteral("tasks"), syncIdOf(QStringLiteral("tasks"), taskId)));
}

void SyncTests::foreignSyncTriggerIsDroppedBeforeMigrationsWrite()
{
    // 恢复备份时，名字是同步触发器、内容却不是本应用这一版的（更早版本写的，或伪造的）不再整份拒绝，
    // 打开库时换成本应用自己的。前提是它在被换掉之前不能执行：迁移链会写业务表（例如排序号坏了要重排），
    // 那时它若还挂着，就会带着伪造的内容跑一遍。所以必须在任何迁移写入之前先拆掉它。
    QVERIFY(exec(QStringLiteral("INSERT INTO categories (name, color, is_preset, display_order) "
                                "VALUES ('物理', '#123456', 0, 6)")));
    // 同一天两条任务排序号相同：打开库时迁移链会重跑 v12，把任务表重排一遍（会触发更新触发器）。
    QVERIFY(exec(QStringLiteral("INSERT INTO tasks (title, date, completed, display_order) "
                                "VALUES ('甲', '2026-09-30', 0, 1), ('乙', '2026-09-30', 0, 1)")));
    QVERIFY(exec(QStringLiteral("DROP TRIGGER tasks_sync_au")));
    QVERIFY(exec(QStringLiteral("CREATE TRIGGER tasks_sync_au AFTER UPDATE ON tasks "
                                "BEGIN DELETE FROM categories WHERE is_preset = 0; END")));

    QVERIFY(DatabaseManager::instance()->createTables());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM categories WHERE name = '物理'")), 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(DISTINCT display_order) FROM tasks WHERE date = '2026-09-30'")), 2);
    QCOMPARE(triggerSql(), SyncSchema::canonicalTriggerSql());
}

void SyncTests::missingSyncTableDoesNotBlockStartup()
{
    // 删掉一个预置科目（按远端改动的方式，不留删除记录），再拆掉待发送队列表：
    // 下次启动时，迁移链前面会补回预置科目——触发器此时若还在，就会因为队列表不存在而让启动失败。
    // 应用远端删除时同步核心会连同版本行一起清掉，这里照做，否则残留的版本会让迁移以为它早已发过。
    QVERIFY(exec(QStringLiteral("UPDATE sync_runtime SET applying = 1 WHERE singleton_id = 1")));
    QVERIFY(exec(QStringLiteral("DELETE FROM categories WHERE sync_id = 'preset-5'")));
    QVERIFY(exec(QStringLiteral("DELETE FROM sync_field_versions WHERE sync_id = 'preset-5'")));
    QVERIFY(exec(QStringLiteral("UPDATE sync_runtime SET applying = 0 WHERE singleton_id = 1")));
    QVERIFY(exec(QStringLiteral("DROP TABLE sync_outbox")));

    QTest::ignoreMessage(QtWarningMsg, "同步结构不完整，已先拆掉同步触发器，随后由迁移补齐");
    QVERIFY(DatabaseManager::instance()->createTables());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM categories WHERE sync_id = 'preset-5'")), 1);
    QCOMPARE(triggerSql(), SyncSchema::canonicalTriggerSql());
    // 补回来的预置科目仍按默认值处理：版本取最小值，并照常入队。
    QCOMPARE(versionOf(QStringLiteral("categories"), QStringLiteral("preset-5"), QStringLiteral("name")).time, 0);
    QVERIFY(queued(QStringLiteral("categories"), QStringLiteral("preset-5")));
}

// ── 2b：读出与应用 ──
//
// 需要决定「谁的修改更晚」的用例，把时钟拨到远超真实时间的值（约 2096 年）：
// 逻辑时间取 max(此刻, 上一次 + 1)，拨得足够大，版本就完全由用例决定。
namespace {
constexpr qint64 kFuture = 4000000000000LL;
}

void SyncTests::batchSurvivesJsonRoundTrip()
{
    SyncBatch batch;
    batch.device = QStringLiteral("device-a");
    batch.epoch = 3;
    SyncRecord live;
    live.table = QStringLiteral("tasks");
    live.syncId = QStringLiteral("task-1");
    live.fields.insert(QStringLiteral("title"),
                       {QStringLiteral("写论文"), {1000, QStringLiteral("device-a")}, {500, QStringLiteral("device-b")}});
    live.fields.insert(QStringLiteral("completed"), {qint64(1), {1001, QStringLiteral("device-a")}, {}});
    live.fields.insert(QStringLiteral("category_id"), {QVariant(), {1002, QStringLiteral("device-a")}, {}});
    SyncRecord gone;
    gone.table = QStringLiteral("categories");
    gone.syncId = QStringLiteral("category-1");
    gone.deleted = true;
    gone.deleteVersion = {2000, QStringLiteral("device-a")};
    gone.deleteKind = QStringLiteral("merge");
    gone.mergedInto = QStringLiteral("category-0");
    batch.records = {live, gone};
    batch.settings = {{QStringLiteral("logic/dayStartHour"), QStringLiteral("5"), {3000, QStringLiteral("device-a")}, {}}};

    const QByteArray bytes = QJsonDocument(SyncJson::toJson(batch)).toJson();
    SyncBatch parsed;
    QString error;
    QVERIFY2(SyncJson::fromJson(QJsonDocument::fromJson(bytes).object(), &parsed, &error), qPrintable(error));
    QCOMPARE(parsed.device, batch.device);
    QCOMPARE(parsed.epoch, qint64(3));
    QCOMPARE(parsed.records.size(), 2);
    const SyncRecord& task = parsed.records.at(0);
    QCOMPARE(task.fields.size(), 3);
    for (const QString& field : {QStringLiteral("title"), QStringLiteral("completed"), QStringLiteral("category_id")}) {
        QCOMPARE(SyncJson::canonicalValue(task.fields.value(field).value),
                 SyncJson::canonicalValue(live.fields.value(field).value));
        QVERIFY(task.fields.value(field).version == live.fields.value(field).version);
    }
    QVERIFY(task.fields.value(QStringLiteral("title")).base == live.fields.value(QStringLiteral("title")).base);
    const SyncRecord& category = parsed.records.at(1);
    QVERIFY(category.deleted);
    QVERIFY(category.deleteVersion == gone.deleteVersion);
    QCOMPARE(category.deleteKind, QStringLiteral("merge"));
    QCOMPARE(category.mergedInto, QStringLiteral("category-0"));
    QCOMPARE(parsed.settings.size(), 1);
    QCOMPARE(parsed.settings.first().value, QStringLiteral("5"));

    // 更新的版本写出的文件：拒绝，而不是按旧含义去猜。
    QJsonObject future = SyncJson::toJson(batch);
    future.insert(QStringLiteral("format"), SyncJson::kFormatVersion + 1);
    QVERIFY(!SyncJson::fromJson(future, &parsed, &error));
    QVERIFY(!error.isEmpty());

    // 计划 054 起写出格式 4（052 起是 3），旧应用停下等更新；第一期的格式 1 仍能读，比它更旧的不认识。
    QCOMPARE(SyncJson::toJson(batch).value(QStringLiteral("format")).toInt(), 4);
    QJsonObject firstPhase = SyncJson::toJson(batch);
    firstPhase.insert(QStringLiteral("format"), 1);
    SyncBatch old;
    QVERIFY2(SyncJson::fromJson(firstPhase, &old, &error), qPrintable(error));
    QCOMPARE(old.records.size(), 2);
    firstPhase.insert(QStringLiteral("format"), 0);
    QVERIFY(!SyncJson::fromJson(firstPhase, &old, &error));
}

void SyncTests::insertUpdateDeleteReachOtherDevice()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    syncAll(cloud, {a, b});

    const QString id = addTask(a, QStringLiteral("买菜"));
    syncAll(cloud, {a, b});
    QCOMPARE(taskValue(b, id, QStringLiteral("title")).toString(), QStringLiteral("买菜"));
    // 应用收到的改动不会反过来进 B 的待发送队列（触发器在应用期间跳过）。
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), 0);

    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '买菜和水果' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});
    QCOMPARE(taskValue(b, id, QStringLiteral("title")).toString(), QStringLiteral("买菜和水果"));

    QVERIFY(exec(a, QStringLiteral("DELETE FROM tasks WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(id)), 0);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM sync_tombstones WHERE sync_id = '%1'").arg(id)), 1);
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::editsOfDifferentFieldsAreBothKept()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("写论文"));
    syncAll(cloud, {a, b});

    // 两台都离线，各改一个字段：合并后两处修改都在，而且不算冲突。
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '写论文（第二稿）' WHERE sync_id = '%1'").arg(id)));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET notes = '第三章' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});
    for (const Device& device : {a, b}) {
        QCOMPARE(taskValue(device, id, QStringLiteral("title")).toString(), QStringLiteral("写论文（第二稿）"));
        QCOMPARE(taskValue(device, id, QStringLiteral("notes")).toString(), QStringLiteral("第三章"));
    }
    QCOMPARE(logCount(a) + logCount(b), 0);
}

// 产品保证：编辑弹窗只写用户改过的字段。弹窗开着时另一台改了同一条的备注和日期，这边只改标题后保存，
// 两台上留下的都是「这边的标题 + 另一台的备注和日期」，也不算冲突。
// 抓住的错误实现：按弹窗打开时的快照整条写回，把另一台刚改的备注、日期盖回打开时的旧值，并同步回去。
void SyncTests::fieldLevelEditKeepsOtherDevicesChanges()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("写论文"));
    syncAll(cloud, {a, b});
    const int localId = static_cast<int>(localIdOf(a, QStringLiteral("tasks"), id));
    QVERIFY(localId > 0);

    // A 打开编辑弹窗，读到的备注是空的、日期是原来的。
    QVariantMap opened;
    withServices(a, [&] { opened = TaskManager::instance()->readTask(localId).value; });
    QCOMPARE(opened.value(QStringLiteral("notes")).toString(), QString());
    QCOMPARE(opened.value(QStringLiteral("date")).toString(), QStringLiteral("2026-09-30"));

    // 弹窗开着时，B 改了备注和日期，并且已经同步到 A。
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET notes = '第三章', date = '2026-10-02' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});
    QCOMPARE(taskValue(a, id, QStringLiteral("notes")).toString(), QStringLiteral("第三章"));

    // A 只改了标题就保存。
    bool saved = false;
    withServices(a, [&] {
        saved = TaskManager::instance()->updateTaskChanges(
            localId, {{QStringLiteral("title"), QStringLiteral("写论文（第二稿）")}});
    });
    QVERIFY(saved);
    syncAll(cloud, {a, b});
    for (const Device& device : {a, b}) {
        QCOMPARE(taskValue(device, id, QStringLiteral("title")).toString(), QStringLiteral("写论文（第二稿）"));
        QCOMPARE(taskValue(device, id, QStringLiteral("notes")).toString(), QStringLiteral("第三章"));
        QCOMPARE(taskValue(device, id, QStringLiteral("date")).toString(), QStringLiteral("2026-10-02"));
    }
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::concurrentEditsOfSameFieldConvergeAndAreLogged()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("标题"));
    syncAll(cloud, {a, b});

    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture + 1000));
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = 'A 改的' WHERE sync_id = '%1'").arg(id)));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = 'B 改的' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});

    // 同一字段两边同时改：后改的（B）为准，两台设备结果一致。
    QCOMPARE(taskValue(a, id, QStringLiteral("title")).toString(), QStringLiteral("B 改的"));
    QCOMPARE(taskValue(b, id, QStringLiteral("title")).toString(), QStringLiteral("B 改的"));
    // 输掉的值两边都记了一笔，而且是给人看的文字：哪条任务、哪一项、丢了什么、留下什么。
    for (const Device& device : {a, b}) {
        QCOMPARE(logCount(device, QStringLiteral("edit")), 1);
        QSqlQuery log(deviceDb(device));
        QVERIFY(log.exec(QStringLiteral("SELECT record_label, field, lost_value, kept_value FROM sync_conflict_log")));
        QVERIFY(log.next());
        QCOMPARE(log.value(1).toString(), QStringLiteral("title"));
        QCOMPARE(log.value(2).toString(), QStringLiteral("A 改的"));
        QCOMPARE(log.value(3).toString(), QStringLiteral("B 改的"));
    }
}

void SyncTests::sequentialEditsAcrossDevicesAreNotConflicts()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("标题"));
    syncAll(cloud, {a, b});

    // 看过对方的修改再改：这是先后修改，不是冲突，一条日志都不该有。
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = 'B 改的' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = 'A 接着改' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = 'B 再改' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});

    QCOMPARE(taskValue(a, id, QStringLiteral("title")).toString(), QStringLiteral("B 再改"));
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::deleteWinsOverConcurrentEdit_deleteArrivesFirst()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("复习"));
    syncAll(cloud, {a, b});

    // A 离线删除；B 离线修改，时间上更晚。删除仍然优先。
    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture + 1000));
    QVERIFY(exec(a, QStringLiteral("DELETE FROM tasks WHERE sync_id = '%1'").arg(id)));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = '复习第二章' WHERE sync_id = '%1'").arg(id)));
    QVERIFY(cloud.publish(a) > 0);
    cloud.pull(b);
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(id)), 0);
    }
    // B 那次没发出去的修改随删除作废，记在 B 的日志里。
    QCOMPARE(logCount(b, QStringLiteral("delete")), 1);
    QCOMPARE(scalar(b, QStringLiteral("SELECT lost_value FROM sync_conflict_log")).toString(),
             QStringLiteral("复习第二章"));
}

void SyncTests::deleteWinsOverConcurrentEdit_editArrivesFirst()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("复习"));
    syncAll(cloud, {a, b});

    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture + 1000));
    QVERIFY(exec(a, QStringLiteral("DELETE FROM tasks WHERE sync_id = '%1'").arg(id)));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = '复习第二章' WHERE sync_id = '%1'").arg(id)));
    // 这次 B 的修改先到 A：A 已经删了，修改被忽略（不复活），并记下这次作废的修改。
    QVERIFY(cloud.publish(b) > 0);
    cloud.pull(a);
    QCOMPARE(count(a, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(id)), 0);
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(id)), 0);
    }
    QCOMPARE(logCount(a, QStringLiteral("delete")), 1);
}

void SyncTests::concurrentCreatesStayTwoRecords()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    // 两台离线各建一条同名任务：身份不同，就是两条任务，不会互相覆盖。
    QVERIFY(!addTask(a, QStringLiteral("买菜")).isEmpty());
    QVERIFY(!addTask(b, QStringLiteral("买菜")).isEmpty());
    syncAll(cloud, {a, b});
    QCOMPARE(taskTitles(a), QStringList({QStringLiteral("买菜"), QStringLiteral("买菜")}));
    QCOMPARE(taskTitles(b), QStringList({QStringLiteral("买菜"), QStringLiteral("买菜")}));
}

void SyncTests::redeliveredBatchesChangeNothing()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("任务"));
    syncAll(cloud, {a, b});
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '改过', notes = '备注' WHERE sync_id = '%1'").arg(id)));
    QVERIFY(cloud.publish(a) > 0);
    cloud.pull(b);

    // sol6 审查第 4 条：已经写入、却没收到确认（断线、被挂起），连续两次之后全部变成冲突。
    // 这里 B 把 A 的全部文件从头再读两遍，其间 B 自己又改了别的列：什么都不该变，也不该有冲突。
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET completed = 1 WHERE sync_id = '%1'").arg(id)));
    for (int round = 0; round < 2; ++round) {
        cloud.rewind(b, a);
        for (const SyncStore::ApplyResult& result : cloud.pull(b)) {
            QVERIFY2(result.ok, qPrintable(result.error));
        }
    }
    QCOMPARE(taskValue(b, id, QStringLiteral("title")).toString(), QStringLiteral("改过"));
    QCOMPARE(taskValue(b, id, QStringLiteral("notes")).toString(), QStringLiteral("备注"));
    QCOMPARE(taskValue(b, id, QStringLiteral("completed")).toInt(), 1);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks")), 1);
    QCOMPARE(logCount(b), 0);
}

void SyncTests::editDuringSendIsNotLost()
{
    Device a = openDevice(QStringLiteral("a"));
    const QString id = addTask(a, QStringLiteral("任务"));
    SyncStore store(a.connection);
    QVERIFY(store.acknowledge(store.collectPending()));

    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '第一次' WHERE sync_id = '%1'").arg(id)));
    const SyncBatch sent = store.collectPending();
    QCOMPARE(sent.records.size(), 1);
    // 正在写同步文件的时候又改了一次，然后才确认刚才那批。
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '第二次' WHERE sync_id = '%1'").arg(id)));
    QVERIFY(store.acknowledge(sent));

    // 第二次的修改还在队列里，下一批带的是它；base 改成刚发出去的那一版（对方马上就会见到它）。
    const SyncBatch next = store.collectPending();
    QCOMPARE(next.records.size(), 1);
    const SyncFieldValue title = next.records.first().fields.value(QStringLiteral("title"));
    QCOMPARE(title.value.toString(), QStringLiteral("第二次"));
    QVERIFY(title.base == sent.records.first().fields.value(QStringLiteral("title")).version);
    QVERIFY(store.acknowledge(next));
    QVERIFY(store.collectPending().isEmpty());
}

void SyncTests::causalEditWinsDespiteClockSkew()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("任务"));
    syncAll(cloud, {a, b});

    // B 的时钟快很多；A 看过 B 的修改之后再改，即使 A 的时钟慢，A 这次也一定排在后面。
    QVERIFY(setClock(b, kFuture * 2));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = 'B 改的' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});
    QVERIFY(setClock(a, kFuture));
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = 'A 看过之后又改' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});

    QCOMPARE(taskValue(a, id, QStringLiteral("title")).toString(), QStringLiteral("A 看过之后又改"));
    QCOMPARE(taskValue(b, id, QStringLiteral("title")).toString(), QStringLiteral("A 看过之后又改"));
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::sameLogicalTimeConvergesByDevice()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("任务"));
    syncAll(cloud, {a, b});

    // 两台设备恰好给出同一逻辑时间：再比设备标识，所有设备选出同一个结果。
    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture));
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '甲' WHERE sync_id = '%1'").arg(id)));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET title = '乙' WHERE sync_id = '%1'").arg(id)));
    syncAll(cloud, {a, b});

    const QString expected = a.id > b.id ? QStringLiteral("甲") : QStringLiteral("乙");
    QCOMPARE(taskValue(a, id, QStringLiteral("title")).toString(), expected);
    QCOMPARE(taskValue(b, id, QStringLiteral("title")).toString(), expected);
}

void SyncTests::badRecordIsSkippedWithoutBlockingBatch()
{
    Device b = openDevice(QStringLiteral("b"));
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    const SyncVersion version{kFuture, remote};
    SyncBatch batch;
    batch.device = remote;
    // 空标题撞上表上的约束；另一条来自不认识的表（更新的版本多同步了一张表）；中间夹一条正常的。
    SyncRecord bad;
    bad.table = QStringLiteral("tasks");
    bad.syncId = QStringLiteral("bad-task");
    bad.fields.insert(QStringLiteral("title"), {QString(QStringLiteral("")), version, {}});
    bad.fields.insert(QStringLiteral("date"), {QStringLiteral("2026-09-30"), version, {}});
    SyncRecord unknown;
    unknown.table = QStringLiteral("future_table");
    unknown.syncId = QStringLiteral("future-1");
    unknown.fields.insert(QStringLiteral("x"), {qint64(1), version, {}});
    SyncRecord good;
    good.table = QStringLiteral("tasks");
    good.syncId = QStringLiteral("good-task");
    good.fields.insert(QStringLiteral("title"), {QStringLiteral("正常的任务"), version, {}});
    good.fields.insert(QStringLiteral("date"), {QStringLiteral("2026-09-30"), version, {}});
    good.fields.insert(QStringLiteral("display_order"), {qint64(1), version, {}});
    batch.records = {bad, unknown, good};

    // 跳过的每一条都会在运行日志里留一行，真机排查时靠它；这里预期正好两行。
    QTest::ignoreMessage(QtWarningMsg, QRegularExpression(QStringLiteral("^Skipped sync record \"tasks\" \"bad-task\"")));
    QTest::ignoreMessage(QtWarningMsg, QRegularExpression(QStringLiteral("^Skipped sync record \"future_table\"")));
    const SyncStore::ApplyResult result = SyncStore(b.connection).applyRemote(batch);
    // 整批照常提交：坏的两条跳过并记日志，正常的那条落地。
    QVERIFY2(result.ok, qPrintable(result.error));
    QCOMPARE(result.skippedRecords, 2);
    QCOMPARE(logCount(b, QStringLiteral("skipped")), 2);
    QCOMPARE(taskValue(b, QStringLiteral("good-task"), QStringLiteral("title")).toString(), QStringLiteral("正常的任务"));
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = 'bad-task'")), 0);
}

void SyncTests::remoteTaskDeletionKeepsItsSessions()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("任务"));
    const qint64 localId = scalar(a, QStringLiteral("SELECT id FROM tasks WHERE sync_id = '%1'").arg(id)).toLongLong();
    QVERIFY(exec(a, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                   "VALUES (%1, '2026-09-30T09:00:00', '2026-09-30T09:25:00', 1500, 1)").arg(localId)));
    syncAll(cloud, {a, b});
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM focus_sessions fs JOIN tasks t ON t.id = fs.task_id "
                                     "WHERE t.sync_id = '%1'").arg(id)), 1);

    // 在 A 上走服务层删任务（先解除专注记录的关联再删）。B 上任务消失，专注记录作为历史留下，只是不再关联任务。
    withServices(a, [&] { QVERIFY(TaskManager::instance()->deleteTask(int(localId))); });
    syncAll(cloud, {a, b});
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(id)), 0);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE task_id IS NULL AND duration = 1500")), 1);
}

void SyncTests::runningSessionIsNeverSent()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString id = addTask(a, QStringLiteral("任务"));
    syncAll(cloud, {a, b});
    const qint64 localId = scalar(a, QStringLiteral("SELECT id FROM tasks WHERE sync_id = '%1'").arg(id)).toLongLong();
    QVERIFY(exec(a, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, mode) "
                                   "VALUES (%1, '2026-09-30T10:00:00', 1)").arg(localId)));

    for (const SyncRecord& record : SyncStore(a.connection).collectPending().records) {
        QVERIFY(record.table != QLatin1String("focus_sessions"));
    }
    syncAll(cloud, {a, b});
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM focus_sessions")), 0);
}

void SyncTests::batchFromOtherEpochOrSameDeviceIsRejected()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    QVERIFY(!addTask(a, QStringLiteral("任务")).isEmpty());
    SyncBatch batch = SyncStore(a.connection).collectPending();
    QVERIFY(!batch.isEmpty());

    // 纪元不同：属于全局回滚前（或之后）的改动，不能直接合并。
    batch.epoch = 1;
    SyncStore::ApplyResult result = SyncStore(b.connection).applyRemote(batch);
    QVERIFY(!result.ok);
    QVERIFY(!result.error.isEmpty());
    // 设备标识与本机相同：多半是两台设备恢复了同一份备份，合并会把两边搅乱。
    batch.epoch = 0;
    batch.device = b.id;
    result = SyncStore(b.connection).applyRemote(batch);
    QVERIFY(!result.ok);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks")), 0);
}

// ── 2c：引用与去重 ──
//
// 每条都对应 sol6 局域网方案审查时用真实表结构复现过的问题：在那个方案里，这些情况要么让同步永久卡住，
// 要么冒出一堆看不懂的冲突。这里要求：整批照常提交（syncAll 里逐批断言 ok），两台设备结果一致。

void SyncTests::sessionOnRemotelyDeletedTaskIsKeptDetached()
{
    // 审查第 1 条：Mac 删了一条任务，iPad 离线时在这条任务上做了专注——当年报「外键目标不存在」，永久卡死。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString task = addTask(a, QStringLiteral("复习"));
    syncAll(cloud, {a, b});

    QVERIFY(exec(a, QStringLiteral("DELETE FROM tasks WHERE sync_id = '%1'").arg(task)));
    QVERIFY(exec(b, QStringLiteral(
        "INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode, category_name_snapshot) "
        "VALUES (%1, '2026-09-30T09:00:00', '2026-09-30T09:25:00', 1500, 1, '数学')")
                        .arg(localIdOf(b, QStringLiteral("tasks"), task))));
    syncAll(cloud, {a, b});

    // 任务按删除优先消失；专注记录作为历史留下，只是不再关联任务，科目快照还在，统计照样有归属。
    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(task)), 0);
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE task_id IS NULL "
                                              "AND duration = 1500 AND category_name_snapshot = '数学'")), 1);
        QCOMPARE(logCount(device, QStringLiteral("skipped")), 0);
    }
}

void SyncTests::taskUnderRemotelyDeletedCategoryBecomesUncategorized()
{
    // 审查第 1 条的另一种：删科目，而另一台离线时在这个科目下建了任务。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString category = addCategory(a, QStringLiteral("编程"));
    syncAll(cloud, {a, b});

    withServices(a, [&] {
        QVERIFY(CategoryManager::instance()->deleteCategory(int(localIdOf(a, QStringLiteral("categories"), category))));
    });
    const QString task = addTask(b, QStringLiteral("写代码"));
    QVERIFY(setTaskCategory(b, task, category));
    syncAll(cloud, {a, b});

    // 与本机删除科目的做法一致：任务留着，科目和旧的科目名文本一起清空，变成未分类。
    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM categories WHERE sync_id = '%1'").arg(category)), 0);
        QVERIFY(taskValue(device, task, QStringLiteral("category_id")).isNull());
        QVERIFY(taskValue(device, task, QStringLiteral("category")).isNull());
        QCOMPARE(taskValue(device, task, QStringLiteral("title")).toString(), QStringLiteral("写代码"));
    }
}

void SyncTests::renamedCategoryThenRecreatedNameSyncs()
{
    // 审查第 3 条：把「编程」改名后再新建一个「编程」——按名字认科目的方案里，对方连读取都失败。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString old = addCategory(a, QStringLiteral("编程"));
    const QString first = addTask(a, QStringLiteral("旧任务"));
    QVERIFY(setTaskCategory(a, first, old));
    syncAll(cloud, {a, b});

    QVERIFY(exec(a, QStringLiteral("UPDATE categories SET name = '计算机' WHERE sync_id = '%1'").arg(old)));
    const QString recreated = addCategory(a, QStringLiteral("编程"));
    const QString second = addTask(a, QStringLiteral("新任务"));
    QVERIFY(setTaskCategory(a, second, recreated));
    syncAll(cloud, {a, b});

    QCOMPARE(customCategoryNames(b), QStringList({QStringLiteral("编程"), QStringLiteral("计算机")}));
    QCOMPARE(taskCategory(b, first), old);
    QCOMPARE(taskCategory(b, second), recreated);
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::renameCollidingWithOtherSidesNewCategoryMerges()
{
    // 审查第 3 条：A 把「编程」改成「计算机」，B 同时新建了「计算机」——当年撞上名称唯一约束，写入失败。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString renamed = addCategory(a, QStringLiteral("编程"));
    syncAll(cloud, {a, b});

    QVERIFY(exec(a, QStringLiteral("UPDATE categories SET name = '计算机' WHERE sync_id = '%1'").arg(renamed)));
    const QString onA = addTask(a, QStringLiteral("A 的任务"));
    QVERIFY(setTaskCategory(a, onA, renamed));
    const QString created = addCategory(b, QStringLiteral("计算机"));
    const QString onB = addTask(b, QStringLiteral("B 的任务"));
    QVERIFY(setTaskCategory(b, onB, created));
    syncAll(cloud, {a, b});

    // 合并成一个：留身份较小的那个，两边的任务都指向它，另一个留下「合并」删除记录。
    const QString winner = qMin(renamed, created);
    const QString loser = qMax(renamed, created);
    for (const Device& device : {a, b}) {
        QCOMPARE(customCategoryNames(device), QStringList{QStringLiteral("计算机")});
        QCOMPARE(taskCategory(device, onA), winner);
        QCOMPARE(taskCategory(device, onB), winner);
        QCOMPARE(taskValue(device, onB, QStringLiteral("category")).toString(), QStringLiteral("计算机"));
        QCOMPARE(scalar(device, QStringLiteral("SELECT kind || ':' || merged_into FROM sync_tombstones "
                                               "WHERE sync_id = '%1'").arg(loser)).toString(),
                 QStringLiteral("merge:") + winner);
        QCOMPARE(logCount(device, QStringLiteral("skipped")), 0);
    }
}

void SyncTests::sameNameCategoriesCreatedOnBothSidesMerge()
{
    // 审查第 5 条：两边各建一个同名科目，只因为创建时间不同就一定冲突，要人去选。这里自动合并，不算冲突。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString x = addCategory(a, QStringLiteral("英语阅读"));
    const QString y = addCategory(b, QStringLiteral("英语阅读"));
    const QString taskA = addTask(a, QStringLiteral("精读"));
    const QString taskB = addTask(b, QStringLiteral("泛读"));
    QVERIFY(setTaskCategory(a, taskA, x));
    QVERIFY(setTaskCategory(b, taskB, y));
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(customCategoryNames(device), QStringList{QStringLiteral("英语阅读")});
        QCOMPARE(taskCategory(device, taskA), qMin(x, y));
        QCOMPARE(taskCategory(device, taskB), qMin(x, y));
        // 只有一条「已合并」的说明，没有要人处理的冲突。
        QCOMPARE(logCount(device, QStringLiteral("edit")), 0);
        QCOMPARE(logCount(device, QStringLiteral("skipped")), 0);
    }
}

void SyncTests::swappedCategoryNamesAreNotMerged()
{
    // 两个科目互换名字：逐条应用时中途会撞名，但最终并没有重名，不能被误判成要合并。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString first = addCategory(a, QStringLiteral("甲"));
    const QString second = addCategory(a, QStringLiteral("乙"));
    syncAll(cloud, {a, b});

    QVERIFY(exec(a, QStringLiteral("UPDATE categories SET name = '临时' WHERE sync_id = '%1'").arg(first)));
    QVERIFY(exec(a, QStringLiteral("UPDATE categories SET name = '甲' WHERE sync_id = '%1'").arg(second)));
    QVERIFY(exec(a, QStringLiteral("UPDATE categories SET name = '乙' WHERE sync_id = '%1'").arg(first)));
    syncAll(cloud, {a, b});

    QCOMPARE(scalar(b, QStringLiteral("SELECT name FROM categories WHERE sync_id = '%1'").arg(first)).toString(),
             QStringLiteral("乙"));
    QCOMPARE(scalar(b, QStringLiteral("SELECT name FROM categories WHERE sync_id = '%1'").arg(second)).toString(),
             QStringLiteral("甲"));
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::mergeReachesSideThatDidNotCollide()
{
    // A 看到撞名、做了合并；B 却在这之前把自己那个科目改成了别的名字，本机没有撞名。
    // 合并记录必须发给 B，否则 B 会一直留着 A 已经并掉的那个科目。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    // 固定身份：A 的较小，撞名时 B 的并进 A 的。换成随机身份，一半的情况下合并方向相反，
    // 那种方向即使合并没发出去，两边也碰巧一致，这条用例就测不出问题了。
    const QString x = addCategory(a, QStringLiteral("编程"), QStringLiteral("aaaa-category"));
    const QString y = addCategory(b, QStringLiteral("编程"), QStringLiteral("bbbb-category"));
    const QString task = addTask(b, QStringLiteral("B 的任务"));
    QVERIFY(setTaskCategory(b, task, y));
    QVERIFY(cloud.publish(b) > 0);
    QVERIFY(exec(b, QStringLiteral("UPDATE categories SET name = '编程基础' WHERE sync_id = '%1'").arg(y)));
    cloud.pull(a);  // A 只看到 B 改名之前的那一批：撞名，把 B 的并进自己的
    QCOMPARE(scalar(a, QStringLiteral("SELECT kind FROM sync_tombstones WHERE sync_id = '%1'").arg(y)).toString(),
             QStringLiteral("merge"));
    syncAll(cloud, {a, b});

    // 两台设备最终一致：只剩 A 的那个科目，B 的任务也挂到它下面；B 那次改名随合并作废（记了日志）。
    for (const Device& device : {a, b}) {
        QCOMPARE(customCategoryNames(device), QStringList{QStringLiteral("编程")});
        QCOMPARE(taskCategory(device, task), x);
        QCOMPARE(logCount(device, QStringLiteral("skipped")), 0);
    }
    QCOMPARE(logCount(a, QStringLiteral("merge")), 2);
}

void SyncTests::presetsRenamedToSameNameGetSuffix()
{
    // 预置科目不能删，也就不能合并：两边把不同的预置科目改成同一个名字时，后改的留下名字，另一个加后缀。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    syncAll(cloud, {a, b});

    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture + 1000));
    QVERIFY(exec(a, QStringLiteral("UPDATE categories SET name = '数理' WHERE sync_id = 'preset-1'")));
    QVERIFY(exec(b, QStringLiteral("UPDATE categories SET name = '数理' WHERE sync_id = 'preset-2'")));
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(scalar(device, QStringLiteral("SELECT name FROM categories WHERE sync_id = 'preset-2'")).toString(),
                 QStringLiteral("数理"));
        QCOMPARE(scalar(device, QStringLiteral("SELECT name FROM categories WHERE sync_id = 'preset-1'")).toString(),
                 QStringLiteral("数理（2）"));
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM categories WHERE is_preset = 1")), 5);
    }
}

void SyncTests::sameDayTasksAreRenumberedWithoutMigration()
{
    // 审查第 7 条：两端同一天各加任务，排序号撞了；当年每次同步后启动都要走 v12 修一遍并生成迁移快照，
    // 快照只留三份，真正升级前的那几份很快被挤掉。这里在同步的同一个事务里按确定规则重排，两边顺序一致。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString date = QStringLiteral("2026-09-30");
    for (const QString& title : {QStringLiteral("A1"), QStringLiteral("A2")}) {
        QVERIFY(!addTask(a, title, date).isEmpty());
    }
    for (const QString& title : {QStringLiteral("B1"), QStringLiteral("B2")}) {
        QVERIFY(!addTask(b, title, date).isEmpty());
    }
    const QDir dataDir(m_data->path());
    const QStringList pattern{QStringLiteral("pomodoro_backup_*.db")};
    const qsizetype snapshotsBefore = dataDir.entryList(pattern, QDir::Files).size();
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(DISTINCT display_order) FROM tasks WHERE date = '%1'")
                                   .arg(date)), 4);
        QCOMPARE(count(device, QStringLiteral("SELECT MIN(display_order) FROM tasks WHERE date = '%1'").arg(date)), 1);
    }
    QCOMPARE(dayOrder(a, date), dayOrder(b, date));

    // 重新打开两台设备的库：启动检查看不到任何需要修复的排序，不会走 v12，也就不会多出迁移快照。
    withServices(a, [] {});
    withServices(b, [] {});
    QCOMPARE(dataDir.entryList(pattern, QDir::Files).size(), snapshotsBefore);
}

void SyncTests::corruptMergeChainDoesNotHang()
{
    // 合并总是并向身份较小的一方，正常不会成环；外部改坏的数据里出现环，也只追有限步，然后当作找不到。
    Device b = openDevice(QStringLiteral("b"));
    QVERIFY(exec(b, QStringLiteral("INSERT INTO sync_tombstones (tbl, sync_id, v_time, v_device, kind, merged_into, "
                                   "deleted_at) VALUES ('categories', 'loop-x', 1, 'd', 'merge', 'loop-y', 1), "
                                   "('categories', 'loop-y', 1, 'd', 'merge', 'loop-x', 1)")));
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    const SyncVersion version{kFuture, remote};
    SyncRecord task;
    task.table = QStringLiteral("tasks");
    task.syncId = QStringLiteral("task-in-loop");
    task.fields.insert(QStringLiteral("title"), {QStringLiteral("环里的任务"), version, {}});
    task.fields.insert(QStringLiteral("date"), {QStringLiteral("2026-09-30"), version, {}});
    task.fields.insert(QStringLiteral("category_id"), {QStringLiteral("loop-x"), version, {}});
    task.fields.insert(QStringLiteral("category"), {QStringLiteral("环"), version, {}});
    SyncBatch batch;
    batch.device = remote;
    batch.records = {task};
    const SyncStore::ApplyResult result = SyncStore(b.connection).applyRemote(batch);
    QVERIFY2(result.ok, qPrintable(result.error));
    QVERIFY(taskValue(b, QStringLiteral("task-in-loop"), QStringLiteral("category_id")).isNull());
}

// ── 2d：例行与逻辑日起点 ──

void SyncTests::reclaimedInstanceIsSoftDeletedAndRegenerates()
{
    // 单机行为不变：停用例行收回今天没动过的实例，重新启用又能生成回来；只是收回现在留下的是「收回」记录。
    RoutineManager* routines = RoutineManager::instance();
    QVERIFY(routines->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
    const int routineId = scalar(QStringLiteral("SELECT id FROM routines")).toInt();
    const QString instance = SyncSchema::routineInstanceSyncId(
        scalar(QStringLiteral("SELECT sync_id FROM routines")).toString(), today().toString(Qt::ISODate));
    QCOMPARE(routines->materializeToday(), 1);

    QVERIFY(setClock(20000, true));
    QVERIFY(routines->setRoutineActive(routineId, false));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 0);
    QCOMPARE(tombstoneKind(QStringLiteral("tasks"), instance), QStringLiteral("reclaim"));
    // 标记用完就复位：之后的普通删除不能被误记成收回。
    QVERIFY(scalar(QStringLiteral("SELECT delete_kind FROM sync_runtime")).isNull());

    QVERIFY(routines->setRoutineActive(routineId, true));
    QCOMPARE(routines->materializeToday(), 1);
    // 同一个身份回来了，用真实版本（要在对方那里取代收回记录），收回记录随之消失。
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 1);
    QVERIFY(versionOf(QStringLiteral("tasks"), instance, QStringLiteral("title")).time > 20000);
    QVERIFY(tombstoneKind(QStringLiteral("tasks"), instance).isEmpty());

    // 用户自己删掉的实例：删除优先，生成戳被退回也不会再生成。
    QVERIFY(TaskManager::instance()->deleteTask(
        scalar(QStringLiteral("SELECT id FROM tasks WHERE sync_id = '%1'").arg(instance)).toInt()));
    QCOMPARE(tombstoneKind(QStringLiteral("tasks"), instance), QStringLiteral("delete"));
    QVERIFY(exec(QStringLiteral("UPDATE routines SET last_generated_date = '2000-01-01'")));
    QCOMPARE(routines->materializeToday(), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 0);
    QCOMPARE(scalar(QStringLiteral("SELECT last_generated_date FROM routines")).toString(),
             today().toString(Qt::ISODate));
}

void SyncTests::bothDevicesGenerateOneInstanceAndKeepCompletion()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    withServices(a, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
    });
    syncAll(cloud, {a, b});
    const QString instance = SyncSchema::routineInstanceSyncId(
        scalar(a, QStringLiteral("SELECT sync_id FROM routines")).toString(), today().toString(Qt::ISODate));

    // A 生成当天实例并完成了它；B 还没收到，稍后自己也生成了同一天的实例（默认值：未完成）。
    withServices(a, [&] {
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
        QVERIFY(TaskManager::instance()->setTaskCompleted(int(localIdOf(a, QStringLiteral("tasks"), instance)), true));
    });
    withServices(b, [] { QCOMPARE(RoutineManager::instance()->materializeToday(), 1); });
    syncAll(cloud, {a, b});

    // 同一天只有一条，而且 B 晚生成的那份没有盖掉 A 上的「已完成」。
    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE routine_generated = 1")), 1);
        QCOMPARE(taskValue(device, instance, QStringLiteral("completed")).toInt(), 1);
    }
    QCOMPARE(logCount(a) + logCount(b), 0);
}

void SyncTests::remoteReclaimKeepsTouchedInstanceOnBothSides()
{
    // 审查第 1 条的例行版本：停用例行时 Mac 收回今天没专注过的实例，可它只看得到本机的专注记录；
    // iPad 离线时在这条实例上专注过。当年直接卡死；这里两边最后都留着实例，专注记录两边都挂在它上面。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    withServices(a, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    syncAll(cloud, {a, b});
    const QString routine = scalar(a, QStringLiteral("SELECT sync_id FROM routines")).toString();
    const QString instance = SyncSchema::routineInstanceSyncId(routine, today().toString(Qt::ISODate));

    QVERIFY(exec(b, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                   "VALUES (%1, '2026-09-30T09:00:00', '2026-09-30T09:25:00', 1500, 1)")
                        .arg(localIdOf(b, QStringLiteral("tasks"), instance))));
    withServices(a, [&] {
        QVERIFY(RoutineManager::instance()->setRoutineActive(int(localIdOf(a, QStringLiteral("routines"), routine)),
                                                             false));
    });
    QCOMPARE(scalar(a, QStringLiteral("SELECT kind FROM sync_tombstones WHERE sync_id = '%1'").arg(instance)).toString(),
             QStringLiteral("reclaim"));
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 1);
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM focus_sessions fs JOIN tasks t ON t.id = fs.task_id "
                                              "WHERE t.sync_id = '%1'").arg(instance)), 1);
        QCOMPARE(scalar(device, QStringLiteral("SELECT active FROM routines")).toInt(), 0);
        QCOMPARE(logCount(device, QStringLiteral("skipped")), 0);
    }
}

void SyncTests::republishedInstanceOutranksAFastClocksReclaim()
{
    // 上一条的确定版：A 的时钟快（连着做几件事会把逻辑时间推到墙钟前面，两台设备的时钟也本来就有偏差），
    // 它收回实例的版本比 B 此刻的墙钟还新。B 收到时发现实例专注过，重新发布它——这个新版本必须排在
    // A 的收回记录之后，A 才会把实例补回来。曾经在全套并行时偶发失败：重新发布取的是「此刻与本机时钟 + 1」，
    // 这一批里 A 的版本要到整批收尾才并进时钟，于是新版本可能比收回记录还旧，两边从此不一致。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    QVERIFY(setClock(a, kFuture));
    withServices(a, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    syncAll(cloud, {a, b});
    const QString routine = scalar(a, QStringLiteral("SELECT sync_id FROM routines")).toString();
    const QString instance = SyncSchema::routineInstanceSyncId(routine, today().toString(Qt::ISODate));
    QVERIFY(exec(b, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                   "VALUES (%1, '2026-09-30T09:00:00', '2026-09-30T09:25:00', 1500, 1)")
                        .arg(localIdOf(b, QStringLiteral("tasks"), instance))));
    // A 又连着做了几件事（每件都让逻辑时间加一），再停用例行、收回实例。
    for (int i = 0; i < 5; ++i) {
        QVERIFY(!addTask(a, QStringLiteral("A 的任务 %1").arg(i)).isEmpty());
    }
    withServices(a, [&] {
        QVERIFY(RoutineManager::instance()->setRoutineActive(int(localIdOf(a, QStringLiteral("routines"), routine)),
                                                             false));
    });
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 1);
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM focus_sessions fs JOIN tasks t ON t.id = fs.task_id "
                                              "WHERE t.sync_id = '%1'").arg(instance)), 1);
    }
    QCOMPARE(describe(SyncStore(b.connection).exportSnapshot()), describe(SyncStore(a.connection).exportSnapshot()));
}

void SyncTests::regeneratedInstanceReachesOtherDevice()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    withServices(a, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    syncAll(cloud, {a, b});
    const QString routine = scalar(a, QStringLiteral("SELECT sync_id FROM routines")).toString();
    const QString instance = SyncSchema::routineInstanceSyncId(routine, today().toString(Qt::ISODate));
    const int routineId = int(localIdOf(a, QStringLiteral("routines"), routine));

    // A 停用：两边没动过的实例都收回。
    withServices(a, [&] { QVERIFY(RoutineManager::instance()->setRoutineActive(routineId, false)); });
    syncAll(cloud, {a, b});
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 0);

    // A 又启用并重新生成：B 那边也补回来。
    withServices(a, [&] {
        QVERIFY(RoutineManager::instance()->setRoutineActive(routineId, true));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    syncAll(cloud, {a, b});
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 1);
    QCOMPARE(scalar(b, QStringLiteral("SELECT active FROM routines")).toInt(), 1);
}

void SyncTests::userDeletedInstanceStaysDeletedOnBothDevices()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    withServices(a, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    syncAll(cloud, {a, b});
    const QString instance = SyncSchema::routineInstanceSyncId(
        scalar(a, QStringLiteral("SELECT sync_id FROM routines")).toString(), today().toString(Qt::ISODate));

    withServices(a, [&] {
        QVERIFY(TaskManager::instance()->deleteTask(int(localIdOf(a, QStringLiteral("tasks"), instance))));
    });
    syncAll(cloud, {a, b});
    QCOMPARE(scalar(b, QStringLiteral("SELECT kind FROM sync_tombstones WHERE sync_id = '%1'").arg(instance)).toString(),
             QStringLiteral("delete"));

    // B 的生成戳因为别的原因退回了（例如改过逻辑日起点）：你在另一台上删掉的实例也不会被 B 生成回来。
    QVERIFY(exec(b, QStringLiteral("UPDATE routines SET last_generated_date = '2000-01-01'")));
    withServices(b, [] { QCOMPARE(RoutineManager::instance()->materializeToday(), 0); });
    syncAll(cloud, {a, b});
    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 0);
    }
}

void SyncTests::userDeletionOutranksConcurrentReclaimOnBothDevices()
{
    // 审查（10-01）复现的不一致：A 手动删掉今天的实例，B 同时停用例行、收回了同一条。B 的改动先到 A：
    // A 的删除记录压过收回，以前却随之被移出待发送，B 永远只有「收回」。B 当天重新启用例行、生成回这条实例后，
    // A 按删除优先忽略它，两边从此一边有、一边没有。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    withServices(a, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    syncAll(cloud, {a, b});
    const QString instance = SyncSchema::routineInstanceSyncId(
        scalar(a, QStringLiteral("SELECT sync_id FROM routines")).toString(), today().toString(Qt::ISODate));
    const int routineOnB = scalar(b, QStringLiteral("SELECT id FROM routines")).toInt();

    withServices(a, [&] {
        QVERIFY(TaskManager::instance()->deleteTask(int(localIdOf(a, QStringLiteral("tasks"), instance))));
    });
    withServices(b, [&] { QVERIFY(RoutineManager::instance()->setRoutineActive(routineOnB, false)); });
    QCOMPARE(scalar(b, QStringLiteral("SELECT kind FROM sync_tombstones WHERE sync_id = '%1'").arg(instance)).toString(),
             QStringLiteral("reclaim"));

    // B 的那批先到 A：A 的删除记录赢了，而且必须还等着发出去。
    QVERIFY(cloud.publish(b) > 0);
    for (const SyncStore::ApplyResult& result : cloud.pull(a)) {
        QVERIFY2(result.ok, qPrintable(result.error));
    }
    QCOMPARE(scalar(a, QStringLiteral("SELECT kind FROM sync_tombstones WHERE sync_id = '%1'").arg(instance)).toString(),
             QStringLiteral("delete"));
    QCOMPARE(count(a, QStringLiteral("SELECT COUNT(*) FROM sync_outbox WHERE sync_id = '%1'").arg(instance)), 1);
    syncAll(cloud, {a, b});
    QCOMPARE(scalar(b, QStringLiteral("SELECT kind FROM sync_tombstones WHERE sync_id = '%1'").arg(instance)).toString(),
             QStringLiteral("delete"));

    // B 当天重新启用例行：B 已经知道这条是你删掉的，不再生成；两边都没有它。
    withServices(b, [&] {
        QVERIFY(RoutineManager::instance()->setRoutineActive(routineOnB, true));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 0);
    });
    syncAll(cloud, {a, b});
    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 0);
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), 0);
    }
}

void SyncTests::dayStartHourSyncsWithDefaultsAndLatestWins()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString key = QStringLiteral("logic/dayStartHour");
    SyncStore storeA(a.connection);
    SyncStore storeB(b.connection);
    // 两台都还是出厂默认的 4 点：各自记下的是最小版本，谁也不覆盖谁。
    QVERIFY(storeA.recordLocalSetting(key, QStringLiteral("4"), true));
    QVERIFY(storeB.recordLocalSetting(key, QStringLiteral("4"), true));
    syncAll(cloud, {a, b});

    // A 改成 5 点：B 收到后，由调用方把新值写回 AppSettings。
    QVERIFY(storeA.recordLocalSetting(key, QStringLiteral("5"), false));
    QVERIFY(cloud.publish(a) > 0);
    const QList<SyncStore::ApplyResult> results = cloud.pull(b);
    QCOMPARE(results.size(), 1);
    QCOMPARE(results.first().changedSettings.value(key), QStringLiteral("5"));
    QCOMPARE(storeB.syncedSetting(key), QStringLiteral("5"));
    // 写回 AppSettings 之后它又发出变更信号、调用方再记一次：值没变，不是本机改动，不会再发回去。
    QVERIFY(storeB.recordLocalSetting(key, QStringLiteral("5"), false));
    QVERIFY(storeB.collectPending().settings.isEmpty());

    // 两边同时改：后改的为准，输掉的一方记日志。
    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture + 1000));
    QVERIFY(storeA.recordLocalSetting(key, QStringLiteral("6"), false));
    QVERIFY(storeB.recordLocalSetting(key, QStringLiteral("3"), false));
    syncAll(cloud, {a, b});
    QCOMPARE(storeA.syncedSetting(key), QStringLiteral("3"));
    QCOMPARE(storeB.syncedSetting(key), QStringLiteral("3"));
    QCOMPARE(logCount(a, QStringLiteral("edit")), 1);
    QCOMPARE(scalar(a, QStringLiteral("SELECT lost_value FROM sync_conflict_log")).toString(), QStringLiteral("6 点"));

    // 新加入的设备第一次记下默认值：不会盖掉已经改过的设置。
    Device c = openDevice(QStringLiteral("c"));
    QVERIFY(SyncStore(c.connection).recordLocalSetting(key, QStringLiteral("4"), true));
    syncAll(cloud, {a, b, c});
    for (const Device& device : {a, b, c}) {
        QCOMPARE(SyncStore(device.connection).syncedSetting(key), QStringLiteral("3"));
    }
}

void SyncTests::referenceArrivingBeforeItsTargetIsRelinked()
{
    // 一条专注记录先到，它指向的任务本机还没有（例如那条任务被收回、之后才补回来）：
    // 先落空值并记下目标，目标到了再接回去。
    Device b = openDevice(QStringLiteral("b"));
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    const SyncVersion version{kFuture, remote};
    SyncRecord session;
    session.table = QStringLiteral("focus_sessions");
    session.syncId = QStringLiteral("early-session");
    session.fields.insert(QStringLiteral("task_id"), {QStringLiteral("late-task"), version, {}});
    session.fields.insert(QStringLiteral("start_time"), {QStringLiteral("2026-09-30T09:00:00"), version, {}});
    session.fields.insert(QStringLiteral("end_time"), {QStringLiteral("2026-09-30T09:25:00"), version, {}});
    session.fields.insert(QStringLiteral("duration"), {qint64(1500), version, {}});
    session.fields.insert(QStringLiteral("mode"), {qint64(1), version, {}});
    SyncBatch first;
    first.device = remote;
    first.records = {session};
    QVERIFY(SyncStore(b.connection).applyRemote(first).ok);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE sync_id = 'early-session' "
                                     "AND task_id IS NULL")), 1);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM sync_pending_refs")), 1);

    SyncRecord task;
    task.table = QStringLiteral("tasks");
    task.syncId = QStringLiteral("late-task");
    task.fields.insert(QStringLiteral("title"), {QStringLiteral("后到的任务"), version, {}});
    task.fields.insert(QStringLiteral("date"), {QStringLiteral("2026-09-30"), version, {}});
    task.fields.insert(QStringLiteral("display_order"), {qint64(1), version, {}});
    SyncBatch second;
    second.device = remote;
    second.records = {task};
    QVERIFY(SyncStore(b.connection).applyRemote(second).ok);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM focus_sessions fs JOIN tasks t ON t.id = fs.task_id "
                                     "WHERE fs.sync_id = 'early-session' AND t.sync_id = 'late-task'")), 1);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM sync_pending_refs")), 0);
}

void SyncTests::derivedEmptyReferenceIsNotSentBack()
{
    // A 因为引用的目标暂时没有而把引用置空，这个空值的版本还是 B 那一版。之后 A 改了这条记录的别的字段，
    // 整条记录（连同这个推出来的空值）发回 B：B 不能按「版本相同就比大小」把自己正常的引用也清掉。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    const QString task = addTask(b, QStringLiteral("B 的任务"));
    QVERIFY(exec(b, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                   "VALUES (%1, '2026-09-30T09:00:00', '2026-09-30T09:25:00', 1500, 1)")
                        .arg(localIdOf(b, QStringLiteral("tasks"), task))));
    const QString session = scalar(b, QStringLiteral("SELECT sync_id FROM focus_sessions")).toString();

    // A 只收到了专注记录、没收到它的任务（例如任务那条被收回、之后才补回来）。
    const SyncBatch fromB = SyncStore(b.connection).collectPending();
    SyncBatch onlySession;
    onlySession.device = fromB.device;
    onlySession.epoch = fromB.epoch;
    for (const SyncRecord& record : fromB.records) {
        if (record.table == QLatin1String("focus_sessions")) {
            onlySession.records.append(record);
        }
    }
    QVERIFY(SyncStore(a.connection).applyRemote(onlySession).ok);
    QVERIFY(SyncStore(b.connection).acknowledge(fromB));
    QVERIFY(scalar(a, QStringLiteral("SELECT task_id FROM focus_sessions WHERE sync_id = '%1'").arg(session)).isNull());

    // A 在这条专注记录上改了时长，于是整条记录被发回 B。
    QVERIFY(exec(a, QStringLiteral("UPDATE focus_sessions SET duration = 1200 WHERE sync_id = '%1'").arg(session)));
    const SyncStore::ApplyResult result = SyncStore(b.connection).applyRemote(SyncStore(a.connection).collectPending());
    QVERIFY2(result.ok, qPrintable(result.error));

    // B 只收下了时长，仍然挂着自己的任务。
    QCOMPARE(scalar(b, QStringLiteral("SELECT duration FROM focus_sessions WHERE sync_id = '%1'").arg(session)).toInt(),
             1200);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM focus_sessions fs JOIN tasks t ON t.id = fs.task_id "
                                     "WHERE fs.sync_id = '%1' AND t.sync_id = '%2'").arg(session, task)), 1);
}

void SyncTests::pendingReferenceRelinksWhenTargetIsRegeneratedLocally()
{
    // 审查（10-01）复现的不一致：B 在今天的实例上专注过；A 同时停用例行、收回了这条实例。B 的专注记录先到 A，
    // 任务先置空、等着接回。A 当天又重新启用例行，自己生成回这条实例。以前只有「从同步插入目标」时才接回，
    // A 上这条专注记录从此空着，B 上挂着，两边版本相同，谁也不纠正谁。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    withServices(a, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    syncAll(cloud, {a, b});
    const QString instance = SyncSchema::routineInstanceSyncId(
        scalar(a, QStringLiteral("SELECT sync_id FROM routines")).toString(), today().toString(Qt::ISODate));
    const int routineOnA = scalar(a, QStringLiteral("SELECT id FROM routines")).toInt();
    QVERIFY(exec(b, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                   "VALUES (%1, '2026-09-30T09:00:00', '2026-09-30T09:25:00', 1500, 1)")
                        .arg(localIdOf(b, QStringLiteral("tasks"), instance))));
    const QString session = scalar(b, QStringLiteral("SELECT sync_id FROM focus_sessions")).toString();
    withServices(a, [&] { QVERIFY(RoutineManager::instance()->setRoutineActive(routineOnA, false)); });

    // B 的专注记录先到 A：任务先置空，记下等着接回。
    QVERIFY(cloud.publish(b) > 0);
    for (const SyncStore::ApplyResult& result : cloud.pull(a)) {
        QVERIFY2(result.ok, qPrintable(result.error));
    }
    QVERIFY(scalar(a, QStringLiteral("SELECT task_id FROM focus_sessions WHERE sync_id = '%1'").arg(session)).isNull());
    QCOMPARE(count(a, QStringLiteral("SELECT COUNT(*) FROM sync_pending_refs")), 1);

    // A 当天重新启用例行、自己生成回这条实例：同步引擎下一轮开始时就接上，不必等对方的批次。
    withServices(a, [&] {
        QVERIFY(RoutineManager::instance()->setRoutineActive(routineOnA, true));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    const SyncStore::ApplyResult relinked = SyncStore(a.connection).resolvePendingReferences();
    QVERIFY2(relinked.ok, qPrintable(relinked.error));
    QVERIFY(relinked.changedTables.contains(QStringLiteral("focus_sessions")));
    // 接回不是本机改动，不会被当成新版本发出去。
    QCOMPARE(count(a, QStringLiteral("SELECT COUNT(*) FROM sync_outbox WHERE tbl = 'focus_sessions'")), 0);

    syncAll(cloud, {a, b});
    const QString linkedTask = QStringLiteral(
        "SELECT t.sync_id FROM focus_sessions f JOIN tasks t ON t.id = f.task_id WHERE f.sync_id = '%1'");
    for (const Device& device : {a, b}) {
        QCOMPARE(scalar(device, linkedTask.arg(session)).toString(), instance);
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM sync_pending_refs")), 0);
    }
}

void SyncTests::gapLinkToReclaimedInstanceComesBackOnBothDevices()
{
    // 知识缺口指向的今日实例被另一台收回：收到收回的这台删实例时，外键把缺口的来源任务置空（应用远端改动时
    // 触发器跳过、不记版本）；发起收回的那台收到这条缺口时目标已经没了，也是空着、等着接回。
    // 两边都得记成「待接回」，实例补回来时一起接上；只有一边记着，接回之后就一边挂着、一边空着。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    withServices(a, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    syncAll(cloud, {a, b});
    const QString instance = SyncSchema::routineInstanceSyncId(
        scalar(a, QStringLiteral("SELECT sync_id FROM routines")).toString(), today().toString(Qt::ISODate));
    const int routineOnA = scalar(a, QStringLiteral("SELECT id FROM routines")).toInt();
    const QString gap = addGap(b, QStringLiteral("词根总记混"), QString(), instance);
    QVERIFY(!gap.isEmpty());
    withServices(a, [&] { QVERIFY(RoutineManager::instance()->setRoutineActive(routineOnA, false)); });
    syncAll(cloud, {a, b});
    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(instance)), 0);
        QVERIFY(valueOf(device, QStringLiteral("knowledge_gaps"), gap, QStringLiteral("source_task_id")).isNull());
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM sync_pending_refs")), 1);
    }

    // A 当天又启用例行、生成回实例：各自一轮同步之后，两边的缺口都接回到这条实例上。
    withServices(a, [&] {
        QVERIFY(RoutineManager::instance()->setRoutineActive(routineOnA, true));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    syncAll(cloud, {a, b});
    for (const Device& device : {a, b}) {
        QVERIFY(SyncStore(device.connection).resolvePendingReferences().ok);
    }
    syncAll(cloud, {a, b});
    const QString source = QStringLiteral(
        "SELECT t.sync_id FROM knowledge_gaps g JOIN tasks t ON t.id = g.source_task_id WHERE g.sync_id = '%1'");
    for (const Device& device : {a, b}) {
        QCOMPARE(scalar(device, source.arg(gap)).toString(), instance);
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM sync_pending_refs")), 0);
    }
}

void SyncTests::pendingReferenceTravelsAsItsTarget()
{
    // 等着接回的引用，本机列里是空值；发出去的（尤其是快照）必须是它本来指向的身份：从这份快照起步的设备
    // 才会同样记下「待接回」，目标补回来时一起接上，而不是拿到一个推出来的空值、从此接不回。
    Device b = openDevice(QStringLiteral("b"));
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    const SyncVersion version{kFuture, remote};
    SyncRecord session;
    session.table = QStringLiteral("focus_sessions");
    session.syncId = QStringLiteral("early-session");
    session.fields.insert(QStringLiteral("task_id"), {QStringLiteral("late-task"), version, {}});
    session.fields.insert(QStringLiteral("start_time"), {QStringLiteral("2026-09-30T09:00:00"), version, {}});
    session.fields.insert(QStringLiteral("end_time"), {QStringLiteral("2026-09-30T09:25:00"), version, {}});
    session.fields.insert(QStringLiteral("duration"), {qint64(1500), version, {}});
    session.fields.insert(QStringLiteral("mode"), {qint64(1), version, {}});
    SyncBatch batch;
    batch.device = remote;
    batch.records = {session};
    QVERIFY(SyncStore(b.connection).applyRemote(batch).ok);
    QVERIFY(scalar(b, QStringLiteral("SELECT task_id FROM focus_sessions WHERE sync_id = 'early-session'")).isNull());

    const auto exportedTarget = [&b] {
        for (const SyncRecord& record : SyncStore(b.connection).exportSnapshot().records) {
            if (record.syncId == QLatin1String("early-session")) {
                return record.fields.value(QStringLiteral("task_id")).value;
            }
        }
        return QVariant(QStringLiteral("(没有这条记录)"));
    };
    QCOMPARE(exportedTarget().toString(), QStringLiteral("late-task"));

    // 这一列后来被改过（版本对不上）：等着的那条作废，发出去的是现在的值。
    QVERIFY(exec(b, QStringLiteral("UPDATE sync_pending_refs SET v_time = v_time - 1")));
    QVERIFY(exportedTarget().isNull());
}

// ── 2e：快照、首次加入与全局回滚 ──

void SyncTests::firstJoinReplacesJoiningDeviceWithSnapshot()
{
    // 你定了：iPad 第一次加入时完全以 Mac 为准，iPad 上的都是测试数据，不用保留。
    Device mac = openDevice(QStringLiteral("mac"));
    Device ipad = openDevice(QStringLiteral("ipad"));
    const QString date = today().toString(Qt::ISODate);

    // Mac：自定义科目和它下面的任务、改过名的预置科目、例行与当天实例、专注与休息、改过的逻辑日起点。
    const QString programming = addCategory(mac, QStringLiteral("编程"));
    const QString macTask = addTask(mac, QStringLiteral("写代码"), date);
    QVERIFY(setTaskCategory(mac, macTask, programming));
    QVERIFY(exec(mac, QStringLiteral("UPDATE categories SET name = '英语阅读' WHERE sync_id = 'preset-2'")));
    withServices(mac, [] {
        QVERIFY(RoutineManager::instance()->addRoutine(QStringLiteral("背单词"), -1, RoutineRules::kEveryDayMask));
        QCOMPARE(RoutineManager::instance()->materializeToday(), 1);
    });
    QVERIFY(exec(mac, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                     "VALUES (%1, '%2T09:00:00', '%2T09:25:00', 1500, 1)")
                          .arg(localIdOf(mac, QStringLiteral("tasks"), macTask)).arg(date)));
    QVERIFY(exec(mac, QStringLiteral("INSERT INTO rest_sessions (start_time, end_time, duration, manual) "
                                     "VALUES ('%1T09:25:00', '%1T09:30:00', 300, 0)").arg(date)));
    QVERIFY(exec(mac, QStringLiteral("DELETE FROM tasks WHERE sync_id = '%1'").arg(addTask(mac, QStringLiteral("删掉的")))));
    QVERIFY(SyncStore(mac.connection).recordLocalSetting(QStringLiteral("logic/dayStartHour"), QStringLiteral("5"), false));

    // iPad：自己的测试数据、正在计时的专注、一条知识缺口（本机独有、不同步的表）。
    const QString ipadCategory = addCategory(ipad, QStringLiteral("iPad 科目"));
    const QString ipadTask = addTask(ipad, QStringLiteral("iPad 的测试任务"), date);
    QVERIFY(setTaskCategory(ipad, ipadTask, ipadCategory));
    const qint64 ipadTaskId = localIdOf(ipad, QStringLiteral("tasks"), ipadTask);
    QVERIFY(exec(ipad, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, end_time, duration, mode) "
                                      "VALUES (%1, '%2T08:00:00', '%2T08:25:00', 1500, 1)").arg(ipadTaskId).arg(date)));
    QVERIFY(exec(ipad, QStringLiteral("INSERT INTO focus_sessions (task_id, start_time, mode) "
                                      "VALUES (%1, '%2T10:00:00', 1)").arg(ipadTaskId).arg(date)));
    const qint64 mathId = localIdOf(ipad, QStringLiteral("categories"), QStringLiteral("preset-1"));
    QVERIFY(exec(ipad, QStringLiteral("INSERT INTO knowledge_gaps (title, category_id, source_task_id, created_at, "
                                      "updated_at) VALUES ('极限的定义', %1, %2, '%3', '%3')")
                           .arg(mathId).arg(ipadTaskId).arg(date)));
    QVERIFY(SyncStore(ipad.connection).recordLocalSetting(QStringLiteral("logic/dayStartHour"), QStringLiteral("4"), true));
    // 第二期起知识缺口也同步：Mac 上一条指向预置科目和 Mac 任务的缺口。
    QVERIFY(exec(mac, QStringLiteral("INSERT INTO knowledge_gaps (title, category_id, source_task_id, created_at, "
                                     "updated_at) VALUES ('Mac 的缺口', %1, %2, '%3', '%3')")
                          .arg(localIdOf(mac, QStringLiteral("categories"), QStringLiteral("preset-1")))
                          .arg(localIdOf(mac, QStringLiteral("tasks"), macTask))
                          .arg(date)));

    const SyncBatch snapshot = throughJson(SyncStore(mac.connection).exportSnapshot());
    const SyncStore::ApplyResult result = SyncStore(ipad.connection).replaceWithSnapshot(snapshot);
    QVERIFY2(result.ok, qPrintable(result.error));
    // iPad 自己的任务被换掉了；计时器据此解绑（提交后逐个发 taskDeleted）。逻辑日起点交给调用方写回。
    QVERIFY(result.deletedTaskIds.contains(int(ipadTaskId)));
    QCOMPARE(result.changedSettings.value(QStringLiteral("logic/dayStartHour")), QStringLiteral("5"));

    // 两台的同步数据逐字段、逐版本一致（导出的快照完全相同）。
    QCOMPARE(describe(SyncStore(ipad.connection).exportSnapshot()), describe(SyncStore(mac.connection).exportSnapshot()));
    QCOMPARE(SyncStore(ipad.connection).epoch(), SyncStore(mac.connection).epoch());
    QCOMPARE(count(ipad, QStringLiteral("SELECT COUNT(*) FROM sync_outbox")), 0);
    // 正在计时的那一行不受影响（只是它的任务没了，按删除任务的做法解除关联）。
    QCOMPARE(count(ipad, QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE end_time IS NULL AND task_id IS NULL")), 1);
    // 知识缺口第二期起也同步：iPad 自己的测试缺口随加入换掉；Mac 的那条带过来，引用换成 iPad 本机的编号
    // （预置科目没被删，本机编号不变）。updated_at 不同步，插进来时按本机此刻补上。
    QCOMPARE(count(ipad, QStringLiteral("SELECT COUNT(*) FROM knowledge_gaps WHERE title = '极限的定义'")), 0);
    QCOMPARE(scalar(ipad, QStringLiteral("SELECT category_id FROM knowledge_gaps WHERE title = 'Mac 的缺口'"))
                 .toLongLong(), mathId);
    QCOMPARE(scalar(ipad, QStringLiteral("SELECT source_task_id FROM knowledge_gaps WHERE title = 'Mac 的缺口'"))
                 .toLongLong(), localIdOf(ipad, QStringLiteral("tasks"), macTask));
    QVERIFY(!scalar(ipad, QStringLiteral("SELECT updated_at FROM knowledge_gaps WHERE title = 'Mac 的缺口'"))
                 .toString().isEmpty());
    QCOMPARE(logCount(ipad, QStringLiteral("skipped")), 0);

    // 之后照常增量同步。
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    QVERIFY(SyncStore(mac.connection).markSnapshotPublished(SyncStore(mac.connection).exportSnapshot()));
    QVERIFY(exec(ipad, QStringLiteral("UPDATE tasks SET notes = 'iPad 上补的备注' WHERE sync_id = '%1'").arg(macTask)));
    QVERIFY(exec(mac, QStringLiteral("UPDATE tasks SET title = '写代码（Mac 改）' WHERE sync_id = '%1'").arg(macTask)));
    syncAll(cloud, {mac, ipad});
    for (const Device& device : {mac, ipad}) {
        QCOMPARE(taskValue(device, macTask, QStringLiteral("notes")).toString(), QStringLiteral("iPad 上补的备注"));
        QCOMPARE(taskValue(device, macTask, QStringLiteral("title")).toString(), QStringLiteral("写代码（Mac 改）"));
    }
}

void SyncTests::globalRollbackReplacesOtherDeviceAndRejectsOldEpoch()
{
    // D1：恢复备份 = 全局回滚。两台一起回到备份的状态，另一台在回滚前没同步过来的改动被换掉
    // （调用方事先做了自动备份，能从那里找回）。
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString kept = addTask(a, QStringLiteral("备份之前就有"));
    syncAll(cloud, {a, b});
    const QString backupPath = m_data->filePath(QStringLiteral("a-backup.sqlite"));
    QVERIFY(QFile::copy(a.path, backupPath));

    // 备份之后两台都继续记了东西；B 还有一条没发出去的。
    QVERIFY(!addTask(a, QStringLiteral("A 备份之后加的")).isEmpty());
    QVERIFY(!addTask(b, QStringLiteral("B 备份之后加的")).isEmpty());
    syncAll(cloud, {a, b});
    QVERIFY(!addTask(b, QStringLiteral("B 还没发的")).isEmpty());
    const SyncBatch staleFromB = SyncStore(b.connection).collectPending();

    // A 恢复备份：换回旧库文件，开新纪元（设备标识保持恢复前的），发一份全量快照。
    const qint64 epochBefore = SyncStore(a.connection).epoch();
    QSqlDatabase::database(a.connection, false).close();
    QVERIFY(QFile::remove(a.path));
    QVERIFY(QFile::copy(backupPath, a.path));
    QVERIFY(QSqlDatabase::database(a.connection).isOpen());
    QVERIFY(exec(a, QStringLiteral("PRAGMA foreign_keys = ON")));
    QVERIFY(SyncStore(a.connection).beginEpochAfterRestore(epochBefore, a.id));
    QCOMPARE(SyncStore(a.connection).epoch(), epochBefore + 1);
    QVERIFY(SyncStore(a.connection).needsSnapshot());
    const SyncBatch snapshot = throughJson(SyncStore(a.connection).exportSnapshot());
    QVERIFY(SyncStore(a.connection).markSnapshotPublished(snapshot));
    QVERIFY(!SyncStore(a.connection).needsSnapshot());

    // 回滚之前的旧改动（旧纪元）不能再合进来。
    QVERIFY(!SyncStore(a.connection).applyRemote(staleFromB).ok);
    // B 读到纪元更高的快照：不能当普通改动合并，要整体替换。
    QVERIFY(!SyncStore(b.connection).applyRemote(snapshot).ok);
    const SyncStore::ApplyResult replaced = SyncStore(b.connection).replaceWithSnapshot(snapshot);
    QVERIFY2(replaced.ok, qPrintable(replaced.error));
    QCOMPARE(SyncStore(b.connection).epoch(), epochBefore + 1);
    for (const Device& device : {a, b}) {
        QCOMPARE(taskTitles(device), QStringList{QStringLiteral("备份之前就有")});
    }
    QCOMPARE(describe(SyncStore(b.connection).exportSnapshot()), describe(SyncStore(a.connection).exportSnapshot()));

    // 回滚之后的新改动照常同步（新纪元）。旧纪元的文件不再读：换一个云盘文件夹，相当于传输层只读新纪元的文件。
    FakeCloud fresh(m_data->filePath(QStringLiteral("cloud-epoch-1")));
    QVERIFY(exec(b, QStringLiteral("UPDATE tasks SET notes = '回滚后补的' WHERE sync_id = '%1'").arg(kept)));
    syncAll(fresh, {a, b});
    QCOMPARE(taskValue(a, kept, QStringLiteral("notes")).toString(), QStringLiteral("回滚后补的"));
}

void SyncTests::publishedSnapshotAcknowledgesQueuedChanges()
{
    // Mac 第一次开启同步：写出快照，快照已经带上的改动不必再单独发；快照导出之后才改的仍然待发送。
    Device a = openDevice(QStringLiteral("a"));
    const QString first = addTask(a, QStringLiteral("第一条"));
    QVERIFY(!SyncStore(a.connection).collectPending().isEmpty());
    const SyncBatch snapshot = SyncStore(a.connection).exportSnapshot();
    QVERIFY(exec(a, QStringLiteral("UPDATE tasks SET title = '快照之后改的' WHERE sync_id = '%1'").arg(first)));
    QVERIFY(SyncStore(a.connection).markSnapshotPublished(snapshot));

    const SyncBatch pending = SyncStore(a.connection).collectPending();
    QCOMPARE(pending.records.size(), 1);
    QCOMPARE(pending.records.first().syncId, first);
    QCOMPARE(pending.records.first().fields.value(QStringLiteral("title")).value.toString(),
             QStringLiteral("快照之后改的"));
}

// ── 2f：提交后的精确通知 ──
//
// 这几条用单例库当「本机」：各服务的信号挂在单例上，计时器也只认单例库。

void SyncTests::notificationsFollowChangedTablesInOrder()
{
    RoutineManager::instance();  // 先建出例行管理器：它会把 categoriesChanged 转成 routinesChanged
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("要被远端删的"), today(), -1, 0, QString());
    const int categoryId = CategoryManager::instance()->addCategory(QStringLiteral("编程"), QStringLiteral("#123456"));
    QVERIFY(taskId > 0 && categoryId > 0);
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    const SyncVersion version{kFuture, remote};

    SyncBatch batch;
    batch.device = remote;
    batch.records.append(remoteDeletion(QStringLiteral("tasks"), syncIdOf(QStringLiteral("tasks"), taskId), version));
    SyncRecord renamed;
    renamed.table = QStringLiteral("categories");
    renamed.syncId = syncIdOf(QStringLiteral("categories"), categoryId);
    renamed.fields.insert(QStringLiteral("name"), {QStringLiteral("计算机"), version, {}});
    batch.records.append(renamed);
    SyncRecord session;
    session.table = QStringLiteral("focus_sessions");
    session.syncId = QStringLiteral("remote-session");
    session.fields.insert(QStringLiteral("start_time"), {QStringLiteral("2026-09-30T09:00:00"), version, {}});
    session.fields.insert(QStringLiteral("end_time"), {QStringLiteral("2026-09-30T09:25:00"), version, {}});
    session.fields.insert(QStringLiteral("duration"), {qint64(1500), version, {}});
    batch.records.append(session);
    batch.settings.append({QStringLiteral("logic/dayStartHour"), QStringLiteral("5"), version, {}});

    SignalRecorder recorder;
    const SyncStore::ApplyResult result = SyncStore().applyRemote(batch);
    QVERIFY2(result.ok, qPrintable(result.error));
    // 应用过程本身一个信号都不发：事务提交之前发出去，失败回滚时就收不回来了。
    QVERIFY(recorder.events.isEmpty());

    SyncNotifier::publish(result);
    const QString deleted = QStringLiteral("taskDeleted:%1").arg(taskId);
    // 先删除事实、后列表刷新：计时器这类持有任务编号的服务先解绑。
    QCOMPARE(recorder.events.first(), deleted);
    QVERIFY(recorder.events.indexOf(QStringLiteral("tasksChanged")) > recorder.events.indexOf(deleted));
    for (const char* expected : {"categoriesChanged", "routinesChanged", "historyChanged", "dayStartHourChanged"}) {
        QVERIFY2(recorder.events.contains(QString::fromLatin1(expected)), expected);
    }
    // 逻辑日起点写回了 AppSettings。
    QCOMPARE(AppSettings::instance()->dayStartHour(), 5);

    // 只动了专注记录的一批：不发科目、例行的信号，也不整库重载。
    SignalRecorder onlyHistory;
    SyncBatch sessionsOnly;
    sessionsOnly.device = remote;
    SyncRecord longer = session;
    longer.fields.insert(QStringLiteral("duration"), {qint64(1200), {kFuture + 1, remote}, {}});
    sessionsOnly.records.append(longer);
    const SyncStore::ApplyResult second = SyncStore().applyRemote(sessionsOnly);
    QVERIFY(second.ok);
    SyncNotifier::publish(second);
    QVERIFY(!onlyHistory.events.contains(QStringLiteral("categoriesChanged")));
    QVERIFY(!onlyHistory.events.contains(QStringLiteral("routinesChanged")));
    QVERIFY(onlyHistory.events.contains(QStringLiteral("historyChanged")));
}

void SyncTests::failedApplyPublishesNothing()
{
    RoutineManager::instance();
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("还在的任务"), today(), -1, 0, QString());
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    SyncBatch batch;
    batch.device = remote;
    batch.epoch = 7;  // 纪元不对：整批拒绝
    batch.records.append(remoteDeletion(QStringLiteral("tasks"), syncIdOf(QStringLiteral("tasks"), taskId),
                                        {kFuture, remote}));

    SignalRecorder recorder;
    const SyncStore::ApplyResult result = SyncStore().applyRemote(batch);
    QVERIFY(!result.ok);
    SyncNotifier::publish(result);
    QVERIFY(recorder.events.isEmpty());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM tasks WHERE id = %1").arg(taskId)), 1);
}

void SyncTests::remoteDeletionUnbindsRunningTimer()
{
    // 另一台删掉了本机正在计时的任务：计时照常继续，只是不再挂在这条任务上，
    // 活动状态里也不能留着旧编号，否则重启恢复时会带回一个已经不存在的任务。
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("正在计时的"), today(), -1, 0, QString());
    QVERIFY(FocusTimer::instance()->startFocus(taskId, QStringLiteral("正在计时的")));
    QCOMPARE(FocusTimer::instance()->currentTaskId(), taskId);

    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    SyncBatch batch;
    batch.device = remote;
    batch.records.append(remoteDeletion(QStringLiteral("tasks"), syncIdOf(QStringLiteral("tasks"), taskId),
                                        {kFuture, remote}));
    const SyncStore::ApplyResult result = SyncStore().applyRemote(batch);
    QVERIFY2(result.ok, qPrintable(result.error));
    QVERIFY(result.deletedTaskIds.contains(taskId));
    SyncNotifier::publish(result);

    QCOMPARE(FocusTimer::instance()->currentTaskId(), -1);
    QVERIFY(FocusTimer::instance()->hasActiveSession());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM focus_sessions WHERE end_time IS NULL AND task_id IS NULL")), 1);
    QVERIFY(scalar(QStringLiteral("SELECT task_id FROM active_focus_state")).isNull());
}

// ── 051 阶段 1：课表、知识缺口、目标倒计时 ──

void SyncTests::phaseTwoTablesTravelWithLocalReferences()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    // B 先有几条自己的，两台设备的本机编号就错开了：引用必须按身份换成 B 本机的编号，而不是照抄 A 的数字。
    QVERIFY(!addCategory(b, QStringLiteral("B 的科目")).isEmpty());
    QVERIFY(!addTask(b, QStringLiteral("B 的任务")).isEmpty());
    QVERIFY(!addTask(b, QStringLiteral("B 的另一条任务")).isEmpty());

    const QString programming = addCategory(a, QStringLiteral("编程"));
    const QString task = addTask(a, QStringLiteral("写代码"));
    const QString entry = addScheduleEntry(a, QStringLiteral("高等数学"), programming);
    const QString gap = addGap(a, QStringLiteral("极限的定义"), programming, task, task);
    const QString goal = addCountdown(a, QStringLiteral("期末考试"), 0, QStringLiteral("2026-09-30T08:00:00"));
    QVERIFY(!entry.isEmpty() && !gap.isEmpty() && !goal.isEmpty());
    syncAll(cloud, {a, b});

    const qint64 categoryOnB = localIdOf(b, QStringLiteral("categories"), programming);
    const qint64 taskOnB = localIdOf(b, QStringLiteral("tasks"), task);
    QVERIFY(categoryOnB != localIdOf(a, QStringLiteral("categories"), programming));
    QVERIFY(taskOnB != localIdOf(a, QStringLiteral("tasks"), task));
    QCOMPARE(valueOf(b, QStringLiteral("schedule_entries"), entry, QStringLiteral("title")).toString(),
             QStringLiteral("高等数学"));
    QCOMPARE(valueOf(b, QStringLiteral("schedule_entries"), entry, QStringLiteral("category_id")).toLongLong(),
             categoryOnB);
    QCOMPARE(valueOf(b, QStringLiteral("knowledge_gaps"), gap, QStringLiteral("category_id")).toLongLong(), categoryOnB);
    QCOMPARE(valueOf(b, QStringLiteral("knowledge_gaps"), gap, QStringLiteral("source_task_id")).toLongLong(), taskOnB);
    QCOMPARE(valueOf(b, QStringLiteral("knowledge_gaps"), gap, QStringLiteral("linked_task_id")).toLongLong(), taskOnB);
    QCOMPARE(valueOf(b, QStringLiteral("knowledge_gaps"), gap, QStringLiteral("source_task_title")).toString(),
             QStringLiteral("写代码"));
    QCOMPARE(valueOf(b, QStringLiteral("countdown_goals"), goal, QStringLiteral("name")).toString(),
             QStringLiteral("期末考试"));
    // updated_at 不同步：插进 B 时按 B 此刻补上，不为空。
    QVERIFY(!valueOf(b, QStringLiteral("knowledge_gaps"), gap, QStringLiteral("updated_at")).toString().isEmpty());
    QVERIFY(!valueOf(b, QStringLiteral("countdown_goals"), goal, QStringLiteral("updated_at")).toString().isEmpty());
    QCOMPARE(describe(SyncStore(b.connection).exportSnapshot()), describe(SyncStore(a.connection).exportSnapshot()));
}

void SyncTests::phaseTwoConcurrentEditsMergeFieldByField()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString entry = addScheduleEntry(a, QStringLiteral("高等数学"));
    const QString gap = addGap(a, QStringLiteral("极限的定义"));
    syncAll(cloud, {a, b});

    // 两边同时改：知识缺口改的是不同字段（都保留），课表改的是同一字段（后改的 B 为准，A 的记进日志）。
    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture + 1000));
    QVERIFY(exec(a, QStringLiteral("UPDATE knowledge_gaps SET status = 1 WHERE sync_id = '%1'").arg(gap)));
    QVERIFY(exec(b, QStringLiteral("UPDATE knowledge_gaps SET title = '极限的严格定义' WHERE sync_id = '%1'").arg(gap)));
    QVERIFY(exec(a, QStringLiteral("UPDATE schedule_entries SET location = 'A 楼' WHERE sync_id = '%1'").arg(entry)));
    QVERIFY(exec(b, QStringLiteral("UPDATE schedule_entries SET location = 'B 楼' WHERE sync_id = '%1'").arg(entry)));
    syncAll(cloud, {a, b});

    for (const Device& device : {a, b}) {
        QCOMPARE(valueOf(device, QStringLiteral("knowledge_gaps"), gap, QStringLiteral("status")).toInt(), 1);
        QCOMPARE(valueOf(device, QStringLiteral("knowledge_gaps"), gap, QStringLiteral("title")).toString(),
                 QStringLiteral("极限的严格定义"));
        QCOMPARE(valueOf(device, QStringLiteral("schedule_entries"), entry, QStringLiteral("location")).toString(),
                 QStringLiteral("B 楼"));
    }
    // 冲突日志写得出人话：哪张表、哪一项、留下谁的。
    const QList<SyncStore::LogEntry> log = SyncStore(a.connection).syncLog(10);
    QCOMPARE(log.size(), 1);
    QCOMPARE(log.first().tableLabel, QStringLiteral("课表"));
    QCOMPARE(log.first().recordLabel, QStringLiteral("高等数学"));
    QCOMPARE(log.first().fieldLabel, QStringLiteral("地点"));
    QCOMPARE(log.first().lostValue, QStringLiteral("A 楼"));
    QCOMPARE(log.first().keptValue, QStringLiteral("B 楼"));
}

void SyncTests::deletedTaskDetachesKnowledgeGaps()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString task = addTask(a, QStringLiteral("写代码"));
    syncAll(cloud, {a, b});
    // B 上记了一条指向这个任务的知识缺口，还没同步出去；A 这时删掉了任务。
    const QString gap = addGap(b, QStringLiteral("闭包是什么"), QString(), task, task);

    // B 收到删除：知识缺口留着，来源任务和关联任务由外键置空（与本机删任务时一致），记下的来源任务名称还在。
    // A 那一批里只有任务的删除记录、没有这条缺口，界面要刷新知识缺口，只能靠删任务时把它算进「变了的表」。
    QVERIFY(exec(a, QStringLiteral("DELETE FROM tasks WHERE sync_id = '%1'").arg(task)));
    QVERIFY(cloud.publish(a) > 0);
    bool gapsTouched = false;
    for (const SyncStore::ApplyResult& result : cloud.pull(b)) {
        QVERIFY2(result.ok, qPrintable(result.error));
        gapsTouched = gapsTouched || result.changedTables.contains(QStringLiteral("knowledge_gaps"));
    }
    QVERIFY(gapsTouched);
    syncAll(cloud, {a, b});
    for (const Device& device : {a, b}) {
        QCOMPARE(count(device, QStringLiteral("SELECT COUNT(*) FROM knowledge_gaps WHERE sync_id = '%1'").arg(gap)), 1);
        QVERIFY(valueOf(device, QStringLiteral("knowledge_gaps"), gap, QStringLiteral("source_task_id")).isNull());
        QVERIFY(valueOf(device, QStringLiteral("knowledge_gaps"), gap, QStringLiteral("linked_task_id")).isNull());
        QCOMPARE(valueOf(device, QStringLiteral("knowledge_gaps"), gap, QStringLiteral("source_task_title")).toString(),
                 QStringLiteral("写代码"));
    }
    QCOMPARE(describe(SyncStore(b.connection).exportSnapshot()), describe(SyncStore(a.connection).exportSnapshot()));
}

void SyncTests::deletedCategoryClearsScheduleAndGapCategories()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString programming = addCategory(a, QStringLiteral("编程"));
    syncAll(cloud, {a, b});
    // A 上新建了用这个科目的课表项和知识缺口，还没同步出去；B 这时删掉了科目。
    const QString entry = addScheduleEntry(a, QStringLiteral("数据结构"), programming);
    const QString gap = addGap(a, QStringLiteral("红黑树"), programming);

    // A 收到删除：课表项和知识缺口变成未分类，不跟着删。B 那一批里只有科目的删除记录，
    // 两张表都要刷新，只能靠删科目时把它们算进「变了的表」。
    QVERIFY(exec(b, QStringLiteral("DELETE FROM categories WHERE sync_id = '%1'").arg(programming)));
    QVERIFY(cloud.publish(b) > 0);
    QSet<QString> touched;
    for (const SyncStore::ApplyResult& result : cloud.pull(a)) {
        QVERIFY2(result.ok, qPrintable(result.error));
        touched.unite(result.changedTables);
    }
    QVERIFY(touched.contains(QStringLiteral("schedule_entries")));
    QVERIFY(touched.contains(QStringLiteral("knowledge_gaps")));
    syncAll(cloud, {a, b});
    for (const Device& device : {a, b}) {
        QVERIFY(valueOf(device, QStringLiteral("schedule_entries"), entry, QStringLiteral("category_id")).isNull());
        QVERIFY(valueOf(device, QStringLiteral("knowledge_gaps"), gap, QStringLiteral("category_id")).isNull());
    }
    QCOMPARE(describe(SyncStore(b.connection).exportSnapshot()), describe(SyncStore(a.connection).exportSnapshot()));
}

void SyncTests::countdownOrderConvergesAfterConcurrentInserts()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    // 两台各自新建一个倒计时，都排在第一位（排序号 0）：同步后排序号不能撞，两台的顺序要一样。
    // 排序号相同按创建时间先后，期中考试在前。
    QVERIFY(!addCountdown(b, QStringLiteral("四级考试"), 0, QStringLiteral("2026-09-02T08:00:00")).isEmpty());
    QVERIFY(!addCountdown(a, QStringLiteral("期中考试"), 0, QStringLiteral("2026-09-01T08:00:00")).isEmpty());
    syncAll(cloud, {a, b});
    const QStringList expected{QStringLiteral("0:期中考试"), QStringLiteral("1:四级考试")};
    QCOMPARE(countdownOrder(a), expected);
    QCOMPARE(countdownOrder(b), expected);
    QCOMPARE(describe(SyncStore(b.connection).exportSnapshot()), describe(SyncStore(a.connection).exportSnapshot()));
}

void SyncTests::phaseTwoNotificationsRefreshOnlyTheirServices()
{
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    const SyncVersion version{kFuture, remote};
    const auto batchWith = [&](const SyncRecord& record) {
        SyncBatch batch;
        batch.device = remote;
        batch.records.append(record);
        return batch;
    };
    SyncRecord entry;
    entry.table = QStringLiteral("schedule_entries");
    entry.syncId = QStringLiteral("remote-entry");
    for (const auto& field : QList<QPair<QString, QVariant>>{
             {QStringLiteral("title"), QStringLiteral("线性代数")}, {QStringLiteral("location"), QStringLiteral("")},
             {QStringLiteral("weekday"), 2}, {QStringLiteral("start_minutes"), 600}, {QStringLiteral("end_minutes"), 645},
             {QStringLiteral("week_start"), 1}, {QStringLiteral("week_end"), 16}, {QStringLiteral("week_parity"), 0},
             {QStringLiteral("created_at"), QStringLiteral("2026-09-30 08:00:00")}}) {
        entry.fields.insert(field.first, {field.second, version, {}});
    }
    SyncRecord gap;
    gap.table = QStringLiteral("knowledge_gaps");
    gap.syncId = QStringLiteral("remote-gap");
    for (const auto& field : QList<QPair<QString, QVariant>>{
             {QStringLiteral("title"), QStringLiteral("特征值")}, {QStringLiteral("priority"), 1},
             {QStringLiteral("status"), 0}, {QStringLiteral("created_at"), QStringLiteral("2026-09-30T08:00:00")}}) {
        gap.fields.insert(field.first, {field.second, version, {}});
    }
    SyncRecord goal;
    goal.table = QStringLiteral("countdown_goals");
    goal.syncId = QStringLiteral("remote-goal");
    for (const auto& field : QList<QPair<QString, QVariant>>{
             {QStringLiteral("name"), QStringLiteral("期末考试")}, {QStringLiteral("target_date"), QStringLiteral("2027-01-10")},
             {QStringLiteral("display_order"), 0}, {QStringLiteral("created_at"), QStringLiteral("2026-09-30T08:00:00")}}) {
        goal.fields.insert(field.first, {field.second, version, {}});
    }

    // 只动了哪张表，就只刷新那个服务：课表、知识缺口、倒计时互不牵连，也不整库重载。
    const QList<QPair<SyncRecord, QString>> cases{{entry, QStringLiteral("scheduleChanged")},
                                                  {gap, QStringLiteral("gapsChanged")},
                                                  {goal, QStringLiteral("goalsReloaded")}};
    const QStringList all{QStringLiteral("scheduleChanged"), QStringLiteral("gapsChanged"),
                          QStringLiteral("goalsReloaded"), QStringLiteral("tasksChanged"),
                          QStringLiteral("categoriesChanged")};
    for (const auto& item : cases) {
        const SyncStore::ApplyResult result = SyncStore().applyRemote(batchWith(item.first));
        QVERIFY2(result.ok, qPrintable(result.error));
        SignalRecorder recorder;
        SyncNotifier::publish(result);
        for (const QString& event : all) {
            QVERIFY2(recorder.events.contains(event) == (event == item.second),
                     qPrintable(item.second + QStringLiteral(" / ") + event));
        }
    }
    // 倒计时服务真的重新读了库：远端新建的那个出现在它的列表里。
    QCOMPARE(CountdownService::instance()->model()->rowCount(), 1);
}

void SyncTests::migrationFromV18QueuesPhaseTwoRows()
{
    // 用当前代码建出数据，再把第二期三张表的同步结构拆掉、版本号退回 18，就是一份 v18 的库。
    // 倒计时表整个删掉：倒计时服务懒建这张表，从没打开过倒计时的 v18 库里本来就没有它。
    const int taskId = TaskManager::instance()->createTask(QStringLiteral("写代码"), today(), -1, 0, QString());
    QVERIFY(taskId > 0);
    QVERIFY(exec(QStringLiteral("INSERT INTO schedule_entries (title, weekday, start_minutes, end_minutes) "
                                "VALUES ('高等数学', 1, 480, 525)")));
    QVERIFY(exec(QStringLiteral("INSERT INTO knowledge_gaps (title, source_task_id, created_at, updated_at) "
                                "VALUES ('极限', %1, '2026-09-30T08:00:00', '2026-09-30T08:00:00')").arg(taskId)));
    QVERIFY(markEverythingSent());
    const QStringList phaseTwo{QStringLiteral("schedule_entries"), QStringLiteral("knowledge_gaps"),
                               QStringLiteral("countdown_goals")};
    for (const auto& trigger : SyncSchema::triggers()) {
        for (const QString& table : phaseTwo) {
            if (trigger.first.startsWith(table + QStringLiteral("_sync_"))) {
                QVERIFY(exec(QStringLiteral("DROP TRIGGER %1").arg(trigger.first)));
            }
        }
    }
    for (const QString& table : phaseTwo) {
        QVERIFY(exec(QStringLiteral("DELETE FROM sync_field_versions WHERE tbl = '%1'").arg(table)));
        QVERIFY(exec(QStringLiteral("DROP INDEX idx_%1_sync_id").arg(table)));
    }
    QVERIFY(exec(QStringLiteral("ALTER TABLE schedule_entries DROP COLUMN sync_id")));
    QVERIFY(exec(QStringLiteral("ALTER TABLE knowledge_gaps DROP COLUMN sync_id")));
    QVERIFY(exec(QStringLiteral("DROP TABLE countdown_goals")));
    QVERIFY(exec(QStringLiteral("PRAGMA user_version = 18")));

    const QDir dir = QFileInfo(db().databaseName()).absoluteDir();
    const QStringList pattern{QStringLiteral("pomodoro_backup_*.db")};
    const qsizetype snapshotsBefore = dir.entryList(pattern, QDir::Files).size();
    QVERIFY(DatabaseManager::instance()->createTables());

    // 升级前留了一份迁移快照（升到 v19 之后 v18 的应用打不开这个库）；版本推到当前版本；触发器全部装好。
    QCOMPARE(dir.entryList(pattern, QDir::Files).size(), snapshotsBefore + 1);
    QCOMPARE(scalar(QStringLiteral("PRAGMA user_version")).toInt(), DatabaseManager::kCurrentSchemaVersion);
    QCOMPARE(triggerSql(), SyncSchema::canonicalTriggerSql());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM pragma_table_info('countdown_goals') WHERE name = 'sync_id'")), 1);

    // 已有的课表项和知识缺口有了身份、放进待发送；第一期的记录早就发过了，不重新排队。
    for (const QString& table : phaseTwo) {
        QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM %1 WHERE sync_id IS NULL OR sync_id = ''").arg(table)), 0);
    }
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox WHERE tbl = 'schedule_entries'")), 1);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox WHERE tbl = 'knowledge_gaps'")), 1);
    QVERIFY(!queued(QStringLiteral("tasks"), syncIdOf(QStringLiteral("tasks"), taskId)));

    // 升级后本机的修改照常记版本。
    QVERIFY(markEverythingSent());
    QVERIFY(exec(QStringLiteral("UPDATE knowledge_gaps SET status = 2")));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox WHERE tbl = 'knowledge_gaps'")), 1);
    QVERIFY(exec(QStringLiteral("INSERT INTO countdown_goals (name, target_date, display_order, created_at, updated_at) "
                                "VALUES ('期末', '2027-01-10', 0, '2026-09-30T08:00:00', '2026-09-30T08:00:00')")));
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox WHERE tbl = 'countdown_goals'")), 1);
}

// ── 051 阶段 2：设置 ──

void SyncTests::snapshotReplacementReportsSettingsItLacks()
{
    Device mac = openDevice(QStringLiteral("mac"));
    Device ipad = openDevice(QStringLiteral("ipad"));
    const QString key = QStringLiteral("logic/dayStartHour");
    const QString macGoal = SyncSchema::dailyGoalSettingKey(QStringLiteral("2026-09-30"));
    const QString ipadGoal = SyncSchema::dailyGoalSettingKey(QStringLiteral("2026-09-01"));
    QVERIFY(SyncStore(mac.connection).recordLocalSetting(key, QStringLiteral("5"), false));
    QVERIFY(SyncStore(mac.connection).recordLocalSetting(macGoal, QStringLiteral("120"), false));
    // iPad 上测试时设过的另一天的目标：Mac 的快照里没有这一天。
    QVERIFY(SyncStore(ipad.connection).recordLocalSetting(key, QStringLiteral("4"), true));
    QVERIFY(SyncStore(ipad.connection).recordLocalSetting(ipadGoal, QStringLiteral("30"), false));

    const SyncStore::ApplyResult result =
        SyncStore(ipad.connection).replaceWithSnapshot(throughJson(SyncStore(mac.connection).exportSnapshot()));
    QVERIFY2(result.ok, qPrintable(result.error));
    // 以快照为准：快照里有的写回，快照里没有的那一天交给调用方从本机删掉（只从库里删，下次启动又会被当成本机改动发回去）。
    QCOMPARE(result.changedSettings.value(key), QStringLiteral("5"));
    QCOMPARE(result.changedSettings.value(macGoal), QStringLiteral("120"));
    QCOMPARE(result.removedSettings, QSet<QString>{ipadGoal});
    QVERIFY(SyncStore(ipad.connection).syncedSetting(ipadGoal).isEmpty());
}

void SyncTests::settingConflictsReadAsPlainText()
{
    Device a = openDevice(QStringLiteral("a"));
    Device b = openDevice(QStringLiteral("b"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    const QString work = QStringLiteral("focus/workMinutes");
    const QString periods = QStringLiteral("schedule/periods");
    QVERIFY(SyncStore(a.connection).recordLocalSetting(work, QStringLiteral("25"), true));
    QVERIFY(SyncStore(b.connection).recordLocalSetting(work, QStringLiteral("25"), true));
    syncAll(cloud, {a, b});

    // 两边同时改番茄时长和整张节次表：后改的 B 为准，A 输掉的值记进日志，名字和取值都是给人看的说法。
    QVERIFY(setClock(a, kFuture));
    QVERIFY(setClock(b, kFuture + 1000));
    QVERIFY(SyncStore(a.connection).recordLocalSetting(work, QStringLiteral("50"), false));
    QVERIFY(SyncStore(b.connection).recordLocalSetting(work, QStringLiteral("40"), false));
    QVERIFY(SyncStore(a.connection).recordLocalSetting(periods, QStringLiteral("[[480,525],[535,580]]"), false));
    QVERIFY(SyncStore(b.connection).recordLocalSetting(periods, QStringLiteral("[[490,535]]"), false));
    syncAll(cloud, {a, b});
    for (const Device& device : {a, b}) {
        QCOMPARE(SyncStore(device.connection).syncedSetting(work), QStringLiteral("40"));
        QCOMPARE(SyncStore(device.connection).syncedSetting(periods), QStringLiteral("[[490,535]]"));
    }
    QHash<QString, SyncStore::LogEntry> byField;
    for (const SyncStore::LogEntry& entry : SyncStore(a.connection).syncLog(10)) {
        byField.insert(entry.fieldLabel, entry);
    }
    QCOMPARE(byField.size(), 2);
    QCOMPARE(byField.value(QStringLiteral("番茄时长")).lostValue, QStringLiteral("50 分钟"));
    QCOMPARE(byField.value(QStringLiteral("番茄时长")).keptValue, QStringLiteral("40 分钟"));
    QCOMPARE(byField.value(QStringLiteral("课表节次")).lostValue, QStringLiteral("2 节，08:00–09:40"));
    QCOMPARE(byField.value(QStringLiteral("课表节次")).keptValue, QStringLiteral("1 节，08:10–08:55"));
}


void SyncTests::memosTravelWithContentTimeAndNullableCategory()
{
    // 产品保证：新建备忘的五个字段完整到达，科目按身份接回；更新时间是修改时刻，不能是接收时刻。
    const Device a = openDevice(QStringLiteral("memo-a"));
    const Device b = openDevice(QStringLiteral("memo-b"));
    QVERIFY(!addCategory(b, QStringLiteral("占用编号")).isEmpty());
    const QString cat = addCategory(a, QStringLiteral("学习"));
    constexpr qint64 time = 1900000000728;
    QVERIFY(setClock(a, time));
    const QString id = addMemo(a, QString(), QStringLiteral("第一行\r\n第二行"), cat);
    QVERIFY(!id.isEmpty());
    const QString plain = addMemo(a, QStringLiteral("未分类"), QStringLiteral("原文"));
    SyncStore sa(a.connection), sb(b.connection);
    const SyncBatch batch = throughJson(sa.collectPending());
    const SyncRecord record = memoRecord(batch, id);
    QCOMPARE(record.fields.size(), 5);
    QVERIFY(!record.fields.contains(QStringLiteral("updated_at")));
    QCOMPARE(record.fields.value(QStringLiteral("category_id")).value.toString(), cat);
    QCOMPARE(record.fields.value(QStringLiteral("body")).version.time, time);
    QVERIFY(setClock(b, time + 900000));
    const auto result = sb.applyRemote(batch);
    QVERIFY2(result.ok, qPrintable(result.error));
    QCOMPARE(result.skippedRecords, 0);
    QVERIFY(result.changedTables.contains(QStringLiteral("memos")));
    QVERIFY(localIdOf(a, QStringLiteral("categories"), cat) != localIdOf(b, QStringLiteral("categories"), cat));
    QCOMPARE(memoCategory(b, id), cat);
    QVERIFY(valueOf(b, QStringLiteral("memos"), plain, QStringLiteral("category_id")).isNull());
    for (const QString& field : {QStringLiteral("title"), QStringLiteral("body"), QStringLiteral("sort_order"),
                                 QStringLiteral("created_at"), QStringLiteral("updated_at")}) {
        QCOMPARE(valueOf(b, QStringLiteral("memos"), id, field), valueOf(a, QStringLiteral("memos"), id, field));
    }
    QCOMPARE(valueOf(b, QStringLiteral("memos"), id, QStringLiteral("updated_at")).toString(), memoStamp(time));
}

void SyncTests::memoEditsMergeAndKeepFullLosingBody()
{
    // 产品保证：不同字段的改动都保留；同一字段以后改的赢，输掉的完整正文可从日志找回。
    const Device a = openDevice(QStringLiteral("memo-a"));
    const Device b = openDevice(QStringLiteral("memo-b"));
    constexpr qint64 time = 1900000000728;
    QVERIFY(setClock(a, time));
    const QString id = addMemo(a, QStringLiteral("原题"), QStringLiteral("原文"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    syncAll(cloud, {a, b});
    QVERIFY(setClock(a, time + 100));
    QVERIFY(exec(a, QStringLiteral("UPDATE memos SET title='新题' WHERE sync_id='%1'").arg(id)));
    QVERIFY(setClock(b, time + 200));
    QVERIFY(exec(b, QStringLiteral("UPDATE memos SET body='另一台的正文' WHERE sync_id='%1'").arg(id)));
    syncAll(cloud, {a, b});
    for (const Device& d : {a, b}) {
        QCOMPARE(valueOf(d, QStringLiteral("memos"), id, QStringLiteral("title")).toString(), QStringLiteral("新题"));
        QCOMPARE(valueOf(d, QStringLiteral("memos"), id, QStringLiteral("body")).toString(), QStringLiteral("另一台的正文"));
        QCOMPARE(valueOf(d, QStringLiteral("memos"), id, QStringLiteral("updated_at")).toString(), memoStamp(time + 200));
        QCOMPARE(logCount(d), 0);
    }
    const QString lost = QString(3000, QChar(0x7532)) + QStringLiteral("\n独有末尾甲");
    const QString kept = QString(3100, QChar(0x4e59)) + QStringLiteral("\n独有末尾乙");
    auto edit = [&](const Device& d, const QString& body, qint64 t) {
        QVERIFY(setClock(d, t));
        QSqlQuery q(deviceDb(d));
        q.prepare(QStringLiteral("UPDATE memos SET body=? WHERE sync_id=?"));
        q.addBindValue(body); q.addBindValue(id);
        QVERIFY(q.exec());
    };
    edit(a, lost, time + 300);
    edit(b, kept, time + 400);
    const auto av = memoRecord(SyncStore(a.connection).collectPending(), id).fields.value(QStringLiteral("body"));
    const auto bv = memoRecord(SyncStore(b.connection).collectPending(), id).fields.value(QStringLiteral("body"));
    QVERIFY(av.value != bv.value && av.version.time < bv.version.time);
    QCOMPARE(av.base, bv.base); // 共同基础，才是真正并发，不能拿顺序修改冒充冲突。
    syncAll(cloud, {a, b});
    for (const Device& d : {a, b}) {
        QCOMPARE(valueOf(d, QStringLiteral("memos"), id, QStringLiteral("body")).toString(), kept);
        QCOMPARE(valueOf(d, QStringLiteral("memos"), id, QStringLiteral("updated_at")).toString(), memoStamp(time + 400));
        const auto logs = SyncStore(d.connection).syncLog(10);
        QCOMPARE(logs.size(), 1);
        QCOMPARE(logs.first().fieldLabel, QStringLiteral("正文"));
        QCOMPARE(logs.first().recordLabel, QStringLiteral("新题"));
        QCOMPARE(logs.first().lostValue, lost);
        QCOMPARE(logs.first().keptValue, kept);
    }
}

void SyncTests::memoSortingAndLosingEditsKeepContentTime()
{
    // 产品保证：对方只拖动排序或发来输掉的内容版本，列表里的内容更新时间都不动。
    const Device a = openDevice(QStringLiteral("memo-a"));
    const Device b = openDevice(QStringLiteral("memo-b"));
    constexpr qint64 time = 1900000000728;
    QVERIFY(setClock(a, time));
    const QString first = addMemo(a, QStringLiteral("第一条"), QStringLiteral("正文"));
    const QString second = addMemo(a, QStringLiteral("第二条"), QStringLiteral("正文"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    syncAll(cloud, {a, b});
    const QVariant stamp = valueOf(a, QStringLiteral("memos"), first, QStringLiteral("updated_at"));
    QVERIFY(setClock(a, time + 100));
    withServices(a, [&] {
        QVERIFY(MemoService::instance()->reorderMemos(0, {localIdOf(a, QStringLiteral("memos"), second),
                                                        localIdOf(a, QStringLiteral("memos"), first)}));
    });
    QCOMPARE(valueOf(a, QStringLiteral("memos"), first, QStringLiteral("sort_order")).toInt(), 2);
    const SyncBatch sorted = SyncStore(a.connection).collectPending();
    const auto fields = memoRecord(sorted, first).fields;
    QVERIFY(fields.value(QStringLiteral("sort_order")).version.time > fields.value(QStringLiteral("body")).version.time);
    syncAll(cloud, {a, b});
    QCOMPARE(valueOf(a, QStringLiteral("memos"), first, QStringLiteral("updated_at")), stamp);
    QCOMPARE(valueOf(b, QStringLiteral("memos"), first, QStringLiteral("updated_at")), stamp);
    QVERIFY(setClock(b, time + 400));
    QVERIFY(exec(b, QStringLiteral("UPDATE memos SET title='较新标题' WHERE sync_id='%1'").arg(first)));
    const QVariant newer = valueOf(b, QStringLiteral("memos"), first, QStringLiteral("updated_at"));
    SyncBatch stale = sorted;
    stale.records = {memoRecord(sorted, first)};
    stale.records[0].fields[QStringLiteral("title")].value = QStringLiteral("过期标题");
    const auto incoming = stale.records.first().fields.value(QStringLiteral("title"));
    QVERIFY(incoming.version.time < time + 400);
    const auto result = SyncStore(b.connection).applyRemote(stale);
    QVERIFY(result.ok);
    QCOMPARE(valueOf(b, QStringLiteral("memos"), first, QStringLiteral("title")).toString(), QStringLiteral("较新标题"));
    QCOMPARE(valueOf(b, QStringLiteral("memos"), first, QStringLiteral("updated_at")), newer);
}


void SyncTests::memoCategoryEditsAdvanceContentTime()
{
    // 产品保证：只改科目也算内容更新，两台按科目字段版本显示同一个 UTC 毫秒时间。
    const Device a = openDevice(QStringLiteral("memo-a"));
    const Device b = openDevice(QStringLiteral("memo-b"));
    const QString oldCat = addCategory(a, QStringLiteral("原科目"));
    const QString newCat = addCategory(a, QStringLiteral("新科目"));
    constexpr qint64 time = 1900000000728;
    QVERIFY(setClock(a, time));
    const QString id = addMemo(a, QStringLiteral("移科目"), QStringLiteral("正文"), oldCat);
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    syncAll(cloud, {a, b});
    const QVariant before = valueOf(a, QStringLiteral("memos"), id, QStringLiteral("updated_at"));
    QVERIFY(memoCategory(a, id) == oldCat && oldCat != newCat);
    QVERIFY(setClock(a, time + 500));
    withServices(a, [&] {
        QVERIFY(MemoService::instance()->updateMemo(int(localIdOf(a, QStringLiteral("memos"), id)),
                {{QStringLiteral("categoryId"), localIdOf(a, QStringLiteral("categories"), newCat)}}));
    });
    const auto fields = memoRecord(SyncStore(a.connection).collectPending(), id).fields;
    QCOMPARE(fields.value(QStringLiteral("category_id")).version.time, time + 500);
    QCOMPARE(fields.value(QStringLiteral("body")).version.time, time);
    syncAll(cloud, {a, b});
    for (const Device& d : {a, b}) {
        QCOMPARE(memoCategory(d, id), newCat);
        QCOMPARE(valueOf(d, QStringLiteral("memos"), id, QStringLiteral("updated_at")).toString(), memoStamp(time + 500));
        QVERIFY(valueOf(d, QStringLiteral("memos"), id, QStringLiteral("updated_at")) != before);
    }
}

void SyncTests::memoDeletionWinsAndPreservesLosingBody()
{
    // 产品保证：一台删除、一台写长正文，两种接收路径都删除优先，完整被覆盖内容留下来；
    // 空标题没有可找回的内容，哪台都不记。
    const Device a = openDevice(QStringLiteral("memo-a"));
    const Device b = openDevice(QStringLiteral("memo-b"));
    constexpr qint64 time = 1900000000728;
    QVERIFY(setClock(a, time));
    const QString id = addMemo(a, QString(), QStringLiteral("正文首行\n旧内容"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    syncAll(cloud, {a, b});
    QVERIFY(setClock(a, time + 100));
    QVERIFY(exec(a, QStringLiteral("DELETE FROM memos WHERE sync_id='%1'").arg(id)));
    QVERIFY(setClock(b, time + 200));
    const QString body = QStringLiteral("正文首行\n") + QString(3000, QChar(0x7532)) + QStringLiteral("完整结尾");
    QSqlQuery q(deviceDb(b));
    q.prepare(QStringLiteral("UPDATE memos SET body=? WHERE sync_id=?")); q.addBindValue(body); q.addBindValue(id);
    QVERIFY(q.exec());
    QCOMPARE(count(a, QStringLiteral("SELECT COUNT(*) FROM memos")), 0);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM memos")), 1);
    // 空标题那一项确实会随记录发出去：A 收到这条修改时要面对一个空的标题，测「空的不记」才有意义。
    const auto outgoing = memoRecord(SyncStore(b.connection).collectPending(), id).fields;
    QVERIFY(outgoing.contains(QStringLiteral("title")));
    QVERIFY(outgoing.value(QStringLiteral("title")).value.toString().isEmpty());
    // 删除到达还在编辑的一台，以及编辑到达已删的一台，分别经过不同的应用分支。
    // 编辑的一台先发出修改还是先收到删除取决于读写顺序，记成「删除优先」或「已删除」都对，关键是正文完整留下。
    syncAll(cloud, {a, b});
    for (const Device& d : {a, b}) {
        QCOMPARE(count(d, QStringLiteral("SELECT COUNT(*) FROM memos")), 0);
        bool found = false;
        for (const auto& log : SyncStore(d.connection).syncLog(10)) {
            if ((log.kind == QLatin1String("delete") || log.kind == QLatin1String("removed"))
                && log.field == QLatin1String("body")) {
                QCOMPARE(log.lostValue, body);
                QCOMPARE(log.recordLabel, QStringLiteral("正文首行"));
                found = true;
            }
        }
        QVERIFY(found);
        QCOMPARE(count(d, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log WHERE tbl = 'memos' AND field = 'title'")),
                 0);
    }
}

void SyncTests::memoDeletedElsewhereKeepsCopyWithoutCallingItConflict()
{
    // 产品保证：另一台正常删掉备忘录时，这台在日志里留一份删除前的内容，记成「已删除」而不是冲突，
    // 空标题、空正文不记；只有本机还没发出去的修改被删除盖掉，才记成「删除优先」的冲突。
    const Device a = openDevice(QStringLiteral("memo-copy-a"));
    const Device b = openDevice(QStringLiteral("memo-copy-b"));
    const QString titled = addMemo(a, QStringLiteral("张宇 36 讲"), QStringLiteral("第 8 讲做完"));
    const QString untitled = addMemo(a, QString(), QStringLiteral("只有正文"));
    const QString editing = addMemo(a, QStringLiteral("1000 题"), QStringLiteral("第 3 章"));
    QVERIFY(!titled.isEmpty() && !untitled.isEmpty() && !editing.isEmpty());
    FakeCloud cloud(m_data->filePath(QStringLiteral("memo-copy-cloud")));
    syncAll(cloud, {a, b});
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM memos")), 3);

    // A 又改了第三条的正文，还没发出去；其余内容都已经发出去了。
    QVERIFY(exec(a, QStringLiteral("UPDATE memos SET body = '第 4 章' WHERE sync_id = '%1'").arg(editing)));
    const QString pendingSql = QStringLiteral(
        "SELECT COUNT(*) FROM sync_field_versions WHERE tbl = 'memos' AND pending = 1 AND sync_id = '%1' AND field = '%2'");
    QCOMPARE(count(a, pendingSql.arg(titled, QStringLiteral("body"))), 0);
    QCOMPARE(count(a, pendingSql.arg(editing, QStringLiteral("title"))), 0);
    QCOMPARE(count(a, pendingSql.arg(editing, QStringLiteral("body"))), 1);

    // B 看过三条之后全删了。删除直接交给 A，不让 A 先把手上的修改发出去，两种情况才能都出现。
    QVERIFY(exec(b, QStringLiteral("DELETE FROM memos")));
    const SyncStore::ApplyResult result =
        SyncStore(a.connection).applyRemote(throughJson(SyncStore(b.connection).collectPending()));
    QVERIFY2(result.ok, qPrintable(result.error));
    QCOMPARE(count(a, QStringLiteral("SELECT COUNT(*) FROM memos")), 0);

    const QString entrySql = QStringLiteral(
        "SELECT COUNT(*) FROM sync_conflict_log WHERE kind = '%1' AND sync_id = '%2' AND field = '%3' AND lost_value = '%4'");
    // 已经发出去的内容：记成「已删除」，留着删除前的原文。
    QCOMPARE(count(a, entrySql.arg(QStringLiteral("removed"), titled, QStringLiteral("title"), QStringLiteral("张宇 36 讲"))), 1);
    QCOMPARE(count(a, entrySql.arg(QStringLiteral("removed"), titled, QStringLiteral("body"), QStringLiteral("第 8 讲做完"))), 1);
    QCOMPARE(count(a, entrySql.arg(QStringLiteral("removed"), untitled, QStringLiteral("body"), QStringLiteral("只有正文"))), 1);
    QCOMPARE(count(a, entrySql.arg(QStringLiteral("removed"), editing, QStringLiteral("title"), QStringLiteral("1000 题"))), 1);
    // 空标题不记。
    QCOMPARE(count(a, QStringLiteral("SELECT COUNT(*) FROM sync_conflict_log WHERE sync_id = '%1' AND field = 'title'")
                          .arg(untitled)), 0);
    // 本机还没发出去的修改被删除盖掉：这才是冲突。
    QCOMPARE(count(a, entrySql.arg(QStringLiteral("delete"), editing, QStringLiteral("body"), QStringLiteral("第 4 章"))), 1);
    QCOMPARE(logCount(a, QStringLiteral("removed")), 4);
    QCOMPARE(logCount(a, QStringLiteral("delete")), 1);
    // 删除的一台什么都没丢，不记。
    QCOMPARE(logCount(b), 0);
}

void SyncTests::memoOrderCollisionsConverge_data()
{
    QTest::addColumn<bool>("classified");
    QTest::newRow("category") << true;
    QTest::newRow("null-category") << false;
}

void SyncTests::memoOrderCollisionsConverge()
{
    // 产品保证：两台各自拖动造成真实撞号后，科目内按顺序、创建时间、同步身份归一，两台一致且不改内容时间。
    QFETCH(bool, classified);
    const Device a = openDevice(QStringLiteral("memo-a"));
    const Device b = openDevice(QStringLiteral("memo-b"));
    const QString cat = classified ? addCategory(a, QStringLiteral("归一科目")) : QString();
    constexpr qint64 time = 1900000000728;
    QVERIFY(setClock(a, time));
    const QString first = addMemo(a, QStringLiteral("第一条"), QStringLiteral("正文"), cat, QStringLiteral("memo-z"));
    const QString second = addMemo(a, QStringLiteral("第二条"), QStringLiteral("正文"), cat, QStringLiteral("memo-m"));
    const QString third = addMemo(a, QStringLiteral("第三条"), QStringLiteral("正文"), cat, QStringLiteral("memo-a"));
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    syncAll(cloud, {a, b});
    const QVariant firstTime = valueOf(a, QStringLiteral("memos"), first, QStringLiteral("updated_at"));
    QVERIFY(setClock(a, time + 100));
    QVERIFY(exec(a, QStringLiteral("UPDATE memos SET sort_order=CASE sync_id WHEN 'memo-z' THEN 2 ELSE 1 END "
                                  "WHERE sync_id IN ('memo-z','memo-m')")));
    QVERIFY(setClock(b, time + 200));
    QVERIFY(exec(b, QStringLiteral("UPDATE memos SET sort_order=CASE sync_id WHEN 'memo-m' THEN 3 ELSE 2 END "
                                  "WHERE sync_id IN ('memo-m','memo-a')")));
    SyncStore sa(a.connection), sb(b.connection);
    const SyncBatch ab = sa.collectPending(), bb = sb.collectPending();
    // 各台拖动前后都没有本地撞号；字段合并后的 first=2、third=2 才是真正的同步碰撞。
    QCOMPARE(count(a, QStringLiteral("SELECT COUNT(DISTINCT sort_order) FROM memos")), 3);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(DISTINCT sort_order) FROM memos")), 3);
    QCOMPARE(memoRecord(ab, first).fields.value(QStringLiteral("sort_order")).value.toInt(), 2);
    QCOMPARE(memoRecord(bb, third).fields.value(QStringLiteral("sort_order")).value.toInt(), 2);
    QCOMPARE(valueOf(a, QStringLiteral("memos"), first, QStringLiteral("created_at")),
             valueOf(a, QStringLiteral("memos"), third, QStringLiteral("created_at")));
    QVERIFY(localIdOf(a, QStringLiteral("memos"), first) < localIdOf(a, QStringLiteral("memos"), third));
    QVERIFY(sa.acknowledge(ab) && sb.acknowledge(bb));
    const auto applied = sa.applyRemote(throughJson(bb));
    QVERIFY2(applied.ok, qPrintable(applied.error));
    QVERIFY(sa.hasPending()); // 归一必须成为本机改动，再发给对方，不能静默改本地顺序。
    QCOMPARE(valueOf(a, QStringLiteral("memos"), third, QStringLiteral("sort_order")).toInt(), 1);
    QCOMPARE(valueOf(a, QStringLiteral("memos"), first, QStringLiteral("sort_order")).toInt(), 2);
    QCOMPARE(valueOf(a, QStringLiteral("memos"), second, QStringLiteral("sort_order")).toInt(), 3);
    QVERIFY(sb.applyRemote(throughJson(ab)).ok);
    syncAll(cloud, {a, b});
    for (const QString& id : {first, second, third}) {
        QCOMPARE(valueOf(a, QStringLiteral("memos"), id, QStringLiteral("sort_order")),
                 valueOf(b, QStringLiteral("memos"), id, QStringLiteral("sort_order")));
    }
    QCOMPARE(valueOf(a, QStringLiteral("memos"), first, QStringLiteral("updated_at")), firstTime);
    QCOMPARE(valueOf(b, QStringLiteral("memos"), first, QStringLiteral("updated_at")), firstTime);
    QCOMPARE(describe(sa.exportSnapshot()), describe(sb.exportSnapshot()));
}

void SyncTests::memoCategoryDeletionKeepsConcurrentContent()
{
    // 产品保证：一台删科目、一台改正文，最后都归到未分类，修改后的内容不能丢。
    const Device a = openDevice(QStringLiteral("memo-a"));
    const Device b = openDevice(QStringLiteral("memo-b"));
    const QString cat = addCategory(a, QStringLiteral("待删科目"));
    const QString id = addMemo(a, QStringLiteral("备忘"), QStringLiteral("旧文"), cat);
    QVERIFY(!addMemo(a, QStringLiteral("原未分类"), QStringLiteral("旧文")).isEmpty());
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    syncAll(cloud, {a, b});
    QVERIFY(!memoCategory(a, id).isEmpty() && !memoCategory(b, id).isEmpty());
    withServices(a, [&] { QVERIFY(CategoryManager::instance()->deleteCategory(int(localIdOf(a, QStringLiteral("categories"), cat)))); });
    QVERIFY(exec(b, QStringLiteral("UPDATE memos SET body='删除时仍在写的正文' WHERE sync_id='%1'").arg(id)));
    syncAll(cloud, {a, b});
    for (const Device& d : {a, b}) {
        QVERIFY(valueOf(d, QStringLiteral("memos"), id, QStringLiteral("category_id")).isNull());
        QCOMPARE(valueOf(d, QStringLiteral("memos"), id, QStringLiteral("body")).toString(), QStringLiteral("删除时仍在写的正文"));
        QCOMPARE(count(d, QStringLiteral("SELECT COUNT(DISTINCT sort_order) FROM memos")), 2);
    }
}

void SyncTests::memoCategoryMergeRepointsOnBothPaths()
{
    // 产品保证：本机撞名合并与远端 merge 删除，两条路径都把备忘跟到留下的科目。
    const Device a = openDevice(QStringLiteral("memo-a"));
    const Device b = openDevice(QStringLiteral("memo-b"));
    const QString winner = addCategory(a, QStringLiteral("同名科目"), QStringLiteral("cat-a"));
    const QString loser = addCategory(b, QStringLiteral("同名科目"), QStringLiteral("cat-z"));
    const QString id = addMemo(b, QStringLiteral("合并备忘"), QStringLiteral("不能掉进未分类"), loser);
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    QVERIFY(cloud.publish(b) > 0);
    // B 先改名，因而收到 A 时没有同名碰撞；B 必须只靠远端 merge 记录改指，不能误由本机合并兜底。
    QVERIFY(exec(b, QStringLiteral("UPDATE categories SET name='独立科目' WHERE sync_id='cat-z'")));
    QCOMPARE(customCategoryNames(b), QStringList{QStringLiteral("独立科目")});
    const auto pulled = cloud.pull(a);
    QVERIFY(!pulled.isEmpty());
    for (const auto& r : pulled) { QVERIFY2(r.ok, qPrintable(r.error)); QVERIFY(r.changedTables.contains(QStringLiteral("memos"))); }
    QCOMPARE(memoCategory(a, id), winner);
    QCOMPARE(scalar(a, QStringLiteral("SELECT kind FROM sync_tombstones WHERE tbl='categories' AND sync_id='cat-z'")).toString(), QStringLiteral("merge"));
    QVERIFY(cloud.publish(a) > 0);
    const auto merged = cloud.pull(b);
    QVERIFY(!merged.isEmpty());
    for (const auto& r : merged) { QVERIFY2(r.ok, qPrintable(r.error)); QVERIFY(r.changedTables.contains(QStringLiteral("memos"))); }
    QCOMPARE(memoCategory(b, id), winner);
    syncAll(cloud, {a, b});
    for (const Device& d : {a, b}) {
        QCOMPARE(memoCategory(d, id), winner);
        QCOMPARE(valueOf(d, QStringLiteral("memos"), id, QStringLiteral("body")).toString(), QStringLiteral("不能掉进未分类"));
        QCOMPARE(count(d, QStringLiteral("SELECT COUNT(*) FROM categories WHERE sync_id='cat-z'")), 0);
    }
}

void SyncTests::memoSnapshotsPreserveContentTimeDuringJoinAndRollback()
{
    // 产品保证：首次加入和恢复备份的全局回滚都带上备忘原文与内容时间，不能留下接收方的旧时间。
    const Device a = openDevice(QStringLiteral("memo-a"));
    const Device b = openDevice(QStringLiteral("memo-b"));
    constexpr qint64 time = 1900000000728;
    QVERIFY(setClock(a, time));
    const QString id = addMemo(a, QStringLiteral("快照"), QStringLiteral("备份正文"));
    const QString extra = addMemo(b, QStringLiteral("应被替换"), QStringLiteral("本机正文"));
    QVERIFY(!extra.isEmpty());
    SyncStore sa(a.connection), sb(b.connection);
    const SyncBatch original = throughJson(sa.exportSnapshot());
    const auto joined = sb.replaceWithSnapshot(original);
    QVERIFY2(joined.ok, qPrintable(joined.error));
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM memos")), 1);
    QCOMPARE(valueOf(b, QStringLiteral("memos"), id, QStringLiteral("updated_at")).toString(), memoStamp(time));
    const qint64 localId = localIdOf(b, QStringLiteral("memos"), id);
    QVERIFY(setClock(b, time + 800));
    QVERIFY(exec(b, QStringLiteral("UPDATE memos SET body='备份之后的正文' WHERE sync_id='%1'").arg(id)));
    QVERIFY(valueOf(b, QStringLiteral("memos"), id, QStringLiteral("updated_at")).toString() != memoStamp(time));
    QVERIFY(sa.beginEpochAfterRestore(0, a.id));
    const auto rolled = sb.replaceWithSnapshot(throughJson(sa.exportSnapshot()));
    QVERIFY2(rolled.ok, qPrintable(rolled.error));
    QVERIFY(rolled.changedTables.contains(QStringLiteral("memos")));
    QCOMPARE(sb.epoch(), qint64(1));
    QCOMPARE(localIdOf(b, QStringLiteral("memos"), id), localId);
    QCOMPARE(valueOf(b, QStringLiteral("memos"), id, QStringLiteral("body")).toString(), QStringLiteral("备份正文"));
    QCOMPARE(valueOf(b, QStringLiteral("memos"), id, QStringLiteral("updated_at")).toString(), memoStamp(time));
    QVERIFY(!sb.applyRemote(original).ok);
}

void SyncTests::memoPendingCategoryRelinksWithoutEcho()
{
    // 产品保证：备忘先到、科目后到时能接回引用；等待期间导出的快照也保留科目身份，不产生回声修改。
    const Device a = openDevice(QStringLiteral("memo-a"));
    const Device b = openDevice(QStringLiteral("memo-b"));
    const QString cat = addCategory(a, QStringLiteral("晚到科目"));
    const QString id = addMemo(a, QStringLiteral("引用"), QStringLiteral("原文"), cat);
    SyncStore sa(a.connection), sb(b.connection);
    SyncBatch memos = throughJson(sa.collectPending()), categories = memos;
    memos.records = {memoRecord(memos, id)};
    categories.records.removeIf([](const SyncRecord& r) { return r.table != QLatin1String("categories"); });
    QVERIFY(localIdOf(b, QStringLiteral("categories"), cat) == 0);
    const auto first = sb.applyRemote(memos);
    QVERIFY(first.ok && first.skippedRecords == 0);
    QVERIFY(valueOf(b, QStringLiteral("memos"), id, QStringLiteral("category_id")).isNull());
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM sync_pending_refs WHERE tbl='memos'")), 1);
    const SyncRecord waiting = memoRecord(throughJson(sb.exportSnapshot()), id);
    QCOMPARE(waiting.fields.value(QStringLiteral("category_id")).value.toString(), cat);
    const QVariant stamp = valueOf(b, QStringLiteral("memos"), id, QStringLiteral("updated_at"));
    const auto second = sb.applyRemote(categories);
    QVERIFY2(second.ok, qPrintable(second.error));
    QVERIFY(second.changedTables.contains(QStringLiteral("memos")));
    QCOMPARE(memoCategory(b, id), cat);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM sync_pending_refs WHERE tbl='memos'")), 0);
    QCOMPARE(memoRecord(sb.exportSnapshot(), id).fields.value(QStringLiteral("category_id")).version,
             waiting.fields.value(QStringLiteral("category_id")).version);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM sync_outbox WHERE tbl='memos'")), 0);
    QCOMPARE(valueOf(b, QStringLiteral("memos"), id, QStringLiteral("updated_at")), stamp);
}

void SyncTests::phaseOneV20MemosAcquireSyncWithoutVersionBump()
{
    // 产品保证：阶段 1 的 v20 库已有正文、还没有同步列时，重复迁移能补齐身份和队列，原内容时间不变。
    const int id = MemoService::instance()->createMemo(QStringLiteral("阶段一"), QStringLiteral("既有正文"));
    QVERIFY(id > 0);
    for (const auto& spec : SyncSchema::triggers()) {
        if (spec.first.startsWith(QStringLiteral("memos_sync_"))) { QVERIFY(exec(QStringLiteral("DROP TRIGGER %1").arg(spec.first))); }
    }
    QVERIFY(exec(QStringLiteral("DROP INDEX idx_memos_sync_id")));
    QVERIFY(exec(QStringLiteral("ALTER TABLE memos DROP COLUMN sync_id")));
    QVERIFY(exec(QStringLiteral("DELETE FROM sync_field_versions WHERE tbl='memos'")));
    QVERIFY(exec(QStringLiteral("DELETE FROM sync_outbox WHERE tbl='memos'")));
    const QString original = QStringLiteral("2026-10-02T12:51:46.728Z");
    QVERIFY(exec(QStringLiteral("UPDATE memos SET updated_at='%1'").arg(original)));
    QCOMPARE(count(QStringLiteral("PRAGMA user_version")), DatabaseManager::kCurrentSchemaVersion);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM pragma_table_info('memos') WHERE name='sync_id'")), 0);
    QVERIFY(DatabaseManager::instance()->createTables());
    QCOMPARE(count(QStringLiteral("PRAGMA user_version")), DatabaseManager::kCurrentSchemaVersion);
    const QString identity = syncIdOf(QStringLiteral("memos"), id);
    QVERIFY(!identity.isEmpty());
    QCOMPARE(versionCount(QStringLiteral("memos"), identity), 5);
    QVERIFY(queued(QStringLiteral("memos"), identity));
    const qint64 time = QDateTime::fromString(original, Qt::ISODateWithMs).toMSecsSinceEpoch();
    QCOMPARE(versionOf(QStringLiteral("memos"), identity, QStringLiteral("body")).time, time);
    QCOMPARE(scalar(QStringLiteral("SELECT updated_at FROM memos WHERE id=%1").arg(id)).toString(), original);
    QCOMPARE(scalar(QStringLiteral("SELECT body FROM memos WHERE id=%1").arg(id)).toString(), QStringLiteral("既有正文"));
    QCOMPARE(triggerSql(), SyncSchema::canonicalTriggerSql());
    QVERIFY(markEverythingSent());
    QVERIFY(DatabaseManager::instance()->createTables());
    QCOMPARE(syncIdOf(QStringLiteral("memos"), id), identity);
    QVERIFY(!queued(QStringLiteral("memos"), identity));
    QCOMPARE(versionOf(QStringLiteral("memos"), identity, QStringLiteral("body")).time, time);
}

void SyncTests::memoNotificationsCoverContentAndCategoryDeletion()
{
    // 产品保证：远端内容生效或科目被删，提交后都会刷新备忘；重复应用和失败不会多发信号。
    const int cat = CategoryManager::instance()->addCategory(QStringLiteral("通知科目"), QStringLiteral("#123456"));
    const int id = MemoService::instance()->createMemo(QStringLiteral("通知"), QStringLiteral("正文"), cat);
    QVERIFY(cat > 0 && id > 0);
    QSignalSpy spy(MemoService::instance(), &MemoService::memosChanged);
    const QString identity = syncIdOf(QStringLiteral("memos"), id);
    const QString remote = QStringLiteral("0123456789abcdef0123456789abcdef");
    SyncBatch batch; batch.device = remote;
    SyncRecord record; record.table = QStringLiteral("memos"); record.syncId = identity;
    record.fields.insert(QStringLiteral("body"), {QStringLiteral("远端正文"), {1900000000728, remote}, {}});
    batch.records = {record};
    const auto changed = SyncStore().applyRemote(batch);
    QVERIFY(changed.ok && changed.changedTables.contains(QStringLiteral("memos")));
    QCOMPARE(spy.count(), 0);
    SyncNotifier::publish(changed);
    QCOMPARE(spy.count(), 1);
    SyncNotifier::publish(SyncStore().applyRemote(batch));
    QCOMPARE(spy.count(), 1);
    SyncStore::ApplyResult failed;
    failed.changedTables.insert(QStringLiteral("memos"));
    SyncNotifier::publish(failed);
    QCOMPARE(spy.count(), 1);
    batch.records = {remoteDeletion(QStringLiteral("categories"), syncIdOf(QStringLiteral("categories"), cat),
                                    {1900000000828, remote})};
    QCOMPARE(MemoService::instance()->getMemo(id).value(QStringLiteral("categoryId")).toInt(), cat);
    const auto deleted = SyncStore().applyRemote(batch);
    QVERIFY(deleted.ok && deleted.changedTables.contains(QStringLiteral("memos")));
    QCOMPARE(MemoService::instance()->getMemo(id).value(QStringLiteral("categoryId")).toInt(), 0);
    SyncNotifier::publish(deleted);
    QCOMPARE(spy.count(), 2);
}

// ── 054 阶段 2：废纸篓两台共用 ──

void SyncTests::trashDeletedOnOneDeviceAppearsOnTheOtherWithoutBeingWrittenTwice()
{
    // 产品保证：在一台设备上删除的内容，另一台的废纸篓里也有同样的一份（逐字相同），原记录在两台都没了；
    // 只有执行删除的那台写废纸篓，另一台应用远端删除时不会自己再写一份。
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    TrashScenario s;
    setUpTrashScenario(cloud, QStringLiteral("线性代数 第 4 讲"), &s);
    QVERIFY(!QTest::currentTestFailed());
    // B 把科目改了名：A 删除时写进内容里的是旧名字，列表上的科目名要读 B 本机现在的科目。
    const QString renamed = QStringLiteral("线代（B 改名）");
    QVERIFY(exec(s.b, QStringLiteral("UPDATE categories SET name = '%1' WHERE sync_id = '%2'")
                          .arg(renamed, s.category)));

    deleteTaskOn(s.a, s.task);
    QCOMPARE(trashRows(s.a), 1);
    QCOMPARE(trashRows(s.b), 0);
    const QString trashId = scalar(s.a, QStringLiteral("SELECT sync_id FROM trash_items")).toString();
    QVERIFY(!trashId.isEmpty());
    syncAll(cloud, {s.a, s.b});

    // 原记录两台都没了。
    for (const Device& d : {s.a, s.b}) {
        QCOMPARE(count(d, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(s.task)), 0);
    }
    // B 的废纸篓恰好是 A 写的那一行：身份和五个同步字段逐字相同。
    // 如果 B 应用远端删除时自己也写了一份，这里会是两行；只有它自己写、没收到 A 的，按 A 的身份就查不到。
    QCOMPARE(trashRows(s.b), 1);
    QCOMPARE(trashRows(s.a), 1);
    for (const QString& column : kTrashColumns) {
        QCOMPARE(trashValue(s.b, trashId, column), trashValue(s.a, trashId, column));
    }
    QCOMPARE(trashValue(s.b, trashId, QStringLiteral("kind")), QStringLiteral("task"));
    QCOMPARE(trashValue(s.b, trashId, QStringLiteral("origin_sync_id")), s.task);
    QCOMPARE(trashValue(s.b, trashId, QStringLiteral("title")), QStringLiteral("线性代数 第 4 讲"));
    // 收到的废纸篓记录不是 B 的本机改动，不会再发回去。
    QCOMPARE(count(s.b, QStringLiteral("SELECT COUNT(*) FROM sync_outbox WHERE tbl = 'trash_items'")), 0);

    // B 上能把它列出来：科目是 B 本机的科目（改名后的名字、颜色），不是内容里记的旧名字。
    QVariantMap listed;
    withServices(s.b, [&] { listed = TrashService::instance()->readItems(); });
    QVERIFY2(listed.value(QStringLiteral("ok")).toBool(), qPrintable(listed.value(QStringLiteral("error")).toString()));
    const QVariantList items = listed.value(QStringLiteral("items")).toList();
    QCOMPARE(items.size(), 1);
    const QVariantMap item = items.first().toMap();
    QCOMPARE(item.value(QStringLiteral("kind")).toString(), QStringLiteral("task"));
    QCOMPARE(item.value(QStringLiteral("title")).toString(), QStringLiteral("线性代数 第 4 讲"));
    QCOMPARE(item.value(QStringLiteral("originSyncId")).toString(), s.task);
    QCOMPARE(item.value(QStringLiteral("categoryName")).toString(), renamed);
    QCOMPARE(item.value(QStringLiteral("categoryColor")).toString(), QStringLiteral("#123456"));
    QVERIFY(item.value(QStringLiteral("restorable")).toBool());
}

void SyncTests::trashRestoredOnOneDeviceCreatesTheRecordOnTheOtherAndClearsBothTrashes()
{
    // 产品保证：一台设备恢复之后，另一台出现同一条新记录（同一个新身份、同一个科目、同样的内容），
    // 两台的废纸篓里那一项都没了；恢复出来的是新记录，原来的身份不会被写回去，也不会出现第二份。
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    TrashScenario s;
    setUpTrashScenario(cloud, QStringLiteral("线性代数 第 4 讲"), &s);
    QVERIFY(!QTest::currentTestFailed());
    deleteTaskOn(s.a, s.task);
    syncAll(cloud, {s.a, s.b});
    QCOMPARE(trashRows(s.a), 1);
    QCOMPARE(trashRows(s.b), 1);
    QCOMPARE(count(s.a, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '线性代数 第 4 讲'")), 0);
    QCOMPARE(count(s.b, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '线性代数 第 4 讲'")), 0);

    // 在收到废纸篓记录的 B 上恢复。
    QVariantMap restored;
    withServices(s.b, [&] {
        const QVariantList items = TrashService::instance()->readItems().value(QStringLiteral("items")).toList();
        QVERIFY(items.size() == 1);
        restored = TrashService::instance()->restoreItem(items.first().toMap().value(QStringLiteral("id")).toInt());
    });
    QVERIFY2(restored.value(QStringLiteral("ok")).toBool(), qPrintable(restored.value(QStringLiteral("error")).toString()));
    QCOMPARE(count(s.b, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '线性代数 第 4 讲'")), 1);
    QCOMPARE(trashRows(s.b), 0);
    QCOMPARE(trashRows(s.a), 1); // A 还没收到，前提成立后再同步
    syncAll(cloud, {s.a, s.b});

    for (const Device& d : {s.a, s.b}) {
        QCOMPARE(count(d, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '线性代数 第 4 讲'")), 1);
        QCOMPARE(trashRows(d), 0);
        // 原来的身份是删除记录占着的，写回去另一台会忽略：恢复出来的必须是新身份。
        QCOMPARE(count(d, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE sync_id = '%1'").arg(s.task)), 0);
    }
    const QString restoredId =
        scalar(s.b, QStringLiteral("SELECT sync_id FROM tasks WHERE title = '线性代数 第 4 讲'")).toString();
    QVERIFY(!restoredId.isEmpty());
    QVERIFY(restoredId != s.task);
    QCOMPARE(scalar(s.a, QStringLiteral("SELECT sync_id FROM tasks WHERE title = '线性代数 第 4 讲'")).toString(),
             restoredId);
    // 科目按身份接回，两台一致（本机编号不同，但指向同一个科目）；其余内容是删除前的样子。
    QCOMPARE(taskCategory(s.a, restoredId), s.category);
    QCOMPARE(taskCategory(s.b, restoredId), s.category);
    for (const QString& column : {QStringLiteral("date"), QStringLiteral("estimated_minutes"),
                                  QStringLiteral("notes"), QStringLiteral("completed")}) {
        QCOMPARE(taskValue(s.a, restoredId, column), taskValue(s.b, restoredId, column));
    }
    QCOMPARE(taskValue(s.a, restoredId, QStringLiteral("estimated_minutes")).toInt(), 45);
    QCOMPARE(taskValue(s.a, restoredId, QStringLiteral("notes")).toString(), QStringLiteral("第二遍"));
}

void SyncTests::trashDeleteItemAndEmptyTrashFollowToTheOtherDevice()
{
    // 产品保证：一台设备彻底删除废纸篓里的一项，另一台只少这一项；一台设备清空，另一台也跟着清空，
    // 之后再同步也不会有哪一项复活。
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    TrashScenario s;
    setUpTrashScenario(cloud, QStringLiteral("第一项"), &s);
    QVERIFY(!QTest::currentTestFailed());
    const QString second = createTaskOn(s.a, QStringLiteral("第二项"), s.category, 0, QString());
    const QString third = createTaskOn(s.a, QStringLiteral("第三项"), s.category, 0, QString());
    syncAll(cloud, {s.a, s.b});
    deleteTaskOn(s.a, s.task);
    deleteTaskOn(s.a, second);
    deleteTaskOn(s.a, third);
    syncAll(cloud, {s.a, s.b});
    QCOMPARE(trashRows(s.a), 3);
    QCOMPARE(trashRows(s.b), 3);

    // A 彻底删除中间那一项：B 只少这一项，排在它前后的两项还在（删错了别的项、或清空了，这里都会不同）。
    QVariantMap removed;
    withServices(s.a, [&] {
        removed = TrashService::instance()->deleteItem(trashIdOf(s.a, QStringLiteral("第二项")));
    });
    QVERIFY2(removed.value(QStringLiteral("ok")).toBool(), qPrintable(removed.value(QStringLiteral("error")).toString()));
    QCOMPARE(trashRows(s.b), 3); // 同步之前 B 还有
    syncAll(cloud, {s.a, s.b});
    QStringList expected{QStringLiteral("第一项"), QStringLiteral("第三项")};
    expected.sort();
    QCOMPARE(trashTitles(s.a), expected);
    QCOMPARE(trashTitles(s.b), expected);

    // 再放两项，由 B（不是写入这些项的那一台）清空：A 也清空。
    const QString fourth = createTaskOn(s.a, QStringLiteral("第四项"), s.category, 0, QString());
    const QString fifth = createTaskOn(s.a, QStringLiteral("第五项"), s.category, 0, QString());
    syncAll(cloud, {s.a, s.b});
    deleteTaskOn(s.a, fourth);
    deleteTaskOn(s.a, fifth);
    syncAll(cloud, {s.a, s.b});
    QCOMPARE(trashRows(s.a), 4);
    QCOMPARE(trashRows(s.b), 4);
    QVariantMap emptied;
    withServices(s.b, [&] { emptied = TrashService::instance()->emptyTrash(); });
    QVERIFY2(emptied.value(QStringLiteral("ok")).toBool(), qPrintable(emptied.value(QStringLiteral("error")).toString()));
    QCOMPARE(emptied.value(QStringLiteral("count")).toInt(), 4);
    QCOMPARE(trashRows(s.a), 4); // 同步之前 A 还有
    syncAll(cloud, {s.a, s.b});
    QCOMPARE(trashRows(s.a), 0);
    QCOMPARE(trashRows(s.b), 0);
    // 再同步一轮也没有复活：删除记录压过任何还在路上的旧记录。
    syncAll(cloud, {s.a, s.b});
    QCOMPARE(trashRows(s.a), 0);
    QCOMPARE(trashRows(s.b), 0);
}

void SyncTests::trashBothDevicesDeletingTheSameRecordListsOneAndRestoresOnce()
{
    // 产品保证：两台设备（没有同步时）各自删了同一条记录，同步之后废纸篓列表里这一条只出现一次；
    // 恢复它时两份一起收掉，只恢复出一条记录，不会留下分身、也不会恢复出第二份。
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    TrashScenario s;
    setUpTrashScenario(cloud, QStringLiteral("同时删除"), &s);
    QVERIFY(!QTest::currentTestFailed());
    deleteTaskOn(s.a, s.task);
    deleteTaskOn(s.b, s.task);
    QCOMPARE(trashRows(s.a), 1);
    QCOMPARE(trashRows(s.b), 1);
    // 两台各写了自己的一份，身份不同：这才是「两份」。
    QVERIFY(scalar(s.a, QStringLiteral("SELECT sync_id FROM trash_items")).toString()
            != scalar(s.b, QStringLiteral("SELECT sync_id FROM trash_items")).toString());
    syncAll(cloud, {s.a, s.b});

    for (const Device& d : {s.a, s.b}) {
        QCOMPARE(trashRows(d), 2);
        QCOMPARE(count(d, QStringLiteral("SELECT COUNT(DISTINCT sync_id) FROM trash_items")), 2);
        QCOMPARE(count(d, QStringLiteral("SELECT COUNT(DISTINCT origin_sync_id) FROM trash_items")), 1);
        QCOMPARE(scalar(d, QStringLiteral("SELECT origin_sync_id FROM trash_items LIMIT 1")).toString(), s.task);
        QVariantList items;
        withServices(d, [&] { items = TrashService::instance()->readItems().value(QStringLiteral("items")).toList(); });
        QCOMPARE(items.size(), 1);
    }

    // A 恢复：两份废纸篓记录一起删掉，任务恰好一条，同步之后两台一致。
    QVariantMap restored;
    withServices(s.a, [&] {
        const QVariantList items = TrashService::instance()->readItems().value(QStringLiteral("items")).toList();
        QVERIFY(items.size() == 1);
        restored = TrashService::instance()->restoreItem(items.first().toMap().value(QStringLiteral("id")).toInt());
    });
    QVERIFY2(restored.value(QStringLiteral("ok")).toBool(), qPrintable(restored.value(QStringLiteral("error")).toString()));
    QCOMPARE(trashRows(s.a), 0);
    syncAll(cloud, {s.a, s.b});
    for (const Device& d : {s.a, s.b}) {
        QCOMPARE(trashRows(d), 0);
        QCOMPARE(count(d, QStringLiteral("SELECT COUNT(*) FROM tasks WHERE title = '同时删除'")), 1);
    }
    QCOMPARE(scalar(s.b, QStringLiteral("SELECT sync_id FROM tasks WHERE title = '同时删除'")).toString(),
             scalar(s.a, QStringLiteral("SELECT sync_id FROM tasks WHERE title = '同时删除'")).toString());
}

void SyncTests::trashExpiryPurgeConvergesWhetherBothDevicesOrOnlyOneExpireIt()
{
    // 产品保证：过期清理在两台设备上结果一致——同一项在两台都到期、各自清掉时，同步照常完成、两边都空；
    // 只有一台到期（另一台的日期还早一天）时，那台清掉之后另一台也跟着没有，不必等自己到期。
    FakeCloud cloud(m_data->filePath(QStringLiteral("cloud")));
    TrashScenario s;
    setUpTrashScenario(cloud, QStringLiteral("两台同时到期"), &s);
    QVERIFY(!QTest::currentTestFailed());
    deleteTaskOn(s.a, s.task);
    syncAll(cloud, {s.a, s.b});
    QCOMPARE(trashRows(s.a), 1);
    QCOMPARE(trashRows(s.b), 1);
    const QString both = scalar(s.a, QStringLiteral("SELECT sync_id FROM trash_items")).toString();
    QCOMPARE(trashValue(s.b, both, QStringLiteral("deleted_at")), trashValue(s.a, both, QStringLiteral("deleted_at")));

    // 前提：到期前一天（D+29）两台都不会清掉它。
    QCOMPARE(purgeExpiredOn(s.a, trashNowAfter(s.a, both, 29)), 0);
    QCOMPARE(purgeExpiredOn(s.b, trashNowAfter(s.b, both, 29)), 0);
    QCOMPARE(trashRows(s.a), 1);
    QCOMPARE(trashRows(s.b), 1);
    // 到期当天（D+30）两台各自清掉同一项：各清一条，都是自己写的删除记录。
    QCOMPARE(purgeExpiredOn(s.a, trashNowAfter(s.a, both, 30)), 1);
    QCOMPARE(purgeExpiredOn(s.b, trashNowAfter(s.b, both, 30)), 1);
    QCOMPARE(trashRows(s.a), 0);
    QCOMPARE(trashRows(s.b), 0);
    syncAll(cloud, {s.a, s.b}); // 两边互相收到对方对同一项的删除记录，不能出错，也不能把它救回来
    QCOMPARE(trashRows(s.a), 0);
    QCOMPARE(trashRows(s.b), 0);

    // 另造一行，只有 A 到期：B 的「现在」早一天，它自己清不掉，要靠同步收到 A 的删除。
    const QString second = createTaskOn(s.a, QStringLiteral("只有一台到期"), s.category, 0, QString());
    syncAll(cloud, {s.a, s.b});
    deleteTaskOn(s.a, second);
    syncAll(cloud, {s.a, s.b});
    QCOMPARE(trashRows(s.a), 1);
    QCOMPARE(trashRows(s.b), 1);
    const QString onlyA = scalar(s.a, QStringLiteral("SELECT sync_id FROM trash_items")).toString();
    QVERIFY(onlyA != both);
    QCOMPARE(purgeExpiredOn(s.b, trashNowAfter(s.b, onlyA, 29)), 0);
    QCOMPARE(trashRows(s.b), 1);
    QCOMPARE(purgeExpiredOn(s.a, trashNowAfter(s.a, onlyA, 30)), 1);
    QCOMPARE(trashRows(s.a), 0);
    QCOMPARE(trashRows(s.b), 1); // 同步之前 B 还有
    syncAll(cloud, {s.a, s.b});
    QCOMPARE(trashRows(s.a), 0);
    QCOMPARE(trashRows(s.b), 0);
}

void SyncTests::trashChangesFromSyncNotifyTheTrashPage()
{
    // 产品保证：同步带来废纸篓的变化（对方放进、彻底删除、清空、恢复……）并提交之后，废纸篓页收到 trashChanged
    // 重读；应用失败的结果、与废纸篓无关的改动都不会误报。
    // 先取单例：TrashNotifier 到 trashChanged 的转发在 TrashService 构造时才接上。
    QSignalSpy spy(TrashService::instance(), &TrashService::trashChanged);
    const Device a = openDevice(QStringLiteral("trash-a"));
    const Device b = openDevice(QStringLiteral("trash-b"));
    SyncStore sa(a.connection), sb(b.connection);

    // 真实路径一：A 写了一行废纸篓记录，B 应用之后提交。
    QVERIFY(!addTrashRow(a, QStringLiteral("memo"), QStringLiteral("origin-1"), QStringLiteral("远端放进的"),
                         QStringLiteral("{\"v\":1}"), QStringLiteral("2026-10-06T01:00:00.000Z")).isEmpty());
    // 确认发送用本机读出的那一批：出队要核对记录带着的 changeTime，它不写进文件，
    // 经 JSON 解析出来的批次没有这个值（见 SyncRecord::changeTime）。
    const SyncBatch inserted = sa.collectPending();
    QVERIFY(!inserted.isEmpty());
    QVERIFY(sa.acknowledge(inserted));
    const SyncStore::ApplyResult arrived = sb.applyRemote(throughJson(inserted));
    QVERIFY2(arrived.ok, qPrintable(arrived.error));
    QVERIFY(arrived.changedTables.contains(QStringLiteral("trash_items")));
    QCOMPARE(trashRows(b), 1);
    QCOMPARE(spy.count(), 0); // 应用本身不发信号，提交之后由 SyncNotifier 统一发
    SyncNotifier::publish(arrived);
    QCOMPARE(spy.count(), 1);

    // 真实路径二：A 又把它彻底删除，B 应用对方的删除记录。
    QVERIFY(exec(a, QStringLiteral("DELETE FROM trash_items WHERE origin_sync_id = 'origin-1'")));
    const SyncBatch deletion = sa.collectPending();
    QVERIFY(!deletion.isEmpty());
    QVERIFY(sa.acknowledge(deletion));
    const SyncStore::ApplyResult removed = sb.applyRemote(throughJson(deletion));
    QVERIFY2(removed.ok, qPrintable(removed.error));
    QVERIFY(removed.changedTables.contains(QStringLiteral("trash_items")));
    QCOMPARE(trashRows(b), 0);
    SyncNotifier::publish(removed);
    QCOMPARE(spy.count(), 2);

    // 应用失败（ok = false）：即使带着 trash_items 也一个信号都不发。
    SyncStore::ApplyResult failed;
    failed.changedTables.insert(QStringLiteral("trash_items"));
    SyncNotifier::publish(failed);
    QCOMPARE(spy.count(), 2);

    // 成功但没有碰废纸篓：不发。
    SyncStore::ApplyResult unrelated;
    unrelated.ok = true;
    unrelated.changedTables.insert(QStringLiteral("tasks"));
    unrelated.changedTables.insert(QStringLiteral("memos"));
    SyncNotifier::publish(unrelated);
    QCOMPARE(spy.count(), 2);

    // 成功且含废纸篓：照发，且同一次提交只发一次。
    SyncStore::ApplyResult mixed;
    mixed.ok = true;
    mixed.changedTables.insert(QStringLiteral("tasks"));
    mixed.changedTables.insert(QStringLiteral("trash_items"));
    SyncNotifier::publish(mixed);
    QCOMPARE(spy.count(), 3);
}

void SyncTests::phaseOneV21TrashAcquiresSyncWithoutVersionBump()
{
    // 产品保证：阶段 1 留下的 v21 库（废纸篓里已有内容、还没有同步列）打开之后补齐身份、进待发送队列、
    // 装上触发器，原有内容一字不动，版本号不变——已经装过阶段 1 的设备升级之后，废纸篓里现有的内容也会同步出去。
    for (const auto& spec : SyncSchema::triggers()) {
        if (spec.first.startsWith(QStringLiteral("trash_items_sync_"))) {
            QVERIFY(exec(QStringLiteral("DROP TRIGGER %1").arg(spec.first)));
        }
    }
    QVERIFY(exec(QStringLiteral("DROP INDEX idx_trash_items_sync_id")));
    QVERIFY(exec(QStringLiteral("ALTER TABLE trash_items DROP COLUMN sync_id")));
    // 阶段 1 的库没有同步列，行是在没有触发器的情况下写的，附属表里不会有它们的踪迹。
    const QString specialPayload = QStringLiteral("{\"v\":1,\"title\":\"含 '单引号' 和 emoji 😀\"}");
    QVERIFY(exec(QStringLiteral("INSERT INTO trash_items (kind, origin_sync_id, title, payload, deleted_at) "
                                "VALUES ('task', 'origin-one', '阶段一的任务', '{\"v\":1,\"title\":\"阶段一的任务\"}', "
                                "'2026-10-05T01:00:00.000Z')")));
    QVERIFY(exec(QStringLiteral("INSERT INTO trash_items (kind, origin_sync_id, title, payload, deleted_at) "
                                "VALUES ('memo', 'origin-two', '阶段一的备忘', '%1', '2026-10-06T01:00:00.000Z')")
                     .arg(QString(specialPayload).replace(QLatin1Char('\''), QStringLiteral("''")))));
    QVERIFY(exec(QStringLiteral("PRAGMA user_version = 21")));
    // 前提：没有同步列、索引、触发器，也没有版本和队列；数据在；版本是 21。
    QCOMPARE(count(QStringLiteral("PRAGMA user_version")), 21);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM pragma_table_info('trash_items') WHERE name = 'sync_id'")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_trash_items_sync_id'")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' "
                                  "AND instr(name, 'trash_items_sync_') = 1")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_field_versions WHERE tbl = 'trash_items'")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sync_outbox WHERE tbl = 'trash_items'")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items")), 2);
    const auto snapshotOf = [] {
        QStringList rows;
        QSqlQuery query(db());
        query.exec(QStringLiteral("SELECT id, kind, origin_sync_id, title, payload, deleted_at FROM trash_items ORDER BY id"));
        while (query.next()) {
            QStringList parts;
            for (int column = 0; column < 6; ++column) {
                parts.append(query.value(column).toString());
            }
            rows.append(parts.join(QLatin1Char('|')));
        }
        return rows;
    };
    const QStringList before = snapshotOf();
    QCOMPARE(before.size(), 2);

    QVERIFY(DatabaseManager::instance()->createTables());

    QCOMPARE(count(QStringLiteral("PRAGMA user_version")), 21);
    QVERIFY(DatabaseManager::trashSchemaIsValid(db()));
    QCOMPARE(snapshotOf(), before); // 原数据一字不动（含编号）
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE sync_id IS NULL OR sync_id = ''")), 0);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(DISTINCT sync_id) FROM trash_items")), 2);
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_trash_items_sync_id'")), 1);
    QStringList expectedTriggers;
    for (const auto& spec : SyncSchema::triggers()) {
        if (spec.first.startsWith(QStringLiteral("trash_items_sync_"))) {
            expectedTriggers.append(spec.first);
        }
    }
    QVERIFY(!expectedTriggers.isEmpty());
    QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' "
                                  "AND instr(name, 'trash_items_sync_') = 1")), int(expectedTriggers.size()));
    QCOMPARE(triggerSql(), SyncSchema::canonicalTriggerSql());
    const SyncSchema::Table* trash = SyncSchema::table(QStringLiteral("trash_items"));
    QVERIFY(trash);
    QSqlQuery rows(db());
    QVERIFY(rows.exec(QStringLiteral("SELECT sync_id FROM trash_items")));
    QStringList identities;
    while (rows.next()) {
        identities.append(rows.value(0).toString());
    }
    rows.finish();
    QCOMPARE(identities.size(), 2);
    for (const QString& identity : identities) {
        QVERIFY(queued(QStringLiteral("trash_items"), identity));
        QCOMPARE(versionCount(QStringLiteral("trash_items"), identity), int(trash->fields.size()));
    }

    // 再打开一次：身份不变，已经发出去的不会重新排队。
    QVERIFY(markEverythingSent());
    QVERIFY(DatabaseManager::instance()->createTables());
    QCOMPARE(count(QStringLiteral("PRAGMA user_version")), 21);
    for (const QString& identity : identities) {
        QCOMPARE(count(QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE sync_id = '%1'").arg(identity)), 1);
        QVERIFY(!queued(QStringLiteral("trash_items"), identity));
    }
    QCOMPARE(snapshotOf(), before);
}

void SyncTests::trashSnapshotsReplaceTheTrashOnJoinAndRollback()
{
    // 产品保证：首次加入和恢复备份的全局回滚都带上废纸篓——整体替换之后，本机的废纸篓与发出快照的那台
    // 一模一样（身份和内容逐字相同），本机原来多出来的项消失，快照里没有的项不会残留。
    const Device a = openDevice(QStringLiteral("trash-a"));
    const Device b = openDevice(QStringLiteral("trash-b"));
    // 内容里带引号、反斜杠、换行转义和 emoji：快照走一遍 JSON，文本必须原样回来。
    const QString tricky = QStringLiteral("{\"v\":1,\"title\":\"带\\\"引号\\\"、\\\\ 和\\n换行 😀\"}");
    QVERIFY(!addTrashRow(a, QStringLiteral("task"), QStringLiteral("origin-a1"), QStringLiteral("A 的第一项"), tricky,
                         QStringLiteral("2026-10-05T01:00:00.123Z")).isEmpty());
    QVERIFY(!addTrashRow(a, QStringLiteral("memo"), QStringLiteral("origin-a2"), QStringLiteral("A 的第二项"),
                         QStringLiteral("{\"v\":1}"), QStringLiteral("2026-10-06T01:00:00.456Z")).isEmpty());
    QVERIFY(!addTrashRow(b, QStringLiteral("task"), QStringLiteral("origin-b1"), QStringLiteral("B 本机的，应被替换"),
                         QStringLiteral("{\"v\":1}"), QStringLiteral("2026-10-04T01:00:00.000Z")).isEmpty());
    SyncStore sa(a.connection), sb(b.connection);

    // 首次加入：B 以 A 的快照为准。
    QVERIFY(trashDump(a) != trashDump(b));
    const SyncBatch original = throughJson(sa.exportSnapshot());
    const SyncStore::ApplyResult joined = sb.replaceWithSnapshot(original);
    QVERIFY2(joined.ok, qPrintable(joined.error));
    QVERIFY(joined.changedTables.contains(QStringLiteral("trash_items")));
    QCOMPARE(trashRows(b), 2);
    QCOMPARE(trashDump(b), trashDump(a));
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE title = 'B 本机的，应被替换'")), 0);

    // 全局回滚：B 加入之后自己动了废纸篓；A 恢复了备份，废纸篓变成另一个样子（少了第一项，多了一项）。
    QVERIFY(exec(b, QStringLiteral("DELETE FROM trash_items WHERE origin_sync_id = 'origin-a2'")));
    QVERIFY(!addTrashRow(b, QStringLiteral("task"), QStringLiteral("origin-b2"), QStringLiteral("加入之后 B 放的"),
                         QStringLiteral("{\"v\":1}"), QStringLiteral("2026-10-06T02:00:00.000Z")).isEmpty());
    QVERIFY(exec(a, QStringLiteral("DELETE FROM trash_items WHERE origin_sync_id = 'origin-a1'")));
    QVERIFY(!addTrashRow(a, QStringLiteral("countdown_goal"), QStringLiteral("origin-a3"),
                         QStringLiteral("A 恢复后多出的一项"), QStringLiteral("{\"v\":1}"),
                         QStringLiteral("2026-10-06T03:00:00.000Z")).isEmpty());
    QVERIFY(trashDump(a) != trashDump(b));
    QVERIFY(sa.beginEpochAfterRestore(0, a.id));
    const SyncStore::ApplyResult rolled = sb.replaceWithSnapshot(throughJson(sa.exportSnapshot()));
    QVERIFY2(rolled.ok, qPrintable(rolled.error));
    QVERIFY(rolled.changedTables.contains(QStringLiteral("trash_items")));
    QCOMPARE(sb.epoch(), qint64(1));
    QCOMPARE(trashRows(b), 2);
    QCOMPARE(trashDump(b), trashDump(a));
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE title = '加入之后 B 放的'")), 0);
    QCOMPARE(count(b, QStringLiteral("SELECT COUNT(*) FROM trash_items WHERE origin_sync_id = 'origin-a1'")), 0);
}

QTEST_MAIN(SyncTests)
#include "SyncTests.moc"
