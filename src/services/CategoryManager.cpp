#include "CategoryManager.h"

#include "DatabaseManager.h"

#include <QDebug>
#include <QRegularExpression>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>

namespace {
bool isValidCategoryId(int id)
{
    return id > 0;
}
}

CategoryManager::CategoryManager(QObject* parent)
    : QObject(parent)
{
}

CategoryManager* CategoryManager::instance()
{
    static CategoryManager manager;
    return &manager;
}

QVariantList CategoryManager::getAllCategories() const
{
    return queryCategories(QStringLiteral(
        "SELECT id, name, color, is_preset, display_order, created_at "
        "FROM categories ORDER BY display_order ASC, name ASC, id ASC"));
}

QVariantList CategoryManager::getPresetCategories() const
{
    return queryCategories(QStringLiteral(
        "SELECT id, name, color, is_preset, display_order, created_at "
        "FROM categories WHERE is_preset = 1 ORDER BY display_order ASC, name ASC, id ASC"));
}

QVariantList CategoryManager::getCustomCategories() const
{
    return queryCategories(QStringLiteral(
        "SELECT id, name, color, is_preset, display_order, created_at "
        "FROM categories WHERE is_preset = 0 ORDER BY display_order ASC, name ASC, id ASC"));
}

QVariantMap CategoryManager::getCategoryById(int id) const
{
    if (!isValidCategoryId(id)) {
        return QVariantMap();
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get category: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法加载科目"));
        return QVariantMap();
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT id, name, color, is_preset, display_order, created_at "
        "FROM categories WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to get category:" << query.lastError().text();
        reportFailure(QStringLiteral("科目加载失败: %1").arg(query.lastError().text()));
        return QVariantMap();
    }

    return query.next() ? categoryFromQuery(query) : QVariantMap();
}

int CategoryManager::addCategory(const QString& name, const QString& color)
{
    const QString normalizedName = name.trimmed();
    const QString normalizedColor = color.trimmed();

    if (normalizedName.isEmpty()) {
        qWarning() << "Failed to add category: name is empty";
        return -1;
    }

    if (!isValidColor(normalizedColor)) {
        qWarning() << "Failed to add category: invalid color" << normalizedColor;
        return -1;
    }

    if (categoryNameExists(normalizedName)) {
        qWarning() << "Failed to add category: name already exists" << normalizedName;
        return -1;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to add category: database is not open";
        return -1;
    }

    QSqlQuery orderQuery(db);
    if (!orderQuery.exec(QStringLiteral("SELECT COALESCE(MAX(display_order), 0) + 1 FROM categories")) || !orderQuery.next()) {
        qWarning() << "Failed to calculate category display order:" << orderQuery.lastError().text();
        return -1;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "INSERT INTO categories (name, color, is_preset, display_order) "
        "VALUES (:name, :color, 0, :displayOrder)"));
    query.bindValue(QStringLiteral(":name"), normalizedName);
    query.bindValue(QStringLiteral(":color"), normalizedColor);
    query.bindValue(QStringLiteral(":displayOrder"), orderQuery.value(0).toInt());

    if (!query.exec()) {
        qWarning() << "Failed to add category:" << query.lastError().text();
        return -1;
    }

    emit categoriesChanged();
    return query.lastInsertId().toInt();
}

bool CategoryManager::updateCategory(int id, const QString& name, const QString& color)
{
    const QVariantMap existing = getCategoryById(id);
    if (existing.isEmpty()) {
        qWarning() << "Failed to update category: category not found" << id;
        return false;
    }

    if (existing.value(QStringLiteral("isPreset")).toBool()) {
        qWarning() << "Failed to update category: preset category cannot be edited";
        return false;
    }

    const QString normalizedName = name.trimmed();
    const QString normalizedColor = color.trimmed();
    if (normalizedName.isEmpty()) {
        qWarning() << "Failed to update category: name is empty";
        return false;
    }

    if (!isValidColor(normalizedColor)) {
        qWarning() << "Failed to update category: invalid color" << normalizedColor;
        return false;
    }

    if (categoryNameExists(normalizedName, id)) {
        qWarning() << "Failed to update category: name already exists" << normalizedName;
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE categories SET name = :name, color = :color WHERE id = :id AND is_preset = 0"));
    query.bindValue(QStringLiteral(":name"), normalizedName);
    query.bindValue(QStringLiteral(":color"), normalizedColor);
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to update category:" << query.lastError().text();
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to update category: no rows changed" << id;
        return false;
    }

    emit categoriesChanged();
    return true;
}

bool CategoryManager::deleteCategory(int id)
{
    const QVariantMap existing = getCategoryById(id);
    if (existing.isEmpty()) {
        qWarning() << "Failed to delete category: category not found" << id;
        return false;
    }

    if (existing.value(QStringLiteral("isPreset")).toBool()) {
        qWarning() << "Failed to delete category: preset category cannot be deleted";
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to delete category: database is not open";
        return false;
    }

    if (!db.transaction()) {
        qWarning() << "Failed to start delete category transaction:" << db.lastError().text();
        return false;
    }

    // 删除自定义科目不能删除任务；同时清空外键和旧文本字段，让新旧任务行都变成未分类。
    QSqlQuery detachTasks(db);
    detachTasks.prepare(QStringLiteral(
        "UPDATE tasks "
        "SET category_id = NULL, category = NULL "
        "WHERE category_id = :id "
        "OR (category_id IS NULL AND trim(category) = :name)"));
    detachTasks.bindValue(QStringLiteral(":id"), id);
    detachTasks.bindValue(QStringLiteral(":name"), existing.value(QStringLiteral("name")).toString());

    if (!detachTasks.exec()) {
        qWarning() << "Failed to detach tasks before deleting category:" << detachTasks.lastError().text();
        db.rollback();
        return false;
    }

    QSqlQuery deleteQuery(db);
    deleteQuery.prepare(QStringLiteral("DELETE FROM categories WHERE id = :id AND is_preset = 0"));
    deleteQuery.bindValue(QStringLiteral(":id"), id);

    if (!deleteQuery.exec()) {
        qWarning() << "Failed to delete category:" << deleteQuery.lastError().text();
        db.rollback();
        return false;
    }

    if (deleteQuery.numRowsAffected() == 0) {
        qWarning() << "Failed to delete category: no rows changed" << id;
        db.rollback();
        return false;
    }

    if (!db.commit()) {
        qWarning() << "Failed to commit delete category transaction:" << db.lastError().text();
        db.rollback();
        return false;
    }

    emit categoriesChanged();
    return true;
}

bool CategoryManager::canDeleteCategory(int id) const
{
    if (!isValidCategoryId(id)) {
        return false;
    }

    // 任务关联不是删除阻断条件；deleteCategory() 会先解除任务关联。
    const QVariantMap existing = getCategoryById(id);
    if (existing.isEmpty() || existing.value(QStringLiteral("isPreset")).toBool()) {
        return false;
    }

    return true;
}

bool CategoryManager::categoryNameExists(const QString& name, int excludeId) const
{
    const QString normalizedName = name.trimmed();
    if (normalizedName.isEmpty()) {
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to check category name: database is not open";
        return false;
    }

    QSqlQuery query(db);
    if (excludeId > 0) {
        query.prepare(QStringLiteral("SELECT COUNT(*) FROM categories WHERE name = :name AND id != :excludeId"));
        query.bindValue(QStringLiteral(":excludeId"), excludeId);
    } else {
        query.prepare(QStringLiteral("SELECT COUNT(*) FROM categories WHERE name = :name"));
    }
    query.bindValue(QStringLiteral(":name"), normalizedName);

    if (!query.exec() || !query.next()) {
        qWarning() << "Failed to check category name:" << query.lastError().text();
        return false;
    }

    return query.value(0).toInt() > 0;
}

QVariantMap CategoryManager::categoryFromQuery(const QSqlQuery& query) const
{
    QVariantMap category;
    category.insert(QStringLiteral("id"), query.value(0).toInt());
    category.insert(QStringLiteral("name"), query.value(1).toString());
    category.insert(QStringLiteral("color"), query.value(2).toString());
    category.insert(QStringLiteral("isPreset"), query.value(3).toBool());
    category.insert(QStringLiteral("displayOrder"), query.value(4).toInt());
    category.insert(QStringLiteral("createdAt"), query.value(5));
    return category;
}

void CategoryManager::reportFailure(const QString& message) const
{
    emit const_cast<CategoryManager*>(this)->operationFailed(message);
}

QVariantList CategoryManager::queryCategories(const QString& sql) const
{
    QVariantList categories;
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to query categories: database is not open";
        reportFailure(QStringLiteral("数据库未打开，无法加载科目"));
        return categories;
    }

    QSqlQuery query(db);
    if (!query.exec(sql)) {
        qWarning() << "Failed to query categories:" << query.lastError().text();
        reportFailure(QStringLiteral("科目加载失败: %1").arg(query.lastError().text()));
        return categories;
    }

    while (query.next()) {
        categories.append(categoryFromQuery(query));
    }

    return categories;
}

bool CategoryManager::isValidColor(const QString& color) const
{
    static const QRegularExpression hexColorPattern(QStringLiteral("^#[0-9A-Fa-f]{6}$"));
    return hexColorPattern.match(color.trimmed()).hasMatch();
}
