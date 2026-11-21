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
    // 数据库整体替换会让所有科目快照失效，统一广播而不是让每个页面感知数据库层。
    connect(DatabaseManager::instance(), &DatabaseManager::databaseChanged,
            this, &CategoryManager::categoriesChanged);
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
    return categoryForAction(id, QString());
}

QVariantMap CategoryManager::categoryForAction(int id, const QString& action) const
{
    if (!isValidCategoryId(id)) {
        if (!action.isEmpty()) reportFailure(action + QStringLiteral("失败：科目编号无效"));
        return QVariantMap();
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to get category: database is not open";
        reportFailure(action.isEmpty() ? QStringLiteral("数据库未打开，无法加载科目")
            : action + QStringLiteral("失败：数据库未打开"));
        return QVariantMap();
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "SELECT id, name, color, is_preset, display_order, created_at "
        "FROM categories WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to get category:" << query.lastError().text();
        reportFailure(action.isEmpty() ? QStringLiteral("科目加载失败: %1").arg(query.lastError().text())
            : action + QStringLiteral("失败：科目读取失败：%1").arg(query.lastError().text()));
        return QVariantMap();
    }

    if (query.next()) return categoryFromQuery(query);
    if (!action.isEmpty()) reportFailure(action + QStringLiteral("失败：科目不存在"));
    return QVariantMap();
}

int CategoryManager::addCategory(const QString& name, const QString& color)
{
    const QString normalizedName = name.trimmed();
    const QString normalizedColor = color.trimmed();

    if (normalizedName.isEmpty()) {
        qWarning() << "Failed to add category: name is empty";
        reportFailure(QStringLiteral("新增科目失败：名称不能为空"));
        return -1;
    }

    if (!isValidColor(normalizedColor)) {
        qWarning() << "Failed to add category: invalid color" << normalizedColor;
        reportFailure(QStringLiteral("新增科目失败：颜色无效"));
        return -1;
    }

    if (categoryNameExists(normalizedName)) {
        qWarning() << "Failed to add category: name already exists" << normalizedName;
        reportFailure(QStringLiteral("新增科目失败：名称已存在"));
        return -1;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to add category: database is not open";
        reportFailure(QStringLiteral("新增科目失败：数据库未打开"));
        return -1;
    }

    QSqlQuery orderQuery(db);
    if (!orderQuery.exec(QStringLiteral("SELECT COALESCE(MAX(display_order), 0) + 1 FROM categories")) || !orderQuery.next()) {
        qWarning() << "Failed to calculate category display order:" << orderQuery.lastError().text();
        reportFailure(QStringLiteral("新增科目失败：排序读取失败：%1").arg(orderQuery.lastError().text()));
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
        reportFailure(QStringLiteral("新增科目失败：数据库写入失败：%1").arg(query.lastError().text()));
        return -1;
    }

    emit categoriesChanged();
    return query.lastInsertId().toInt();
}

bool CategoryManager::updateCategory(int id, const QString& name, const QString& color)
{
    const QVariantMap existing = categoryForAction(id, QStringLiteral("修改科目"));
    if (existing.isEmpty()) {
        qWarning() << "Failed to update category: category not found" << id;
        return false;
    }

    const QString normalizedName = name.trimmed();
    const QString normalizedColor = color.trimmed();
    if (normalizedName.isEmpty()) {
        qWarning() << "Failed to update category: name is empty";
        reportFailure(QStringLiteral("修改科目失败：名称不能为空"));
        return false;
    }

    if (!isValidColor(normalizedColor)) {
        qWarning() << "Failed to update category: invalid color" << normalizedColor;
        reportFailure(QStringLiteral("修改科目失败：颜色无效"));
        return false;
    }

    if (categoryNameExists(normalizedName, id)) {
        qWarning() << "Failed to update category: name already exists" << normalizedName;
        reportFailure(QStringLiteral("修改科目失败：名称已存在"));
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE categories SET name = :name, color = :color WHERE id = :id"));
    query.bindValue(QStringLiteral(":name"), normalizedName);
    query.bindValue(QStringLiteral(":color"), normalizedColor);
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to update category:" << query.lastError().text();
        reportFailure(QStringLiteral("修改科目失败：数据库写入失败：%1").arg(query.lastError().text()));
        return false;
    }

    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to update category: no rows changed" << id;
        reportFailure(QStringLiteral("修改科目失败：科目不存在或未修改"));
        return false;
    }

    emit categoriesChanged();
    return true;
}

bool CategoryManager::updateCategoryChanges(int id, const QVariantMap& changes)
{
    const QString nameKey = QStringLiteral("name");
    const QString colorKey = QStringLiteral("color");
    for (auto it = changes.cbegin(); it != changes.cend(); ++it) {
        if (it.key() != nameKey && it.key() != colorKey) {
            qWarning() << "Failed to update category: unknown field" << it.key();
            reportFailure(QStringLiteral("修改科目失败：未知字段 %1").arg(it.key()));
            return false;
        }
    }
    if (changes.contains(nameKey) && changes.value(nameKey).typeId() != QMetaType::QString) {
        qWarning() << "Failed to update category: name must be text";
        reportFailure(QStringLiteral("修改科目失败：名称必须是文本"));
        return false;
    }
    if (changes.contains(colorKey) && changes.value(colorKey).typeId() != QMetaType::QString) {
        qWarning() << "Failed to update category: color must be text";
        reportFailure(QStringLiteral("修改科目失败：颜色必须是文本"));
        return false;
    }

    const QVariantMap existing = categoryForAction(id, QStringLiteral("修改科目"));
    if (existing.isEmpty()) {
        qWarning() << "Failed to update category: category not found" << id;
        return false;
    }
    if (changes.isEmpty()) {
        return true;
    }

    const QString currentName = existing.value(QStringLiteral("name")).toString();
    const QString currentColor = existing.value(QStringLiteral("color")).toString();

    QStringList setClauses;
    QString normalizedName;
    bool updateName = false;
    if (changes.contains(nameKey)) {
        normalizedName = changes.value(nameKey).toString().trimmed();
        if (normalizedName.isEmpty()) {
            qWarning() << "Failed to update category: name is empty";
            reportFailure(QStringLiteral("修改科目失败：名称不能为空"));
            return false;
        }
        // 仅当变更实际修改了名称时才做重名校验并拼入 SQL，避免仅改色或提交原名时触碰 name 列。
        if (normalizedName != currentName) {
            if (categoryNameExists(normalizedName, id)) {
                qWarning() << "Failed to update category: name already exists" << normalizedName;
                reportFailure(QStringLiteral("修改科目失败：名称已存在"));
                return false;
            }
            updateName = true;
            setClauses.append(QStringLiteral("name = :name"));
        }
    }

    QString normalizedColor;
    bool updateColor = false;
    if (changes.contains(colorKey)) {
        normalizedColor = changes.value(colorKey).toString().trimmed();
        if (!isValidColor(normalizedColor)) {
            qWarning() << "Failed to update category: invalid color" << normalizedColor;
            reportFailure(QStringLiteral("修改科目失败：颜色无效"));
            return false;
        }
        if (normalizedColor != currentColor) {
            updateColor = true;
            setClauses.append(QStringLiteral("color = :color"));
        }
    }

    // 传入字段与库内现值无实际差异：不写库、不触发列级同步触发器、不发无意义刷新信号。
    if (setClauses.isEmpty()) {
        return true;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    QSqlQuery query(db);
    query.prepare(QStringLiteral("UPDATE categories SET %1 WHERE id = :id").arg(setClauses.join(QStringLiteral(", "))));
    if (updateName) {
        query.bindValue(QStringLiteral(":name"), normalizedName);
    }
    if (updateColor) {
        query.bindValue(QStringLiteral(":color"), normalizedColor);
    }
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        qWarning() << "Failed to update category:" << query.lastError().text();
        reportFailure(QStringLiteral("修改科目失败：数据库写入失败：%1").arg(query.lastError().text()));
        return false;
    }
    if (query.numRowsAffected() == 0) {
        qWarning() << "Failed to update category: no rows changed" << id;
        reportFailure(QStringLiteral("修改科目失败：科目不存在或未修改"));
        return false;
    }

    emit categoriesChanged();
    return true;
}

bool CategoryManager::deleteCategory(int id)
{
    const QVariantMap existing = categoryForAction(id, QStringLiteral("删除科目"));
    if (existing.isEmpty()) {
        qWarning() << "Failed to delete category: category not found" << id;
        return false;
    }

    if (existing.value(QStringLiteral("isPreset")).toBool()) {
        qWarning() << "Failed to delete category: preset category cannot be deleted";
        reportFailure(QStringLiteral("删除科目失败：预设科目不能删除"));
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Failed to delete category: database is not open";
        reportFailure(QStringLiteral("删除科目失败：数据库未打开"));
        return false;
    }

    if (!db.transaction()) {
        qWarning() << "Failed to start delete category transaction:" << db.lastError().text();
        reportFailure(QStringLiteral("删除科目失败：无法开始数据库事务：%1").arg(db.lastError().text()));
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
        const QString errorText = detachTasks.lastError().text();
        qWarning() << "Failed to detach tasks before deleting category:" << errorText;
        detachTasks.finish();
        db.rollback();
        reportFailure(QStringLiteral("删除科目失败：解除任务关联失败：%1").arg(errorText));
        return false;
    }
    detachTasks.finish();

    QSqlQuery deleteQuery(db);
    deleteQuery.prepare(QStringLiteral("DELETE FROM categories WHERE id = :id AND is_preset = 0"));
    deleteQuery.bindValue(QStringLiteral(":id"), id);

    if (!deleteQuery.exec()) {
        const QString errorText = deleteQuery.lastError().text();
        qWarning() << "Failed to delete category:" << errorText;
        deleteQuery.finish();
        db.rollback();
        reportFailure(QStringLiteral("删除科目失败：数据库写入失败：%1").arg(errorText));
        return false;
    }

    if (deleteQuery.numRowsAffected() == 0) {
        qWarning() << "Failed to delete category: no rows changed" << id;
        deleteQuery.finish();
        db.rollback();
        reportFailure(QStringLiteral("删除科目失败：科目不存在或未修改"));
        return false;
    }
    deleteQuery.finish();

    if (!db.commit()) {
        qWarning() << "Failed to commit delete category transaction:" << db.lastError().text();
        reportFailure(QStringLiteral("删除科目失败：提交数据库事务失败：%1").arg(db.lastError().text()));
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
    // 读取前置检查与写入共用一次带动作的失败，避免桥接及弹窗收到两条相同失败。
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

QVariantMap CategoryManager::readAllCategories() const
{
    const ServiceReadResult<QVariantList> result = readCategories();
    if (result.ok()) {
        return {{QStringLiteral("ok"), true}, {QStringLiteral("categories"), result.value}};
    }
    const QString error = result.error == ServiceReadError::LimitExceeded
        ? QStringLiteral("科目太多，没能全部读出")
        : QStringLiteral("科目加载失败，请稍后重试");
    return {{QStringLiteral("ok"), false}, {QStringLiteral("categories"), QVariantList()},
            {QStringLiteral("error"), error}};
}

ServiceReadResult<QVariantList> CategoryManager::readCategories(int limit) const
{
    if (limit < 1 || limit > 10000) return {{}, ServiceReadError::InvalidArgument};
    const auto db = DatabaseManager::instance()->database();
    if (!db.isOpen()) return {{}, ServiceReadError::Database};
    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT id, name, color, is_preset, display_order, created_at "
                                 "FROM categories ORDER BY display_order, name, id LIMIT :limit"));
    query.bindValue(QStringLiteral(":limit"), limit + 1);
    if (!query.exec()) return {{}, ServiceReadError::Database};
    QVariantList rows;
    while (query.next()) {
        if (rows.size() == limit) return {{}, ServiceReadError::LimitExceeded};
        rows.append(categoryFromQuery(query));
    }
    if (query.lastError().isValid()) return {{}, ServiceReadError::Database};
    return {rows};
}

ServiceReadResult<QVariantMap> CategoryManager::readCategory(int id) const
{
    if (id <= 0) return {{}, ServiceReadError::InvalidArgument};
    const auto db = DatabaseManager::instance()->database();
    if (!db.isOpen()) return {{}, ServiceReadError::Database};
    QSqlQuery query(db);
    query.prepare(QStringLiteral("SELECT id, name, color, is_preset, display_order, created_at FROM categories WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), id);
    if (!query.exec()) return {{}, ServiceReadError::Database};
    if (!query.next()) return {{}, query.lastError().isValid() ? ServiceReadError::Database : ServiceReadError::NotFound};
    return {categoryFromQuery(query)};
}
