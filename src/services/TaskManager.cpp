#include "TaskManager.h"

#include "../models/Task.h"
#include "DatabaseManager.h"

#include <QDebug>
#include <QDateTime>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QVariant>

namespace {
bool isValidTaskId(int taskId)
{
    return taskId > 0;
}

QDate normalizeDate(const QVariant& value)
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
        const QDate isoDate = QDate::fromString(text, Qt::ISODate);
        if (isoDate.isValid()) {
            return isoDate;
        }

        const QDateTime isoDateTime = QDateTime::fromString(text, Qt::ISODate);
        if (isoDateTime.isValid()) {
            return isoDateTime.date();
        }
    }

    return QDate();
}
}

TaskManager::TaskManager(QObject* parent)
    : QObject(parent)
{
}

TaskManager* TaskManager::instance()
{
    static TaskManager manager;
    return &manager;
}

bool TaskManager::addTask(const QString& title, const QVariant& dateValue, const QString& category)
{
    const QString normalizedTitle = title.trimmed();
    if (normalizedTitle.isEmpty()) {
        qWarning() << "Failed to add task: title is empty after trimming";
        return false;
    }

    const QDate date = normalizeDate(dateValue);
    if (!date.isValid()) {
        qWarning() << "Failed to add task: invalid date";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to add task: database is not open";
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "INSERT INTO tasks (title, category, date, completed) VALUES (:title, :category, :date, 0)"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":category"), category.trimmed());
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));

    if (!query.exec()) {
        qWarning() << "Failed to add task:" << query.lastError().text();
        return false;
    }

    emit tasksChanged();
    return true;
}

bool TaskManager::completeTask(int taskId)
{
    return setTaskCompleted(taskId, true);
}

bool TaskManager::setTaskCompleted(int taskId, bool completed)
{
    if (!isValidTaskId(taskId)) {
        qWarning() << "Failed to update task completion: invalid task id" << taskId;
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to update task completion: database is not open";
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("UPDATE tasks SET completed = :completed WHERE id = :id"));
    query.bindValue(QStringLiteral(":completed"), completed ? 1 : 0);
    query.bindValue(QStringLiteral(":id"), taskId);

    if (!query.exec()) {
        qWarning() << "Failed to update task completion:" << query.lastError().text();
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to update task completion: task not found" << taskId;
        return false;
    }

    emit tasksChanged();
    return true;
}

bool TaskManager::deleteTask(int taskId)
{
    if (!isValidTaskId(taskId)) {
        qWarning() << "Failed to delete task: invalid task id" << taskId;
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to delete task: database is not open";
        return false;
    }

    if (!db.transaction()) {
        qWarning() << "Failed to start delete task transaction:" << db.lastError().text();
        return false;
    }

    QSqlQuery detachSessions(db);
    detachSessions.prepare(QStringLiteral("UPDATE focus_sessions SET task_id = NULL WHERE task_id = :id"));
    detachSessions.bindValue(QStringLiteral(":id"), taskId);
    if (!detachSessions.exec()) {
        qWarning() << "Failed to detach focus sessions before deleting task:" << detachSessions.lastError().text();
        db.rollback();
        return false;
    }

    QSqlQuery deleteQuery(db);
    deleteQuery.prepare(QStringLiteral("DELETE FROM tasks WHERE id = :id"));
    deleteQuery.bindValue(QStringLiteral(":id"), taskId);
    if (!deleteQuery.exec()) {
        qWarning() << "Failed to delete task:" << deleteQuery.lastError().text();
        db.rollback();
        return false;
    }

    if (deleteQuery.numRowsAffected() == 0) {
        qWarning() << "Failed to delete task: task not found" << taskId;
        db.rollback();
        return false;
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit delete task transaction:" << db.lastError().text();
        db.rollback();
        return false;
    }

    emit tasksChanged();
    return true;
}

QVariantList TaskManager::getTodayTasks() const
{
    return getTasksByDate(QDate::currentDate());
}

QVariantList TaskManager::getTasksByDate(const QDate& date) const
{
    QVariantList tasks;
    if (!date.isValid()) {
        qWarning() << "Failed to get tasks: invalid date";
        return tasks;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get tasks: database is not open";
        return tasks;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT id, title, category, date, completed, created_at "
        "FROM tasks WHERE date = :date ORDER BY completed ASC, created_at ASC, id ASC"));
    query.bindValue(QStringLiteral(":date"), date.toString(Qt::ISODate));

    if (!query.exec()) {
        qWarning() << "Failed to get tasks:" << query.lastError().text();
        return tasks;
    }

    while (query.next()) {
        tasks.append(Task::fromQuery(query).toVariantMap());
    }

    return tasks;
}

QVariantList TaskManager::getWeekTasks(const QVariant& startDateValue) const
{
    QVariantList tasks;
    const QDate startDate = normalizeDate(startDateValue);
    if (!startDate.isValid()) {
        qWarning() << "Failed to get week tasks: invalid start date";
        return tasks;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get week tasks: database is not open";
        return tasks;
    }

    const QDate endDate = startDate.addDays(6);
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT id, title, category, date, completed, created_at "
        "FROM tasks "
        "WHERE date >= :startDate AND date <= :endDate "
        "ORDER BY date ASC, completed ASC, created_at ASC, id ASC"));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));

    if (!query.exec()) {
        qWarning() << "Failed to get week tasks:" << query.lastError().text();
        return tasks;
    }

    while (query.next()) {
        tasks.append(Task::fromQuery(query).toVariantMap());
    }

    return tasks;
}

QVariantList TaskManager::getMonthTasks(int year, int month) const
{
    QVariantList tasks;
    const QDate startDate(year, month, 1);
    if (!startDate.isValid()) {
        qWarning() << "Failed to get month tasks: invalid year/month" << year << month;
        return tasks;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get month tasks: database is not open";
        return tasks;
    }

    const QDate endDate = startDate.addMonths(1).addDays(-1);
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT id, title, category, date, completed, created_at "
        "FROM tasks "
        "WHERE date >= :startDate AND date <= :endDate "
        "ORDER BY date ASC, completed ASC, created_at ASC, id ASC"));
    query.bindValue(QStringLiteral(":startDate"), startDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":endDate"), endDate.toString(Qt::ISODate));

    if (!query.exec()) {
        qWarning() << "Failed to get month tasks:" << query.lastError().text();
        return tasks;
    }

    while (query.next()) {
        tasks.append(Task::fromQuery(query).toVariantMap());
    }

    return tasks;
}
