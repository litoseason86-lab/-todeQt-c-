#include "ExportService.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "FocusSessionRules.h"
#include "LogicalDay.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QCoreApplication>
#include <QDateTime>
#include <QFutureWatcher>
#include <QSaveFile>
#include <QThread>
#include <QtConcurrent>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTextStream>
#include <QTimeZone>
#include <QUuid>

ExportService::ExportService(QObject* parent)
    : QObject(parent)
{
}

ExportService* ExportService::instance()
{
    static ExportService service;
    return &service;
}

QDate ExportService::normalizeDate(const QVariant& value) const
{
    if (value.canConvert<QDate>()) {
        const QDate date = value.toDate();
        if (date.isValid()) {
            return date;
        }
    }

    if (value.canConvert<QDateTime>()) {
        const QDateTime dateTime = value.toDateTime();
        if (dateTime.isValid()) {
            return dateTime.date();
        }
    }

    const QString text = value.toString().trimmed();
    if (!text.isEmpty()) {
        const QDate date = QDate::fromString(text, Qt::ISODate);
        if (date.isValid()) {
            return date;
        }

        const QDateTime dateTime = QDateTime::fromString(text, Qt::ISODate);
        if (dateTime.isValid()) {
            return dateTime.date();
        }
    }

    return QDate();
}

namespace {
// 进度信号的批量粒度。逐行发在 2 万行时就是 2 万次跨线程排队投递。
constexpr int kProgressBatchRows = 200;
}

QString ExportService::escapeCsvField(const QString& field) const
{
    // 按 CSV 的通用规则处理：只在必要时加引号，并把内部引号写成两个引号。
    if (!field.contains(QLatin1Char(',')) && !field.contains(QLatin1Char('"'))
        && !field.contains(QLatin1Char('\n')) && !field.contains(QLatin1Char('\r'))) {
        return field;
    }

    QString escaped = field;
    escaped.replace(QLatin1Char('"'), QStringLiteral("\"\""));
    return QStringLiteral("\"%1\"").arg(escaped);
}

QString ExportService::formatDateTime(const QVariant& value) const
{
    const QString text = value.toString();
    if (text.contains(QLatin1Char('T'))) {
        const QDateTime isoDateTime = QDateTime::fromString(text, Qt::ISODate);
        if (isoDateTime.isValid()) {
            return isoDateTime.toString(QStringLiteral("yyyy-MM-dd HH:mm:ss"));
        }
    }

    QDateTime sqliteDateTime = QDateTime::fromString(text, QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    if (sqliteDateTime.isValid()) {
        // 无 T 的格式来自 SQLite CURRENT_TIMESTAMP，语义固定为 UTC。
        sqliteDateTime.setTimeZone(QTimeZone::UTC);
        return sqliteDateTime.toLocalTime().toString(QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    }

    return text;
}

QString ExportService::categoryExpression() const
{
    // category_id 出现前创建的记录，导出时仍要显示旧文本科目。
    return QStringLiteral("COALESCE(NULLIF(c.name, ''), NULLIF(t.category, ''), '未分类')");
}

QString ExportService::sessionCategoryExpression() const
{
    // 会话快照是历史事实；当前任务列只为迁移前的旧数据提供兼容回退。
    return QStringLiteral(
        "COALESCE(NULLIF(snapshot_category.name, ''), NULLIF(f.category_name_snapshot, ''), "
        "NULLIF(c.name, ''), NULLIF(t.category, ''), '未分类')");
}

int ExportService::countRows(const QString& fromAndWhereSql,
                             const QDate& startDate,
                             const QDate& endDate) const
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("SELECT COUNT(*) %1").arg(fromAndWhereSql));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to count export rows:" << query.lastError().text();
        return 0;
    }

    return query.value(0).toInt();
}

QString ExportService::generateFileName(const QString& type,
                                        const QVariant& startDateValue,
                                        const QVariant& endDateValue) const
{
    const QDate startDate = normalizeDate(startDateValue);
    const QDate endDate = normalizeDate(endDateValue);
    const QString safeType = type.trimmed().isEmpty() ? QStringLiteral("export") : type.trimmed();
    return QStringLiteral("%1_%2_%3.csv")
        .arg(safeType,
             startDate.isValid() ? startDate.toString(QStringLiteral("yyyyMMdd")) : QStringLiteral("invalid"),
             endDate.isValid() ? endDate.toString(QStringLiteral("yyyyMMdd")) : QStringLiteral("invalid"));
}

bool ExportService::exportTasks(const QVariant& startDateValue,
                                const QVariant& endDateValue,
                                const QString& filePath)
{
    const QDate startDate = normalizeDate(startDateValue);
    const QDate endDate = normalizeDate(endDateValue);
    return exportTasksToFile(startDate, endDate, filePath, true);
}

bool ExportService::exportTasksToFile(const QDate& startDate,
                                      const QDate& endDate,
                                      const QString& filePath,
                                      bool emitSuccess)
{
    if (!startDate.isValid() || !endDate.isValid() || startDate > endDate) {
        emit exportCompleted(false, QStringLiteral("日期范围无效"));
        return false;
    }

    QString ownedConnection;
    QSqlDatabase db = acquireDatabase(&ownedConnection);
    // 连接在本函数返回时释放；用 RAII 包一层避免每条错误分支都记得释放。
    struct ConnectionGuard {
        QString name;
        ~ConnectionGuard() { ExportService::releaseDatabase(name); }
    } guard{ownedConnection};
    if (!db.isOpen()) {
        emit exportCompleted(false, QStringLiteral("数据库未打开"));
        return false;
    }

    // QSaveFile 写入同目录临时文件，只有 commit 成功才原子替换目标；任何中途失败都保留旧文件。
    QSaveFile file(filePath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        emit exportCompleted(false, QStringLiteral("无法创建文件: %1").arg(file.errorString()));
        return false;
    }

    QTextStream out(&file);
    out.setEncoding(QStringConverter::Utf8);
    out << QStringLiteral("ID,标题,科目,日期,完成状态,创建时间\n");

    const QString fromAndWhere = QStringLiteral(
        "FROM tasks t "
        "LEFT JOIN categories c ON t.category_id = c.id "
        "WHERE t.date >= :startDate AND t.date <= :endDate");
    // 先统计总数，让 UI 可以显示确定进度，而不是只能显示加载状态。
    const int total = countRows(fromAndWhere, startDate, endDate);

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT t.id, t.title, %1 AS category_name, t.date, t.completed, t.created_at "
        "%2 "
        "ORDER BY t.date ASC, t.created_at ASC, t.id ASC")
                      .arg(categoryExpression(), fromAndWhere));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));

    if (!query.exec()) {
        file.cancelWriting();
        emit exportCompleted(false, QStringLiteral("数据库查询失败: %1").arg(query.lastError().text()));
        return false;
    }

    int current = 0;
    while (query.next()) {
        out << query.value(0).toInt() << ','
            << escapeCsvField(query.value(1).toString()) << ','
            << escapeCsvField(query.value(2).toString()) << ','
            << query.value(3).toString() << ','
            << (query.value(4).toBool() ? QStringLiteral("已完成") : QStringLiteral("未完成")) << ','
            << formatDateTime(query.value(5)) << '\n';
        ++current;
        // 逐行发信号在 2 万行时就是 2 万次跨线程排队投递，比写文件本身还贵。
        // 每 200 行报一次，末尾再补一次准确值。
        if (current % kProgressBatchRows == 0) {
            emit exportProgress(current, total);
        }
    }

    emit exportProgress(current, total);
    return finishCsvFile(file,
                         out,
                         QStringLiteral("成功导出 %1 条任务记录").arg(current),
                         emitSuccess);
}

bool ExportService::exportFocusSessions(const QVariant& startDateValue,
                                        const QVariant& endDateValue,
                                        const QString& filePath)
{
    const QDate startDate = normalizeDate(startDateValue);
    const QDate endDate = normalizeDate(endDateValue);
    return exportFocusSessionsToFile(startDate, endDate, filePath, true);
}

bool ExportService::exportFocusSessionsToFile(const QDate& startDate,
                                              const QDate& endDate,
                                              const QString& filePath,
                                              bool emitSuccess)
{
    if (!startDate.isValid() || !endDate.isValid() || startDate > endDate) {
        emit exportCompleted(false, QStringLiteral("日期范围无效"));
        return false;
    }

    QString ownedConnection;
    QSqlDatabase db = acquireDatabase(&ownedConnection);
    // 连接在本函数返回时释放；用 RAII 包一层避免每条错误分支都记得释放。
    struct ConnectionGuard {
        QString name;
        ~ConnectionGuard() { ExportService::releaseDatabase(name); }
    } guard{ownedConnection};
    if (!db.isOpen()) {
        emit exportCompleted(false, QStringLiteral("数据库未打开"));
        return false;
    }

    QSaveFile file(filePath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        emit exportCompleted(false, QStringLiteral("无法创建文件: %1").arg(file.errorString()));
        return false;
    }

    QTextStream out(&file);
    out.setEncoding(QStringConverter::Utf8);
    out << QStringLiteral("ID,任务ID,任务标题,科目,开始时间,结束时间,时长(分钟)\n");

    // countRows 与主查询复用同一 SQL 片段。shift 由 0-6 的归一化整数生成，
    // 以字面量嵌入可避免两条查询各自维护额外绑定，且不存在外部输入注入面。
    const QString fromAndWhere = QStringLiteral(
        "FROM focus_sessions f "
        "LEFT JOIN tasks t ON f.task_id = t.id "
        "LEFT JOIN categories snapshot_category ON f.category_id_snapshot = snapshot_category.id "
        "LEFT JOIN categories c ON t.category_id = c.id "
        "WHERE date(f.start_time, '%1') >= :startDate "
        "AND date(f.start_time, '%1') <= :endDate "
        "AND f.end_time IS NOT NULL "
        "AND f.duration IS NOT NULL "
        "AND f.duration >= %2")
                                     .arg(LogicalDay::sqlShift(
                                         AppSettings::instance()->dayStartHour()))
                                     .arg(FocusSessionRules::kMinimumValidDurationSeconds);
    // 先统计总数，让 UI 可以显示确定进度，而不是只能显示加载状态。
    const int total = countRows(fromAndWhere, startDate, endDate);

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT f.id, f.task_id, COALESCE(t.title, '未关联任务') AS task_title, "
        "%1 AS category_name, f.start_time, f.end_time, COALESCE(f.duration, 0) "
        "%2 "
        "ORDER BY f.start_time ASC, f.id ASC").arg(sessionCategoryExpression(), fromAndWhere));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));

    if (!query.exec()) {
        file.cancelWriting();
        emit exportCompleted(false, QStringLiteral("数据库查询失败: %1").arg(query.lastError().text()));
        return false;
    }

    int current = 0;
    while (query.next()) {
        const int durationMinutes = query.value(6).toInt() / 60;
        out << query.value(0).toInt() << ','
            << (query.value(1).isNull() ? QStringLiteral("-1") : query.value(1).toString()) << ','
            << escapeCsvField(query.value(2).toString()) << ','
            << escapeCsvField(query.value(3).toString()) << ','
            << formatDateTime(query.value(4)) << ','
            << formatDateTime(query.value(5)) << ','
            << durationMinutes << '\n';
        ++current;
        // 逐行发信号在 2 万行时就是 2 万次跨线程排队投递，比写文件本身还贵。
        // 每 200 行报一次，末尾再补一次准确值。
        if (current % kProgressBatchRows == 0) {
            emit exportProgress(current, total);
        }
    }

    emit exportProgress(current, total);
    return finishCsvFile(file,
                         out,
                         QStringLiteral("成功导出 %1 条专注记录").arg(current),
                         emitSuccess);
}

bool ExportService::exportAll(const QVariant& startDateValue,
                              const QVariant& endDateValue,
                              const QString& dirPath)
{
    const QDate startDate = normalizeDate(startDateValue);
    const QDate endDate = normalizeDate(endDateValue);
    if (!startDate.isValid() || !endDate.isValid() || startDate > endDate) {
        emit exportCompleted(false, QStringLiteral("日期范围无效"));
        return false;
    }

    QDir dir(dirPath);
    if (!dir.exists() && !dir.mkpath(QStringLiteral("."))) {
        emit exportCompleted(false, QStringLiteral("无法创建导出目录"));
        return false;
    }

    const QString tasksPath = dir.filePath(generateFileName(QStringLiteral("tasks"), startDate, endDate));
    const QString sessionsPath = dir.filePath(generateFileName(QStringLiteral("focus_sessions"), startDate, endDate));

    const QFileInfo tasksInfo(tasksPath);
    const QFileInfo sessionsInfo(sessionsPath);
    if ((tasksInfo.exists() && !tasksInfo.isFile())
        || (sessionsInfo.exists() && !sessionsInfo.isFile())) {
        emit exportCompleted(false, QStringLiteral("导出目标不是普通文件"));
        return false;
    }

    const QString stagingSuffix = QStringLiteral(".staging-%1")
                                      .arg(QUuid::createUuid().toString(QUuid::WithoutBraces));
    const QString stagedTasksPath = tasksPath + stagingSuffix;
    const QString stagedSessionsPath = sessionsPath + stagingSuffix;

    // 两份数据先全部写入暂存文件；任意查询或写入失败都不会碰现有导出结果。
    if (!exportTasksToFile(startDate, endDate, stagedTasksPath, false)) {
        return false;
    }
    if (!exportFocusSessionsToFile(startDate, endDate, stagedSessionsPath, false)) {
        QFile::remove(stagedTasksPath);
        return false;
    }

    if (!commitExportPair(stagedTasksPath, tasksPath, stagedSessionsPath, sessionsPath)) {
        QFile::remove(stagedTasksPath);
        QFile::remove(stagedSessionsPath);
        return false;
    }

    emit exportCompleted(true, QStringLiteral("导出完成: %1").arg(dir.absolutePath()));
    return true;
}

bool ExportService::finishCsvFile(QSaveFile& file,
                                  QTextStream& stream,
                                  const QString& successMessage,
                                  bool emitSuccess)
{
    stream.flush();
    if (stream.status() != QTextStream::Ok) {
        file.cancelWriting();
        emit exportCompleted(false, QStringLiteral("写入 CSV 失败"));
        return false;
    }

    if (!file.commit()) {
        emit exportCompleted(false, QStringLiteral("提交文件失败: %1").arg(file.errorString()));
        return false;
    }

    if (emitSuccess) {
        emit exportCompleted(true, successMessage);
    }
    return true;
}

bool ExportService::commitExportPair(const QString& stagedTasksPath,
                                     const QString& tasksPath,
                                     const QString& stagedSessionsPath,
                                     const QString& sessionsPath)
{
    const QString backupSuffix = QStringLiteral(".backup-%1")
                                     .arg(QUuid::createUuid().toString(QUuid::WithoutBraces));
    const QString tasksBackup = tasksPath + backupSuffix;
    const QString sessionsBackup = sessionsPath + backupSuffix;
    const bool hadTasks = QFileInfo::exists(tasksPath);
    const bool hadSessions = QFileInfo::exists(sessionsPath);

    auto restoreBackup = [](const QString& backupPath, const QString& destinationPath, bool existed) {
        if (!existed) {
            return true;
        }
        QFile::remove(destinationPath);
        return QFile::rename(backupPath, destinationPath);
    };

    if (hadTasks && !QFile::rename(tasksPath, tasksBackup)) {
        emit exportCompleted(false, QStringLiteral("无法备份原任务导出文件"));
        return false;
    }
    if (hadSessions && !QFile::rename(sessionsPath, sessionsBackup)) {
        restoreBackup(tasksBackup, tasksPath, hadTasks);
        emit exportCompleted(false, QStringLiteral("无法备份原专注导出文件"));
        return false;
    }

    if (!QFile::rename(stagedTasksPath, tasksPath)) {
        restoreBackup(tasksBackup, tasksPath, hadTasks);
        restoreBackup(sessionsBackup, sessionsPath, hadSessions);
        emit exportCompleted(false, QStringLiteral("无法提交任务导出文件"));
        return false;
    }

    if (!QFile::rename(stagedSessionsPath, sessionsPath)) {
        QFile::remove(tasksPath);
        const bool tasksRestored = restoreBackup(tasksBackup, tasksPath, hadTasks);
        const bool sessionsRestored = restoreBackup(sessionsBackup, sessionsPath, hadSessions);
        emit exportCompleted(false,
                             tasksRestored && sessionsRestored
                                 ? QStringLiteral("无法提交专注导出文件，原文件已恢复")
                                 : QStringLiteral("无法提交专注导出文件，且原文件恢复失败"));
        return false;
    }

    if (hadTasks) {
        QFile::remove(tasksBackup);
    }
    if (hadSessions) {
        QFile::remove(sessionsBackup);
    }
    return true;
}

QSqlDatabase ExportService::acquireDatabase(QString* ownedConnectionName) const
{
    *ownedConnectionName = QString();
    // 主线程直接复用现有连接。
    if (QThread::currentThread() == qApp->thread()) {
        return DatabaseManager::instance()->database();
    }

    // 工作线程：按线程开一条只读连接。名字带线程指针，避免并发导出撞名。
    const QString path = DatabaseManager::instance()->database().databaseName();
    if (path.isEmpty()) {
        return QSqlDatabase();
    }
    const QString name = QStringLiteral("ExportWorker_%1_%2")
                             .arg(reinterpret_cast<quintptr>(QThread::currentThread()))
                             .arg(QDateTime::currentMSecsSinceEpoch());
    QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), name);
    db.setDatabaseName(path);
    // 只读：导出不写库，也就不会和主线程的写事务抢锁。
    db.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
    if (!db.open()) {
        QSqlDatabase::removeDatabase(name);
        return QSqlDatabase();
    }
    *ownedConnectionName = name;
    return db;
}

void ExportService::releaseDatabase(const QString& ownedConnectionName)
{
    if (ownedConnectionName.isEmpty()) {
        return;
    }
    {
        QSqlDatabase db = QSqlDatabase::database(ownedConnectionName, false);
        if (db.isValid()) {
            db.close();
        }
    }
    QSqlDatabase::removeDatabase(ownedConnectionName);
}

void ExportService::setBusy(bool busy)
{
    if (m_busy == busy) {
        return;
    }
    m_busy = busy;
    emit busyChanged();
}

void ExportService::runAsync(const std::function<bool()>& work)
{
    if (m_busy) {
        emit exportCompleted(false, QStringLiteral("已有导出任务正在执行"));
        return;
    }
    setBusy(true);

    auto* watcher = new QFutureWatcher<bool>(this);
    connect(watcher, &QFutureWatcherBase::finished, this, [this, watcher]() {
        watcher->deleteLater();
        setBusy(false);
        // 成功/失败的具体消息由 work 内部 emit exportCompleted 给出，
        // 这里只负责把 busy 放回去——两处都发会让界面收到两次完成。
    });
    watcher->setFuture(QtConcurrent::run(work));
}

void ExportService::requestExportTasks(const QVariant& startDateValue,
                                       const QVariant& endDateValue,
                                       const QString& filePath)
{
    const QDate start = normalizeDate(startDateValue);
    const QDate end = normalizeDate(endDateValue);
    runAsync([this, start, end, filePath]() {
        return exportTasksToFile(start, end, filePath, true);
    });
}

void ExportService::requestExportFocusSessions(const QVariant& startDateValue,
                                               const QVariant& endDateValue,
                                               const QString& filePath)
{
    const QDate start = normalizeDate(startDateValue);
    const QDate end = normalizeDate(endDateValue);
    runAsync([this, start, end, filePath]() {
        return exportFocusSessionsToFile(start, end, filePath, true);
    });
}

void ExportService::requestExportAll(const QVariant& startDateValue,
                                     const QVariant& endDateValue,
                                     const QString& dirPath)
{
    runAsync([this, startDateValue, endDateValue, dirPath]() {
        return exportAll(startDateValue, endDateValue, dirPath);
    });
}
