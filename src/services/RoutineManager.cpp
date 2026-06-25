#include "RoutineManager.h"

#include "CategoryManager.h"
#include "DatabaseManager.h"

#include <QDebug>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QVariantMap>

namespace {
QVariant nullableCategoryId(int categoryId)
{
    // categoryId <= 0 是 QML 层传入的“未选择科目”哨兵值，数据库里必须落成 NULL，
    // 这样删除科目和左连接查询都能保持统一语义。
    return categoryId > 0 ? QVariant(categoryId) : QVariant();
}

bool routineCategoryExists(QSqlDatabase& db, int categoryId, const char* action)
{
    if (categoryId <= 0) {
        return true;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT 1 FROM categories WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), categoryId);
    if (!query.exec()) {
        qWarning() << "Failed to validate routine category:" << query.lastError().text();
        return false;
    }

    if (!query.next()) {
        qWarning().noquote() << QStringLiteral("Failed to %1 routine: category not found").arg(QString::fromLatin1(action)) << categoryId;
        return false;
    }

    return true;
}
}

RoutineManager::RoutineManager(QObject* parent)
    : QObject(parent)
{
    // getRoutines() 左连 categories；分类改名、换色或删除都会改变返回值，
    // 因此把分类变化转发成 routinesChanged，避免 QML 列表停留在旧分类状态。
    connect(CategoryManager::instance(), &CategoryManager::categoriesChanged,
            this, &RoutineManager::routinesChanged);
}

RoutineManager* RoutineManager::instance()
{
    static RoutineManager manager;
    return &manager;
}

bool RoutineManager::addRoutine(const QString& title, int categoryId)
{
    const QString normalizedTitle = title.trimmed();
    if (normalizedTitle.isEmpty()) {
        qWarning("Failed to add routine: title is empty");
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to add routine: database is not open";
        return false;
    }
    if (!routineCategoryExists(db, categoryId, "add")) {
        return false;
    }

    QSqlQuery orderQuery(db);
    if (!orderQuery.exec(QStringLiteral("SELECT COALESCE(MAX(display_order), 0) + 1 FROM routines"))
        || !orderQuery.next()) {
        qWarning() << "Failed to calculate routine display order:" << orderQuery.lastError().text();
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "INSERT INTO routines (title, category_id, display_order) "
        "VALUES (:title, :categoryId, :displayOrder)"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":categoryId"), nullableCategoryId(categoryId));
    query.bindValue(QStringLiteral(":displayOrder"), orderQuery.value(0).toInt());

    if (!query.exec()) {
        qWarning() << "Failed to add routine:" << query.lastError().text();
        return false;
    }

    emit routinesChanged();
    return true;
}

bool RoutineManager::updateRoutine(int id, const QString& title, int categoryId)
{
    if (id <= 0) {
        qWarning() << "Failed to update routine: invalid id" << id;
        return false;
    }

    const QString normalizedTitle = title.trimmed();
    if (normalizedTitle.isEmpty()) {
        qWarning() << "Failed to update routine: title is empty";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to update routine: database is not open";
        return false;
    }
    if (!routineCategoryExists(db, categoryId, "update")) {
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE routines SET title = :title, category_id = :categoryId WHERE id = :id"));
    query.bindValue(QStringLiteral(":title"), normalizedTitle);
    query.bindValue(QStringLiteral(":categoryId"), nullableCategoryId(categoryId));
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to update routine:" << query.lastError().text();
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to update routine: routine not found" << id;
        return false;
    }

    emit routinesChanged();
    return true;
}

bool RoutineManager::deleteRoutine(int id)
{
    if (id <= 0) {
        qWarning() << "Failed to delete routine: invalid id" << id;
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to delete routine: database is not open";
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("DELETE FROM routines WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to delete routine:" << query.lastError().text();
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to delete routine: routine not found" << id;
        return false;
    }

    emit routinesChanged();
    return true;
}

bool RoutineManager::setRoutineActive(int id, bool active)
{
    if (id <= 0) {
        qWarning() << "Failed to set routine active: invalid id" << id;
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to set routine active: database is not open";
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral("UPDATE routines SET active = :active WHERE id = :id"));
    query.bindValue(QStringLiteral(":active"), active ? 1 : 0);
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to set routine active:" << query.lastError().text();
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to set routine active: routine not found" << id;
        return false;
    }

    emit routinesChanged();
    return true;
}

QVariantList RoutineManager::getRoutines() const
{
    QVariantList routines;
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get routines: database is not open";
        return routines;
    }

    QSqlQuery query(db);
    if (!query.exec(QStringLiteral(
            "SELECT r.id, r.title, r.category_id, c.name, c.color, r.active, r.display_order "
            "FROM routines r "
            "LEFT JOIN categories c ON c.id = r.category_id "
            "ORDER BY r.display_order ASC, r.id ASC"))) {
        qWarning() << "Failed to get routines:" << query.lastError().text();
        return routines;
    }

    while (query.next()) {
        QVariantMap routine;
        routine.insert(QStringLiteral("id"), query.value(0).toInt());
        routine.insert(QStringLiteral("title"), query.value(1).toString());
        routine.insert(QStringLiteral("categoryId"), query.value(2).isNull() ? -1 : query.value(2).toInt());
        routine.insert(QStringLiteral("categoryName"), query.value(3));
        routine.insert(QStringLiteral("categoryColor"), query.value(4));
        routine.insert(QStringLiteral("active"), query.value(5).toBool());
        routine.insert(QStringLiteral("displayOrder"), query.value(6).toInt());
        routines.append(routine);
    }

    return routines;
}

int RoutineManager::materializeToday()
{
    return 0;
}
