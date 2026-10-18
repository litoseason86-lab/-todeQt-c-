#include "BackupOperations.h"
#include "BackupSqliteDriver.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "SyncSchema.h"

#include <QCoreApplication>
#include <QDataStream>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QSaveFile>
#include <QScopeGuard>
#include <QSettings>
#include <QSet>
#include <QRegularExpression>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QStringList>
#include <QSysInfo>
#include <QUuid>

#include <memory>

namespace BackupOperations {

// 未受信文件的解析上限。设置项都是标量或短字符串，这两个数留了几个数量级余量。
constexpr int kMaxSettingValueBytes = 64 * 1024;
constexpr int kMaxSettingEntries = 500;
// 格式1只允许标量，固定到最低支持SDK的流格式，避免升级Qt后默认版本改变备份编码。
// 当前允许类型在Qt6.7与Qt6.10编码相同；新增类型时必须同时核对固定夹具和旧备份兼容。
constexpr auto kSettingsStreamVersion = QDataStream::Qt_6_7;

QString platformDisplayName(const QString& productType)
{
    if (productType == QStringLiteral("macos")) {
        return QStringLiteral("macOS");
    }
    if (productType == QStringLiteral("ios")) {
        return QStringLiteral("iOS");
    }
    return productType.isEmpty() ? QStringLiteral("unknown") : productType;
}

std::unique_ptr<QSettings> openSettings(const QString& settingsFilePath)
{
    auto settings = settingsFilePath.isEmpty()
        ? std::make_unique<QSettings>()
        : std::make_unique<QSettings>(settingsFilePath, QSettings::IniFormat);
    // 回退 = 本应用域里找不到时再去组织域、系统全局域找。备份和回滚要的是
    // 「本应用存了什么」，开着回退时 allKeys() 会把全局域的个人信息一并列出。
    settings->setFallbacksEnabled(false);
    return settings;
}

bool isLocalSettingKey(const QString& key)
{
    return AppSettings::isOwnedSettingKey(key) || key.startsWith(QStringLiteral("backup/"));
}

CapturedSettingsResult captureOwnedSettings(const QString& settingsFilePath,
                                            const BackupOperation& operation)
{
    const auto control = operation ? operation : std::make_shared<BackupOperationControl>();
    CapturedSettingsResult result;
    if (control->stopped()) {
        result.error = control->message();
        return result;
    }
    auto settings = openSettings(settingsFilePath);
    result.effectiveSettingsPath = settings->fileName();
    settings->sync();
    if (settings->status() != QSettings::NoError) {
        result.error = QStringLiteral("读取当前偏好失败");
        return result;
    }
    for (const QString& key : settings->allKeys()) {
        if (!control->checkpoint("settings-capture")) {
            result.error = control->message();
            return result;
        }
        // 只带本应用拥有的键；backup/ 是当前设备策略，恢复时保留本机值。
        if (!AppSettings::isOwnedSettingKey(key)) continue;
        QByteArray blob;
        QDataStream stream(&blob, QIODevice::WriteOnly);
        stream.setVersion(kSettingsStreamVersion);
        stream << settings->value(key);
        if (stream.status() != QDataStream::Ok) {
            result.error = QStringLiteral("序列化偏好失败：") + key;
            return result;
        }
        result.values.insert(key, blob);
    }
    result.success = !control->stopped();
    if (!result.success) result.error = control->message();
    return result;
}


namespace {
const auto kFormatVersion = QStringLiteral("1");
const QStringList kRequiredTables = {
    QStringLiteral("tasks"),
    QStringLiteral("focus_sessions"),
    QStringLiteral("categories")
};

// QVariant 的通用解码会递归创建容器，也会相信字符串声明的长度。
// 本应用偏好只有标量：先检查类型与实际负载长度，再交给 Qt 解码，避免在校验前耗尽栈或内存。
bool hasSafeSettingEncoding(const QByteArray& blob)
{
    QDataStream header(blob);
    header.setVersion(kSettingsStreamVersion);
    quint32 type = 0;
    quint8 nullFlag = 0;
    header >> type >> nullFlag;
    if (header.status() != QDataStream::Ok || nullFlag > 1) {
        return false;
    }
    qsizetype payloadSize = 0;
    switch (type) {
    case QMetaType::Bool: payloadSize = 1; break;
    case QMetaType::Int:
    case QMetaType::UInt: payloadSize = 4; break;
    case QMetaType::LongLong:
    case QMetaType::ULongLong:
    case QMetaType::Double: payloadSize = 8; break;
    case QMetaType::QString: {
        quint32 byteCount = 0;
        header >> byteCount;
        if (header.status() != QDataStream::Ok) {
            return false;
        }
        // 0xffffffff 表示空字符串；扩展长度标记及超过文件剩余量的长度一律拒绝。
        if (byteCount == 0xffffffffU) {
            return blob.size() == 9;
        }
        return byteCount <= kMaxSettingValueBytes && byteCount % 2 == 0
            && blob.size() == 9 + static_cast<qsizetype>(byteCount);
    }
    default:
        return false;
    }
    return blob.size() == 5 + payloadSize;
}

QString uniqueConnectionName(const QString& prefix)
{
    return prefix + QUuid::createUuid().toString(QUuid::WithoutBraces);
}

QString escapedSqlString(QString value)
{
    return value.replace(QLatin1Char('\''), QStringLiteral("''"));
}

QString quotedIdentifier(QString name)
{
    return QLatin1Char('"') + name.replace(QLatin1Char('"'), QStringLiteral("\"\"")) + QLatin1Char('"');
}

bool validateDataBudget(const QSqlDatabase& database, QString* reason)
{
    // 先使用SQLite解析结果识别虚拟表，不能对未受信模块发出数据查询。
    QSqlQuery virtualTables(database);
    if (!virtualTables.exec(QStringLiteral("SELECT name FROM pragma_table_list WHERE type IN ('virtual', 'shadow')"))) {
        *reason = QStringLiteral("读取备份结构失败");
        return false;
    }
    if (virtualTables.next()) {
        *reason = QStringLiteral("备份包含虚拟表（%1），出于安全考虑拒绝恢复")
                      .arg(virtualTables.value(0).toString());
        return false;
    }
    if (virtualTables.lastError().isValid()) {
        *reason = QStringLiteral("读取备份结构失败");
        return false;
    }
    QSqlQuery tables(database);
    tables.setForwardOnly(true);
    if (!tables.exec(QStringLiteral("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"))) {
        *reason = QStringLiteral("读取备份数据规模失败");
        return false;
    }
    qint64 totalRows = 0;
    while (tables.next()) {
        const QString name = tables.value(0).toString();
        const QString table = quotedIdentifier(name);
        // COUNT只扫描剩余额度加一行，不为拒绝异常文件先做一次无界全表计数。
        QSqlQuery count(database);
        if (!count.exec(QStringLiteral("SELECT COUNT(*) FROM (SELECT 1 FROM %1 LIMIT %2)")
                            .arg(table).arg(kMaxBackupRows - totalRows + 1)) || !count.next()) {
            *reason = QStringLiteral("检查备份行数预算失败");
            return false;
        }
        totalRows += count.value(0).toLongLong();
        if (totalRows > kMaxBackupRows) {
            *reason = QStringLiteral("备份总行数超出预算上限（500万行）");
            return false;
        }
        count.finish();

        QSqlQuery columns(database);
        columns.prepare(QStringLiteral("SELECT name, hidden FROM pragma_table_xinfo(:table)"));
        columns.bindValue(QStringLiteral(":table"), name);
        if (!columns.exec()) {
            *reason = QStringLiteral("读取备份字段结构失败");
            return false;
        }
        QStringList predicates;
        while (columns.next()) {
            // 数据库程序不能在规模检查时被当成数据执行，生成列可能临时制造巨量内容。
            if (columns.value(1).toInt() != 0) {
                *reason = QStringLiteral("备份包含生成列或隐藏列，无法按普通数据安全恢复");
                return false;
            }
            // 在SQLite内只取字节长度，不把整块文本/BLOB复制到Qt；TEXT的NUL不能截短检查值。
            predicates.append(QStringLiteral("length(CAST(%1 AS BLOB)) > %2")
                                  .arg(quotedIdentifier(columns.value(0).toString()))
                                  .arg(kMaxBackupCellBytes));
        }
        if (columns.lastError().isValid() || predicates.isEmpty()) {
            *reason = QStringLiteral("读取备份字段结构失败");
            return false;
        }
        QSqlQuery oversized(database);
        if (!oversized.exec(QStringLiteral("SELECT 1 FROM %1 WHERE %2 LIMIT 1")
                                .arg(table, predicates.join(QStringLiteral(" OR "))))) {
            *reason = QStringLiteral("检查备份字段预算失败");
            return false;
        }
        if (oversized.next()) {
            *reason = QStringLiteral("备份字段大小超出预算上限（16 MiB）");
            return false;
        }
        if (oversized.lastError().isValid()) {
            *reason = QStringLiteral("检查备份字段预算失败");
            return false;
        }
    }
    if (tables.lastError().isValid()) {
        *reason = QStringLiteral("读取备份数据规模失败");
        return false;
    }
    return true;
}

QString normalizedPath(const QString& path)
{
    const QFileInfo input(path);
    const QString absolutePath = QDir::cleanPath(input.absoluteFilePath());
    const QFileInfo absoluteInfo(absolutePath);
    const QString canonicalPath = absoluteInfo.canonicalFilePath();
    if (!canonicalPath.isEmpty()) {
        return QDir::cleanPath(canonicalPath);
    }

    // 目标文件尚不存在时 canonicalFilePath() 会返回空。向上找到已存在的父目录，
    // 先规范化其中的符号链接，再补回不存在的目录和文件名，避免别名绕过保护检查。
    QStringList missingDirectories;
    QString existingParent = absoluteInfo.absolutePath();
    while (!QFileInfo::exists(existingParent)) {
        const QFileInfo parentInfo(existingParent);
        const QString directoryName = parentInfo.fileName();
        const QString nextParent = parentInfo.absolutePath();
        if (directoryName.isEmpty() || nextParent == existingParent) {
            break;
        }
        missingDirectories.prepend(directoryName);
        existingParent = nextParent;
    }

    QString normalizedParent = QFileInfo(existingParent).canonicalFilePath();
    if (normalizedParent.isEmpty()) {
        normalizedParent = QDir::cleanPath(existingParent);
    }
    for (const QString& directoryName : missingDirectories) {
        normalizedParent = QDir(normalizedParent).filePath(directoryName);
    }
    return QDir::cleanPath(QDir(normalizedParent).filePath(absoluteInfo.fileName()));
}

bool pathsMatch(const QString& leftPath, const QString& rightPath)
{
    return !rightPath.isEmpty() && normalizedPath(leftPath) == normalizedPath(rightPath);
}

bool tableExists(const QSqlDatabase& database, const QString& tableName)
{
    QSqlQuery query(database);
    query.prepare(QStringLiteral(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = :name"));
    query.bindValue(QStringLiteral(":name"), tableName);
    return query.exec() && query.next();
}

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

bool validateRequiredTableStructure(const QSqlDatabase& database,
                                    bool requireScheduleTables,
                                    bool requireKnowledgeGapTable,
                                    bool requireMemoTable,
                                    bool requireTrashTable,
                                    QString* reason)
{
    struct TableContract {
        QString name;
        QStringList columns;
        QStringList sqlFragments;
    };

    // 这里只校验所有历史版本都依赖、且迁移链无法补回的基础结构。
    // estimated_minutes、mode 等版本列由 DatabaseManager 的防御性迁移补齐；
    // title、start_time 这类基础列一旦缺失，CREATE TABLE IF NOT EXISTS 不会自愈。
    const QList<TableContract> contracts = {
        {QStringLiteral("tasks"),
         {QStringLiteral("id"),
          QStringLiteral("title"),
          QStringLiteral("category"),
          QStringLiteral("date"),
          QStringLiteral("completed"),
          QStringLiteral("created_at")}, {}},
        {QStringLiteral("focus_sessions"),
         {QStringLiteral("id"),
          QStringLiteral("task_id"),
          QStringLiteral("start_time"),
          QStringLiteral("end_time"),
          QStringLiteral("duration")}, {}},
        {QStringLiteral("categories"),
         {QStringLiteral("id"),
          QStringLiteral("name"),
          QStringLiteral("color"),
          QStringLiteral("is_preset"),
          QStringLiteral("display_order"),
          QStringLiteral("created_at")}, {}},
    };

    QList<TableContract> versionedContracts = contracts;
    if (requireScheduleTables) {
        // v13 以后课表已是正式业务数据。不能像老版备份那样容忍表缺失，
        // 否则恢复后迁移会创建一张空表，把“数据丢了”伪装成“恢复成功”。
        versionedContracts.append(
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
              QStringLiteral("check(week_end>=week_start)")}});
        versionedContracts.append(
            {QStringLiteral("schedule_periods"),
             {QStringLiteral("id"), QStringLiteral("period_index"),
              QStringLiteral("start_minutes"), QStringLiteral("end_minutes")},
             {QStringLiteral("period_indexintegernotnullunique"),
              QStringLiteral("check(period_index>=1)"),
              QStringLiteral("check(start_minutesbetween0and1439)"),
              QStringLiteral("check(end_minutesbetween1and1440)"),
              QStringLiteral("check(end_minutes>start_minutes)")}});
    }
    if (requireKnowledgeGapTable) {
        // v14 起知识缺口是正式业务数据，且内容全部是用户手写、丢了不可再生。
        // 和课表一样只对 v14 及以后的备份要求这张表：更早的备份本来就没有它，
        // 无条件要求会把全部历史备份判成损坏（业务规则明文禁止这么做）。
        versionedContracts.append(
            {QStringLiteral("knowledge_gaps"),
             {QStringLiteral("id"), QStringLiteral("title"), QStringLiteral("detail"),
              QStringLiteral("category_id"), QStringLiteral("source_task_id"),
              QStringLiteral("source_task_title"), QStringLiteral("priority"),
              QStringLiteral("status"), QStringLiteral("due_date"),
              QStringLiteral("resolution"), QStringLiteral("linked_task_id"),
              QStringLiteral("created_at"), QStringLiteral("updated_at"),
              QStringLiteral("resolved_at")},
             {QStringLiteral("check(length(trim(title))>0)"),
              QStringLiteral("check(priorityin(0,1,2))"),
              QStringLiteral("check(statusin(0,1,2))")}});
    }

    for (const TableContract& contract : versionedContracts) {
        if (!tableExists(database, contract.name)) {
            *reason = QStringLiteral("备份缺少必要的数据表：%1").arg(contract.name);
            return false;
        }
        if ((contract.name.startsWith(QStringLiteral("schedule_"))
             || contract.name == QStringLiteral("knowledge_gaps"))
            && !DatabaseManager::hasGeneratedIntegerId(database, contract.name)) {
            *reason = QStringLiteral("备份表主键不能自动生成整数编号：%1").arg(contract.name);
            return false;
        }
        QSqlQuery columns(database);
        if (!columns.exec(
                QStringLiteral("PRAGMA table_info(%1)").arg(contract.name))) {
            *reason = QStringLiteral("读取备份表结构失败：%1").arg(contract.name);
            return false;
        }

        QStringList names;
        bool idIsPrimaryKey = false;
        while (columns.next()) {
            const QString columnName = columns.value(1).toString();
            names.append(columnName);
            if (columnName == QStringLiteral("id") && columns.value(5).toInt() > 0) {
                idIsPrimaryKey = true;
            }
        }

        for (const QString& requiredColumn : contract.columns) {
            if (!names.contains(requiredColumn)) {
                *reason = QStringLiteral("备份表结构不完整，缺少 %1.%2")
                              .arg(contract.name, requiredColumn);
                return false;
            }
        }
        if (!idIsPrimaryKey) {
            *reason = QStringLiteral("备份表结构不完整，%1.id 不是主键")
                          .arg(contract.name);
            return false;
        }

        if (!contract.sqlFragments.isEmpty()) {
            QSqlQuery sqlQuery(database);
            sqlQuery.prepare(QStringLiteral(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = :name"));
            sqlQuery.bindValue(QStringLiteral(":name"), contract.name);
            if (!sqlQuery.exec() || !sqlQuery.next()) {
                *reason = QStringLiteral("读取备份表约束失败：%1").arg(contract.name);
                return false;
            }
            const QString createSql = normalizedCreateSql(sqlQuery.value(0).toString());
            for (const QString& fragment : contract.sqlFragments) {
                if (!createSql.contains(fragment)) {
                    *reason = QStringLiteral("备份表约束不完整：%1").arg(contract.name);
                    return false;
                }
            }
        }
    }

    if (requireScheduleTables) {
        QSqlQuery foreignKey(database);
        if (!foreignKey.exec(QStringLiteral("PRAGMA foreign_key_list(schedule_entries)"))) {
            *reason = QStringLiteral("读取课表外键失败");
            return false;
        }
        bool categoryForeignKeyFound = false;
        while (foreignKey.next()) {
            if (foreignKey.value(2).toString() == QStringLiteral("categories")
                && foreignKey.value(3).toString() == QStringLiteral("category_id")
                && foreignKey.value(4).toString() == QStringLiteral("id")
                && foreignKey.value(6).toString().compare(
                       QStringLiteral("SET NULL"), Qt::CaseInsensitive) == 0) {
                categoryForeignKeyFound = true;
                break;
            }
        }
        if (!categoryForeignKeyFound) {
            *reason = QStringLiteral("备份课表外键不完整");
            return false;
        }
    }

    // 与启动检查共用同一份外键契约。只看列和 CHECK 会放过 ON DELETE CASCADE 的表：
    // 恢复成功、启动正常，直到删掉一条任务时，关联它的知识缺口被无声地连带删除。
    if (requireKnowledgeGapTable && !DatabaseManager::knowledgeGapForeignKeysAreValid(database)) {
        *reason = QStringLiteral("备份知识缺口外键不完整");
        return false;
    }
    // v20 才引入备忘录：旧备份恢复后建空表，新备份缺表或错约束必须拒绝，
    // 不能把用户手写内容丢失伪装成一次成功恢复。完整契约与启动共用，避免两处漂移。
    if (requireMemoTable && !DatabaseManager::memoSchemaIsValid(database)) {
        *reason = QStringLiteral("备份 memos 表结构或外键不完整");
        return false;
    }
    // v21 才引入废纸篓：更早的备份不要求，恢复后由迁移建空表；v21 及以后缺表或结构不对必须拒绝，
    // 否则恢复成功后用户的「找回」兜底会静默缺失。契约与启动检查共用。
    if (requireTrashTable && !DatabaseManager::trashSchemaIsValid(database)) {
        *reason = QStringLiteral("备份 trash_items 表结构不完整");
        return false;
    }

    return true;
}

QString businessDateCondition(const QString& column)
{
    // date() 归一后与原文比较：2 月 30 日这类非法日期会变成别的日子，比较不等即被识别。加 '+0 days'
    // 让日期必经一次换算，不依赖各 SQLite 版本对无修饰符输入是否归一（实测 3.54 不加也归一）。
    // Qt 的 QDate 不存在公元 0 年；不对可处理的历史日期再套当前界面的输入范围。
    return QStringLiteral("typeof(%1) = 'text' AND substr(%1, 1, 4) <> '0000' AND date(%1, '+0 days') IS %1")
        .arg(quotedIdentifier(column));
}

QString businessDateTimeCondition(const QString& column)
{
    // 历史写入既有 SQLite 的空格分隔时间，也有 Qt ISO 时间（含毫秒、Z 或时区偏移）。
    // 只往返原日期部分并检查时间可解析，不把 datetime() 转成 UTC 后的文本强行与原文比较。
    return QStringLiteral("typeof(%1) = 'text' AND substr(%1, 1, 4) <> '0000' "
                          "AND date(substr(%1, 1, 10), '+0 days') IS substr(%1, 1, 10) "
                          "AND datetime(%1) IS NOT NULL")
        .arg(quotedIdentifier(column));
}

bool validateBusinessValues(const QSqlDatabase& database, int schemaVersion,
                            const BackupOperation& control, QString* reason)
{
    struct ValueContract {
        QString table;
        int sinceVersion;
        QString column;
        QString condition;
        QString description;
    };
    // 宁可放过，不可误拒：这里只拦当前读取/计算无法正确处理的值，不复制新建、编辑界面的限制。
    // 每条注明读取依据；已有 CHECK 的枚举由完整性检查兜底，不重复收紧历史取值。
    const QList<ValueContract> contracts = {
        // TaskManager 按 date 的 ISO 文本取日期区间，按 completed=0/1 筛状态。
        {QStringLiteral("tasks"), 0, QStringLiteral("date"), businessDateCondition(QStringLiteral("date")),
         QStringLiteral("任务日期 date")},
        {QStringLiteral("tasks"), 0, QStringLiteral("completed"),
         QStringLiteral("typeof(completed) = 'integer' AND completed IN (0, 1)"), QStringLiteral("完成状态 completed")},
        // CategoryManager 分别用 is_preset=0/1 查询两组；其它值会在分组和删除规则里消失。
        {QStringLiteral("categories"), 2, QStringLiteral("is_preset"),
         QStringLiteral("typeof(is_preset) = 'integer' AND is_preset IN (0, 1)"), QStringLiteral("预置标志 is_preset")},
        // RoutineManager 只生成 active=1 且生成戳早于今天的实例，乱码戳会永久阻止生成。
        // NULL 与空戳均是旧记录/收回后允许的未生成状态。
        {QStringLiteral("routines"), 3, QStringLiteral("active"),
         QStringLiteral("typeof(active) = 'integer' AND active IN (0, 1)"), QStringLiteral("启用标志 active")},
        // v15 的 CHECK 已保证掩码范围；位掩码是生成日的整数开关，小数会在 SQL 位运算和界面读取时被丢弃。
        {QStringLiteral("routines"), 15, QStringLiteral("weekdays"), QStringLiteral("typeof(weekdays) = 'integer'"),
         QStringLiteral("重复日掩码 weekdays")},
        {QStringLiteral("routines"), 3, QStringLiteral("last_generated_date"),
         QStringLiteral("last_generated_date IS NULL OR last_generated_date = '' OR (%1)")
             .arg(businessDateCondition(QStringLiteral("last_generated_date"))), QStringLiteral("生成日期 last_generated_date")},
        // FocusHistoryService 按 SQLite 日期聚合并以整数秒读取；未结束行允许 NULL，旧短记录和零秒不套 180 秒门槛。
        {QStringLiteral("focus_sessions"), 0, QStringLiteral("start_time"), businessDateTimeCondition(QStringLiteral("start_time")),
         QStringLiteral("开始时间 start_time")},
        {QStringLiteral("focus_sessions"), 0, QStringLiteral("end_time"),
         QStringLiteral("end_time IS NULL OR (%1)").arg(businessDateTimeCondition(QStringLiteral("end_time"))),
         QStringLiteral("结束时间 end_time")},
        {QStringLiteral("focus_sessions"), 0, QStringLiteral("duration"),
         QStringLiteral("duration IS NULL OR (typeof(duration) = 'integer' AND duration >= 0)"),
         QStringLiteral("专注秒数 duration")},
        // rest_sessions 不由 user_version 引入；按实际表/列存在性判断。休息读取同样依赖有效时间和整数正秒数。
        {QStringLiteral("rest_sessions"), 0, QStringLiteral("start_time"), businessDateTimeCondition(QStringLiteral("start_time")),
         QStringLiteral("开始时间 start_time")},
        {QStringLiteral("rest_sessions"), 0, QStringLiteral("end_time"), businessDateTimeCondition(QStringLiteral("end_time")),
         QStringLiteral("结束时间 end_time")},
        {QStringLiteral("rest_sessions"), 0, QStringLiteral("duration"),
         QStringLiteral("typeof(duration) = 'integer' AND duration > 0"), QStringLiteral("休息秒数 duration")},
        // KnowledgeGapService 用 ISO 日期计算逾期；旧空串与 NULL 都可显示为无排期，不拒绝整份备份。
        {QStringLiteral("knowledge_gaps"), 14, QStringLiteral("due_date"),
         QStringLiteral("due_date IS NULL OR due_date = '' OR (%1)").arg(businessDateCondition(QStringLiteral("due_date"))),
         QStringLiteral("计划日期 due_date")},
        // ScheduleService 把这些列读作整数，并以原值查询星期、时间与周次；小数会造成显示和冲突查询不一致。
        // v13 表约束已校验原有范围和先后关系，这里只补整数性，不引入当前界面的额外上限。
        {QStringLiteral("schedule_entries"), 13, QStringLiteral("weekday"), QStringLiteral("typeof(weekday) = 'integer'"),
         QStringLiteral("星期 weekday")},
        {QStringLiteral("schedule_entries"), 13, QStringLiteral("start_minutes"), QStringLiteral("typeof(start_minutes) = 'integer'"),
         QStringLiteral("开始分钟 start_minutes")},
        {QStringLiteral("schedule_entries"), 13, QStringLiteral("end_minutes"), QStringLiteral("typeof(end_minutes) = 'integer'"),
         QStringLiteral("结束分钟 end_minutes")},
        {QStringLiteral("schedule_entries"), 13, QStringLiteral("week_start"), QStringLiteral("typeof(week_start) = 'integer'"),
         QStringLiteral("起始周 week_start")},
        {QStringLiteral("schedule_entries"), 13, QStringLiteral("week_end"), QStringLiteral("typeof(week_end) = 'integer'"),
         QStringLiteral("结束周 week_end")},
        {QStringLiteral("schedule_periods"), 13, QStringLiteral("period_index"), QStringLiteral("typeof(period_index) = 'integer'"),
         QStringLiteral("节次编号 period_index")},
        {QStringLiteral("schedule_periods"), 13, QStringLiteral("start_minutes"), QStringLiteral("typeof(start_minutes) = 'integer'"),
         QStringLiteral("开始分钟 start_minutes")},
        {QStringLiteral("schedule_periods"), 13, QStringLiteral("end_minutes"), QStringLiteral("typeof(end_minutes) = 'integer'"),
         QStringLiteral("结束分钟 end_minutes")},
        // 倒计时早期由服务惰性建表，无固定 schema 起点；无效目标日期会被当成剩余零天。
        {QStringLiteral("countdown_goals"), 0, QStringLiteral("target_date"), businessDateCondition(QStringLiteral("target_date")),
         QStringLiteral("目标日期 target_date")},
        // TrashService 先解析 JSON，再判断类型/载荷版本；未知类型与未来版本仍允许留存，不限制为当前枚举。
        {QStringLiteral("trash_items"), 21, QStringLiteral("payload"), QStringLiteral("json_valid(payload)"),
         QStringLiteral("JSON 载荷 payload")},
        // TrashStore 写 UTC ISO 毫秒；TrashService 依赖删除时间展示和计算清理期限。
        {QStringLiteral("trash_items"), 21, QStringLiteral("deleted_at"), businessDateTimeCondition(QStringLiteral("deleted_at")),
         QStringLiteral("删除时间 deleted_at")},
    };
    QHash<QString, QSet<QString>> columnsByTable;
    for (const ValueContract& contract : contracts) {
        if (schemaVersion < contract.sinceVersion) {
            continue;
        }
        if (!control->checkpoint("inspect-domain-values")) {
            *reason = control->message();
            return false;
        }
        if (!columnsByTable.contains(contract.table)) {
            // 版本列可能由防御性迁移补齐，旧版也可能没有惰性表；只检查确实存在的普通表和列。
            // 不读取同名 View 的表达式：数据库对象合法性仍由后面的专门检查决定。
            QSqlQuery table(database);
            table.prepare(QStringLiteral("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = :name"));
            table.bindValue(QStringLiteral(":name"), contract.table);
            if (!table.exec()) {
                *reason = QStringLiteral("读取备份业务表失败：%1").arg(contract.table);
                return false;
            }
            QSet<QString> names;
            if (table.next()) {
                QSqlQuery columns(database);
                if (!columns.exec(QStringLiteral("PRAGMA table_info(%1)").arg(quotedIdentifier(contract.table)))) {
                    *reason = QStringLiteral("读取备份业务字段失败：%1").arg(contract.table);
                    return false;
                }
                while (columns.next()) {
                    names.insert(columns.value(1).toString());
                }
                if (columns.lastError().isValid()) {
                    *reason = QStringLiteral("读取备份业务字段失败：%1").arg(contract.table);
                    return false;
                }
            } else if (table.lastError().isValid()) {
                *reason = QStringLiteral("读取备份业务表失败：%1").arg(contract.table);
                return false;
            }
            columnsByTable.insert(contract.table, names);
        }
        if (!columnsByTable.value(contract.table).contains(contract.column)) {
            continue;
        }
        QSqlQuery invalid(database);
        if (!invalid.exec(QStringLiteral("SELECT COUNT(*) FROM %1 WHERE NOT (%2)")
                              .arg(quotedIdentifier(contract.table), contract.condition)) || !invalid.next()) {
            *reason = control->stopped() ? control->message()
                : QStringLiteral("检查备份中 %1 的 %2 失败").arg(contract.table, contract.description);
            return false;
        }
        const qint64 count = invalid.value(0).toLongLong();
        invalid.finish();
        if (!control->checkpoint("inspect-domain-values")) {
            *reason = control->message();
            return false;
        }
        if (count > 0) {
            *reason = QStringLiteral("备份中 %1 的 %2 有 %3 条不合法")
                          .arg(contract.table, contract.description).arg(count);
            return false;
        }
    }
    return true;
}

OperationResult embedMetadataAndSettings(const QString& snapshotPath,
                                         const OwnedSettings& settings,
                                         const QString& kind,
                                         int schemaVersion, const BackupOperation& control)
{
    OperationResult result;
    const QString connectionName = uniqueConnectionName(QStringLiteral("BackupMetadata_"));
    {
        QSqlDatabase database = QSqlDatabase::addDatabase(new BackupSqliteDriver(control), connectionName);
        database.setDatabaseName(snapshotPath);
        if (!database.open()) {
            result.error = QStringLiteral("无法写入备份元数据：") + database.lastError().text();
        } else {
            QSqlQuery query(database);
            auto exec = [&query, &result](const QString& sql, const QString& message) {
                if (query.exec(sql)) {
                    return true;
                }
                result.error = message + QStringLiteral("：") + query.lastError().text();
                return false;
            };

            bool ok = exec(QStringLiteral("PRAGMA user_version = %1").arg(schemaVersion),
                           QStringLiteral("写入数据库版本失败"))
                && exec(QStringLiteral(
                            "CREATE TABLE IF NOT EXISTS backup_meta "
                            "(key TEXT PRIMARY KEY, value TEXT NOT NULL)"),
                        QStringLiteral("创建备份元数据表失败"))
                && exec(QStringLiteral(
                            "CREATE TABLE IF NOT EXISTS backup_settings "
                            "(key TEXT PRIMARY KEY, value BLOB NOT NULL)"),
                        QStringLiteral("创建偏好备份表失败"));

            if (ok && !database.transaction()) {
                result.error = QStringLiteral("启动备份元数据事务失败：") + database.lastError().text();
                ok = false;
            }

            auto putMeta = [&database, &result](const QString& key, const QString& value) {
                QSqlQuery insert(database);
                insert.prepare(QStringLiteral(
                    "INSERT OR REPLACE INTO backup_meta (key, value) VALUES (:key, :value)"));
                insert.bindValue(QStringLiteral(":key"), key);
                insert.bindValue(QStringLiteral(":value"), value);
                if (insert.exec()) {
                    return true;
                }
                result.error = QStringLiteral("写入备份元数据失败：") + insert.lastError().text();
                return false;
            };

            if (ok) {
                const QString applicationVersion =
                    QCoreApplication::applicationVersion().isEmpty()
                    ? QStringLiteral("unknown")
                    : QCoreApplication::applicationVersion();
                ok = putMeta(QStringLiteral("format_version"), kFormatVersion)
                    && putMeta(QStringLiteral("created_at"),
                               QDateTime::currentDateTime().toString(Qt::ISODate))
                    && putMeta(QStringLiteral("app_version"), applicationVersion)
                    && putMeta(QStringLiteral("schema_version"), QString::number(schemaVersion))
                    && putMeta(QStringLiteral("platform"), platformDisplayName(QSysInfo::productType()))
                    && putMeta(QStringLiteral("kind"), kind);
            }

            if (ok) {
                for (auto it = settings.constBegin(); it != settings.constEnd(); ++it) {
                    if (!control->checkpoint("metadata-setting")) {
                        result.error = control->message();
                        ok = false;
                        break;
                    }
                    QSqlQuery insert(database);
                    insert.prepare(QStringLiteral(
                        "INSERT OR REPLACE INTO backup_settings (key, value) "
                        "VALUES (:key, :value)"));
                    insert.bindValue(QStringLiteral(":key"), it.key());
                    insert.bindValue(QStringLiteral(":value"), it.value());
                    if (!insert.exec()) {
                        result.error = QStringLiteral("写入偏好备份失败：")
                            + insert.lastError().text();
                        ok = false;
                        break;
                    }
                }
            }

            if (ok && !control->checkpoint("metadata-before-commit")) {
                result.error = control->message();
                ok = false;
            }
            if (ok) {
                if (!database.commit()) {
                    result.error = QStringLiteral("提交备份元数据失败：")
                        + database.lastError().text();
                    ok = false;
                    database.rollback();
                }
            } else if (database.isOpen()) {
                database.rollback();
            }

            result.success = ok;
            database.close();
        }
    }
    QSqlDatabase::removeDatabase(connectionName);
    if (control->stopped()) {
        result.success = false;
        result.error = control->message();
    }
    return result;
}

} // namespace

OperationResult atomicCopy(const QString& sourcePath, const QString& destinationPath, qint64 maxBytes,
                           const BackupOperation& operation)
{
    const auto control = operation ? operation : std::make_shared<BackupOperationControl>();
    OperationResult result;
    if (!control->checkpoint("operation-start")) {
        result.error = control->message();
        return result;
    }
    if (!QFileInfo(sourcePath).isFile()) {
        result.error = QStringLiteral("复制源必须是普通文件");
        return result;
    }
    QFile source(sourcePath);
    if (!source.open(QIODevice::ReadOnly)) {
        result.error = QStringLiteral("无法读取源文件：") + source.errorString();
        return result;
    }
    // 在创建目标临时文件之前拒绝越界源；负值仅用于可信本地回滚，不限制原有数据规模。
    if (maxBytes >= 0 && source.size() > maxBytes) {
        result.error = QStringLiteral("备份文件大小超出预算上限，未复制");
        return result;
    }

    const QFileInfo destinationInfo(destinationPath);
    if (!QDir().mkpath(destinationInfo.absolutePath())) {
        result.error = QStringLiteral("无法创建目标目录");
        return result;
    }

    // QSaveFile 在同目录写临时文件并用原子替换提交。禁止直接写回退，确保失败时旧文件仍完整。
    QSaveFile destination(destinationPath);
    destination.setDirectWriteFallback(false);
    if (!destination.open(QIODevice::WriteOnly)) {
        result.error = QStringLiteral("无法创建目标文件：") + destination.errorString();
        return result;
    }

    constexpr qint64 kChunkSize = 1024 * 1024;
    qint64 copiedBytes = 0;
    while (!source.atEnd()) {
        if (!control->checkpoint("copy-chunk")) {
            destination.cancelWriting();
            result.error = control->message();
            return result;
        }
        const QByteArray chunk = source.read(kChunkSize);
        if (chunk.isEmpty() && source.error() != QFileDevice::NoError) {
            destination.cancelWriting();
            result.error = QStringLiteral("读取源文件失败：") + source.errorString();
            return result;
        }
        // 初始大小检查后源仍可能增长；按实际字节再检查，QSaveFile失败不替换旧目标。
        if (maxBytes >= 0 && chunk.size() > maxBytes - copiedBytes) {
            destination.cancelWriting();
            result.error = QStringLiteral("备份文件大小超出预算上限，未复制");
            return result;
        }
        if (destination.write(chunk) != chunk.size()) {
            destination.cancelWriting();
            result.error = QStringLiteral("写入目标文件失败：") + destination.errorString();
            return result;
        }
        copiedBytes += chunk.size();
    }

    if (!control->checkpoint("copy-before-commit")) {
        destination.cancelWriting();
        result.error = control->message();
        return result;
    }
    if (!destination.commit()) {
        result.error = QStringLiteral("原子替换目标文件失败：") + destination.errorString();
        return result;
    }

    result.committed = true;
    // 提交已发生时即便同时收到取消，也保留committed事实，调用方据此决定验证或回滚。
    result.success = control->checkpoint("copy-after-commit");
    if (!result.success) result.error = control->message();
    return result;
}

OperationResult createSnapshot(const QString& sourceDatabasePath,
                               const QString& settingsFilePath,
                               const QString& destinationPath,
                               const QString& kind,
                               int currentSchemaVersion, const BackupOperation& operation,
                               const QString& stagingDirectory)
{
    // 兼容同步调用方：仍使用同一偏好编码与校验，文件执行入口不再访问 QSettings。
    const auto control = operation ? operation : std::make_shared<BackupOperationControl>();
    const auto captured = captureOwnedSettings(settingsFilePath, control);
    if (!captured.success) return {false, captured.error};
    return createSnapshot({sourceDatabasePath, destinationPath, stagingDirectory,
                           captured.effectiveSettingsPath, kind, currentSchemaVersion,
                           captured.values}, control);
}

OperationResult createSnapshot(const SnapshotRequest& request, const BackupOperation& operation)
{
    const auto& sourceDatabasePath = request.sourceDatabasePath;
    const auto& destinationPath = request.destinationPath;
    const auto& effectiveSettingsPath = request.effectiveSettingsPath;
    const int currentSchemaVersion = request.currentSchemaVersion;
    const auto control = operation ? operation : std::make_shared<BackupOperationControl>();
    OperationResult result;
    if (!control->checkpoint("operation-start")) {
        result.error = control->message();
        return result;
    }
    if (sourceDatabasePath.isEmpty() || !QFileInfo::exists(sourceDatabasePath)) {
        result.error = QStringLiteral("数据库路径无效");
        return result;
    }
    if (destinationPath.trimmed().isEmpty()) {
        result.error = QStringLiteral("备份目标路径为空");
        return result;
    }

    if (pathsMatch(destinationPath, sourceDatabasePath)) {
        result.error = QStringLiteral("备份目标不能覆盖正在使用的数据库");
        return result;
    }

    // SQLite 的 WAL/SHM/journal 和 QSettings 锁文件都可能在运行时被写入；即使目标文件
    // 还不存在，也必须按规范化路径拒绝，避免快照的原子替换破坏当前进程的数据或偏好。
    QStringList protectedRuntimeFiles = {
        sourceDatabasePath + QStringLiteral("-wal"),
        sourceDatabasePath + QStringLiteral("-shm"),
        sourceDatabasePath + QStringLiteral("-journal"),
        // 与SyncController的独立关闭记录同源；它不能被手动备份覆盖成SQLite文件。
        sourceDatabasePath + QStringLiteral(".sync-disabled")
    };
    if (!effectiveSettingsPath.isEmpty()) {
        protectedRuntimeFiles.append(effectiveSettingsPath);
        protectedRuntimeFiles.append(effectiveSettingsPath + QStringLiteral(".lock"));
    }
    for (const QString& protectedPath : protectedRuntimeFiles) {
        if (pathsMatch(destinationPath, protectedPath)) {
            result.error = protectedPath == effectiveSettingsPath
                ? QStringLiteral("备份目标不能覆盖当前设置文件")
                : QStringLiteral("备份目标不能覆盖运行时受保护文件");
            return result;
        }
    }

    const QFileInfo destinationInfo(destinationPath);
    if (!QDir().mkpath(destinationInfo.absolutePath())) {
        result.error = QStringLiteral("无法创建备份目录");
        return result;
    }

    const QString stagingDirectory = request.stagingDirectory.isEmpty()
        ? destinationInfo.absolutePath() : request.stagingDirectory;
    if (!QDir().mkpath(stagingDirectory)) {
        result.error = QStringLiteral("无法创建快照暂存目录");
        return result;
    }
    const QString temporaryPath = QDir(stagingDirectory).filePath(
        QStringLiteral(".snapshot-tmp-") + QUuid::createUuid().toString(QUuid::WithoutBraces)
        + QStringLiteral(".tmp"));
    const auto cleanup = qScopeGuard([&] { QFile::remove(temporaryPath); });
    const QString connectionName = uniqueConnectionName(QStringLiteral("BackupSnapshot_"));
    int schemaVersion = -1;
    {
        QSqlDatabase source = QSqlDatabase::addDatabase(new BackupSqliteDriver(control), connectionName);
        source.setDatabaseName(sourceDatabasePath);
        if (!source.open()) {
            result.error = QStringLiteral("无法打开数据库快照连接：") + source.lastError().text();
        } else {
            // 等锁由独立驱动的busy回调负责；不能用PRAGMA busy_timeout覆盖取消回调。
            if (result.error.isEmpty()) {
                QSqlQuery version(source);
                if (!version.exec(QStringLiteral("PRAGMA user_version")) || !version.next()) {
                    result.error = QStringLiteral("读取数据库版本失败：")
                        + version.lastError().text();
                } else {
                    schemaVersion = version.value(0).toInt();
                }
            }

            if (result.error.isEmpty()
                && (schemaVersion < 0 || schemaVersion > currentSchemaVersion)) {
                result.error = QStringLiteral("当前数据库版本不受支持，无法备份");
            }

            if (result.error.isEmpty()) {
                // 默认回滚日志下 VACUUM INTO（生成完整 SQLite 副本）全程持有主库读锁。
                // 先写本地暂存，避免外置目标的慢 I/O 一直阻塞主库写入；发布前已关闭源连接。
                QSqlQuery vacuum(source);
                const QString sql = QStringLiteral("VACUUM main INTO '%1'")
                    .arg(escapedSqlString(temporaryPath));
                if (!vacuum.exec(sql)) {
                    result.error = QStringLiteral("生成数据库快照失败：")
                        + vacuum.lastError().text();
                }
            }
            source.close();
        }
    }
    QSqlDatabase::removeDatabase(connectionName);

    if (control->stopped()) result.error = control->message();
    if (!result.error.isEmpty()) {
        return result;
    }

    result = embedMetadataAndSettings(
        temporaryPath, request.settings, request.kind, schemaVersion, control);
    if (!result.success) {
        return result;
    }

    // 发布与恢复采用同一可恢复性门禁；否则超限的本地数据会产生“成功但无法恢复”的备份。
    const QVariantMap inspection = inspectBackup(temporaryPath, currentSchemaVersion, control);
    if (!inspection.value(QStringLiteral("valid")).toBool()) {
        result.success = false;
        result.error = inspection.value(QStringLiteral("reason")).toString();
        return result;
    }

    // 不发布本版本会拒绝恢复的超限文件；失败保留原目标，临时快照在下面统一移除。
    result = atomicCopy(temporaryPath, destinationPath, kMaxBackupFileBytes, control);
    return result;
}

QVariantMap inspectBackup(const QString& sourcePath, int currentSchemaVersion, const BackupOperation& operation)
{
    const auto control = operation ? operation : std::make_shared<BackupOperationControl>();
    QVariantMap result;
    if (!control->checkpoint("inspect-start")) {
        return {{QStringLiteral("valid"), false}, {QStringLiteral("reason"), control->message()}};
    }
    result.insert(QStringLiteral("valid"), false);

    const QFileInfo info(sourcePath);
    if (!info.exists() || !info.isFile() || !info.isReadable()) {
        result.insert(QStringLiteral("reason"), QStringLiteral("备份文件不存在或无法读取"));
        return result;
    }
    if (info.size() > kMaxBackupFileBytes) {
        result.insert(QStringLiteral("reason"), QStringLiteral("备份文件大小超出预算上限（512 MiB），无法恢复"));
        return result;
    }

    const QString connectionName = uniqueConnectionName(QStringLiteral("BackupInspect_"));
    QString reason;
    {
        QSqlDatabase database = QSqlDatabase::addDatabase(new BackupSqliteDriver(control), connectionName);
        database.setDatabaseName(sourcePath);
        database.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
        if (!database.open()) {
            reason = QStringLiteral("这不是有效的备份文件");
        } else {
            // 在读取元数据值、业务结构和完整性检查前拒绝超额数据，不能先物化大字段再检查。
            if (validateDataBudget(database, &reason)) {
                QSqlQuery integrity(database);
                if (!integrity.exec(QStringLiteral("PRAGMA integrity_check")) || !integrity.next()
                    || integrity.value(0).toString() != QStringLiteral("ok")) {
                    reason = QStringLiteral("备份文件已损坏，无法恢复");
                }
            }

            if (reason.isEmpty()) {
                for (const QString& table : kRequiredTables) {
                    if (!tableExists(database, table)) {
                        reason = QStringLiteral("备份缺少必要的数据表，可能不是本应用的备份");
                        break;
                    }
                }
            }

            if (reason.isEmpty()
                && (!tableExists(database, QStringLiteral("backup_meta"))
                    || !tableExists(database, QStringLiteral("backup_settings")))) {
                reason = QStringLiteral("备份缺少格式信息或偏好数据");
            }

            QVariantMap metadata;
            if (reason.isEmpty()) {
                QSqlQuery meta(database);
                if (!meta.exec(QStringLiteral("SELECT key, value FROM backup_meta"))) {
                    reason = QStringLiteral("读取备份格式信息失败");
                } else {
                    while (meta.next()) {
                        metadata.insert(meta.value(0).toString(), meta.value(1).toString());
                    }
                }
            }

            if (reason.isEmpty()
                && metadata.value(QStringLiteral("format_version")).toString() != kFormatVersion) {
                reason = QStringLiteral("该备份格式不受当前版本支持");
            }

            bool metadataVersionValid = false;
            const int metadataVersion =
                metadata.value(QStringLiteral("schema_version")).toString()
                    .toInt(&metadataVersionValid);
            int pragmaVersion = -1;
            if (reason.isEmpty()) {
                QSqlQuery version(database);
                if (!version.exec(QStringLiteral("PRAGMA user_version")) || !version.next()) {
                    reason = QStringLiteral("读取备份数据库版本失败");
                } else {
                    pragmaVersion = version.value(0).toInt();
                }
            }

            if (reason.isEmpty()
                && (!metadataVersionValid || metadataVersion < 0
                    || metadataVersion != pragmaVersion)) {
                reason = QStringLiteral("备份版本信息不一致，无法安全恢复");
            }
            if (reason.isEmpty() && pragmaVersion > currentSchemaVersion) {
                reason = QStringLiteral("该备份由更高版本创建，当前版本无法恢复");
            }
            if (reason.isEmpty()) {
                validateRequiredTableStructure(database,
                                               pragmaVersion >= 13,
                                               pragmaVersion >= 14,
                                               pragmaVersion >= 20,
                                               pragmaVersion >= 21,
                                               &reason);
            }
            if (reason.isEmpty() && pragmaVersion >= 22) {
                // v22循环计数是独立业务事实；缺失或越界不能在恢复后静默变成零。
                QSqlQuery cycle(database);
                if (!cycle.exec(QStringLiteral("SELECT singleton_id, completed_pomodoros, "
                                                "typeof(completed_pomodoros) FROM pomodoro_cycle_state"))
                    || !cycle.next() || cycle.value(0).toInt() != 1
                    || cycle.value(2).toString() != QLatin1String("integer")
                    || cycle.value(1).toLongLong() < 0 || cycle.value(1).toLongLong() > 2147483647
                    || cycle.next()) {
                    reason = QStringLiteral("备份中的番茄循环状态缺失或无效");
                }
            }

            if (reason.isEmpty()) {
                validateBusinessValues(database, pragmaVersion, control, &reason);
            }

            // 备份是数据，不是可信的数据库程序。
            //
            // 恢复把外部文件整个复制成主库，此前只校验完整性、必要表、版本和条数——
            // 一个 Trigger 就能随备份永久活进用户库里，之后每次增删改任务都静默执行，
            // 而恢复前快照根本发现不了这种延迟触发的破坏。View 与虚拟表同理
            // （虚拟表还能把模块名当作加载路径）。
            //
            // 本应用自己从不创建 View / 虚拟表；触发器只有 v18 起维护同步版本的那一组（见 SyncSchema）。
            // sqlite_master 里表和索引以外的对象，只放行名字属于同步触发器的，其余一律拒绝恢复。
            // 同步触发器不比内容：以后改了同步表或触发器写法，更早版本的备份里的触发器文本必然不同，
            // 逐字比较会让旧备份全部恢复不了。内容也不必信它——打开恢复后的库时，内容与本版本不一致的
            // 同步触发器会在任何迁移写入之前被拆掉，最后按规范重建（DatabaseManager::dropForeignSyncTriggers），
            // 伪造的同名触发器没有机会执行。
            if (reason.isEmpty()) {
                QSqlQuery objects(database);
                if (!objects.exec(QStringLiteral(
                        "SELECT type, name FROM sqlite_master "
                        "WHERE type NOT IN ('table', 'index')"))) {
                    reason = QStringLiteral("读取备份结构失败");
                } else {
                    while (reason.isEmpty() && objects.next()) {
                        const QString type = objects.value(0).toString();
                        const QString name = objects.value(1).toString();
                        const bool isOwnSyncTrigger = type == QLatin1String("trigger")
                            && SyncSchema::isSyncTriggerName(name);
                        if (!isOwnSyncTrigger) {
                            reason = QStringLiteral("备份包含本应用不会创建的数据库对象（%1 %2），"
                                                    "出于安全考虑拒绝恢复")
                                         .arg(type, name);
                        }
                    }
                }
            }
            if (reason.isEmpty()) {
                for (auto it = metadata.constBegin(); it != metadata.constEnd(); ++it) {
                    result.insert(it.key(), it.value());
                }
                result.insert(QStringLiteral("schemaVersion"), pragmaVersion);

                QSqlQuery count(database);
                if (!count.exec(QStringLiteral("SELECT COUNT(*) FROM tasks")) || !count.next()) {
                    reason = QStringLiteral("读取备份任务数量失败");
                } else {
                    result.insert(QStringLiteral("taskCount"), count.value(0).toInt());
                }
                if (reason.isEmpty()
                    && (!count.exec(QStringLiteral("SELECT COUNT(*) FROM focus_sessions"))
                        || !count.next())) {
                    reason = QStringLiteral("读取备份专注记录数量失败");
                } else if (reason.isEmpty()) {
                    result.insert(QStringLiteral("sessionCount"), count.value(0).toInt());
                }
            }
            database.close();
        }
    }
    QSqlDatabase::removeDatabase(connectionName);

    if (!control->checkpoint("inspect-complete")) reason = control->message();
    result.insert(QStringLiteral("valid"), reason.isEmpty());
    result.insert(QStringLiteral("reason"), reason);
    return result;
}

EmbeddedSettingsResult readEmbeddedSettings(const QString& sourcePath, const BackupOperation& operation)
{
    const auto control = operation ? operation : std::make_shared<BackupOperationControl>();
    EmbeddedSettingsResult result;
    if (!control->checkpoint("settings-start")) {
        result.error = control->message();
        return result;
    }
    const QString connectionName = uniqueConnectionName(QStringLiteral("BackupSettingsRead_"));
    {
        QSqlDatabase database = QSqlDatabase::addDatabase(new BackupSqliteDriver(control), connectionName);
        database.setDatabaseName(sourcePath);
        database.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
        if (!database.open()) {
            result.error = QStringLiteral("无法读取备份偏好：") + database.lastError().text();
        } else if (!tableExists(database, QStringLiteral("backup_settings"))) {
            result.error = QStringLiteral("备份缺少偏好数据");
        } else {
            QSqlQuery rows(database);
            if (!rows.exec(QStringLiteral("SELECT key, value FROM backup_settings"))) {
                result.error = QStringLiteral("读取备份偏好失败：") + rows.lastError().text();
            } else {
                bool ok = true;
                int skipped = 0;
                while (rows.next()) {
                    const QString key = rows.value(0).toString();

                    // 只恢复本应用拥有的键。备份文件是外部输入——可能来自别的版本、
                    // 被手工改过、或者干脆是伪造的。写回陌生键既没有意义，
                    // 又会在自己的偏好文件里留下永远不会被清理的垃圾。
                    if (!AppSettings::isOwnedSettingKey(key)) {
                        ++skipped;
                        continue;
                    }

                    QByteArray blob = rows.value(1).toByteArray();
                    // 单个值的字节数上限。QDataStream 解 QVariant 时会先读出容器长度
                    // 再按该长度预留空间，一个被篡改的长度字段能让这里试图分配几个 GB。
                    // 正常设置值都是标量或短字符串，这个上限留了几个数量级的余量。
                    if (blob.size() > kMaxSettingValueBytes) {
                        result.error = QStringLiteral("备份偏好数据异常：%1 的值过大").arg(key);
                        ok = false;
                        break;
                    }

                    if (!hasSafeSettingEncoding(blob)) {
                        result.error = QStringLiteral("备份偏好类型或长度不合法：") + key;
                        ok = false;
                        break;
                    }
                    QDataStream stream(&blob, QIODevice::ReadOnly);
                    stream.setVersion(kSettingsStreamVersion);
                    QVariant value;
                    stream >> value;
                    if (stream.status() != QDataStream::Ok || !stream.atEnd()) {
                        result.error = QStringLiteral("备份偏好数据已损坏：") + key;
                        ok = false;
                        break;
                    }
                    result.values.insert(key, value);

                    if (result.values.size() > kMaxSettingEntries) {
                        result.error = QStringLiteral("备份偏好条目过多");
                        ok = false;
                        break;
                    }
                }
                if (ok && skipped > 0) {
                    // 不静默：丢了什么必须留下痕迹，否则用户只会发现"恢复后某项没回来"。
                    qInfo() << "Restore skipped" << skipped
                            << "unrecognised setting key(s) from backup";
                }
                if (rows.lastError().isValid()) {
                    ok = false;
                    result.error = QStringLiteral("读取备份偏好失败：") + rows.lastError().text();
                }
                result.success = ok;
            }
            database.close();
        }
    }
    QSqlDatabase::removeDatabase(connectionName);
    if (control->stopped()) {
        result.success = false;
        result.error = control->message();
    }
    return result;
}

} // namespace BackupOperations
