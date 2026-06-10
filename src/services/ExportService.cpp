#include "ExportService.h"

#include "DatabaseManager.h"
#include "FocusSessionRules.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QTextStream>

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
    const QDateTime isoDateTime = QDateTime::fromString(value.toString(), Qt::ISODate);
    if (isoDateTime.isValid()) {
        return isoDateTime.toString(QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    }

    const QDateTime sqliteDateTime = QDateTime::fromString(value.toString(), QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    if (sqliteDateTime.isValid()) {
        return sqliteDateTime.toString(QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    }

    return value.toString();
}

QString ExportService::categoryExpression() const
{
    // category_id 出现前创建的记录，导出时仍要显示旧文本科目。
    return QStringLiteral("COALESCE(NULLIF(c.name, ''), NULLIF(t.category, ''), '未分类')");
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

    QFile file(filePath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate)) {
        emit exportCompleted(false, QStringLiteral("无法创建文件: %1").arg(file.errorString()));
        return false;
    }

    QTextStream out(&file);
    out.setEncoding(QStringConverter::Utf8);
    out << QStringLiteral("ID,标题,科目,日期,完成状态,创建时间\n");

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        file.close();
        emit exportCompleted(false, QStringLiteral("数据库未打开"));
        return false;
    }

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
        file.close();
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
        emit exportProgress(current, total);
    }

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

    QFile file(filePath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate)) {
        emit exportCompleted(false, QStringLiteral("无法创建文件: %1").arg(file.errorString()));
        return false;
    }

    QTextStream out(&file);
    out.setEncoding(QStringConverter::Utf8);
    out << QStringLiteral("ID,任务ID,任务标题,科目,开始时间,结束时间,时长(分钟)\n");

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        file.close();
        emit exportCompleted(false, QStringLiteral("数据库未打开"));
        return false;
    }

    const QString fromAndWhere = QStringLiteral(
        "FROM focus_sessions f "
        "LEFT JOIN tasks t ON f.task_id = t.id "
        "LEFT JOIN categories c ON t.category_id = c.id "
        "WHERE date(f.start_time) >= :startDate "
        "AND date(f.start_time) <= :endDate "
        "AND f.end_time IS NOT NULL "
        "AND f.duration IS NOT NULL "
        "AND f.duration >= %1")
                                     .arg(FocusSessionRules::kMinimumValidDurationSeconds);
    // 先统计总数，让 UI 可以显示确定进度，而不是只能显示加载状态。
    const int total = countRows(fromAndWhere, startDate, endDate);

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT f.id, f.task_id, COALESCE(t.title, '未关联任务') AS task_title, "
        "%1 AS category_name, f.start_time, f.end_time, COALESCE(f.duration, 0) "
        "%2 "
        "ORDER BY f.start_time ASC, f.id ASC").arg(categoryExpression(), fromAndWhere));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));

    if (!query.exec()) {
        file.close();
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
        emit exportProgress(current, total);
    }

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

    // 批量导出时压制单文件成功信号，只在最后发一次总完成消息。
    if (!exportTasksToFile(startDate, endDate, tasksPath, false)) {
        return false;
    }
    if (!exportFocusSessionsToFile(startDate, endDate, sessionsPath, false)) {
        return false;
    }

    emit exportCompleted(true, QStringLiteral("导出完成: %1").arg(dir.absolutePath()));
    return true;
}

bool ExportService::finishCsvFile(QFile& file,
                                  QTextStream& stream,
                                  const QString& successMessage,
                                  bool emitSuccess)
{
    stream.flush();
    if (stream.status() != QTextStream::Ok) {
        file.close();
        emit exportCompleted(false, QStringLiteral("写入 CSV 失败"));
        return false;
    }

    // close 时仍可能发现之前没暴露的写入错误，所以 flush 和 close 分开检查。
    if (!file.flush()) {
        const QString error = file.errorString();
        file.close();
        emit exportCompleted(false, QStringLiteral("写入文件失败: %1").arg(error));
        return false;
    }

    file.close();
    if (file.error() != QFileDevice::NoError) {
        emit exportCompleted(false, QStringLiteral("关闭文件失败: %1").arg(file.errorString()));
        return false;
    }

    if (emitSuccess) {
        emit exportCompleted(true, successMessage);
    }
    return true;
}
