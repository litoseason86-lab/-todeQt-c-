#include "CountdownService.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "LogicalDay.h"
#include "LogicalDayService.h"

#include <QDateTime>
#include <QDebug>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>

#include <utility>

namespace {
constexpr int kMaxGoalNameLength = 50;

QDateTime parseStoredDateTime(const QString& value)
{
    QDateTime dateTime = QDateTime::fromString(value, Qt::ISODate);
    if (!dateTime.isValid()) {
        // SQLite 的 CURRENT_TIMESTAMP 默认是空格分隔格式；这里兼容旧数据或人工写入数据。
        dateTime = QDateTime::fromString(value, QStringLiteral("yyyy-MM-dd HH:mm:ss"));
    }
    return dateTime;
}
}

CountdownService::CountdownService(QObject* parent)
    : QObject(parent)
    , m_model(new CountdownModel(this))
{
    // 必须先定基准日再加载，否则初次构造的横幅 map 会短暂使用物理日。
    syncReferenceDate();
    connect(LogicalDayService::instance(), &LogicalDayService::changed,
            this, &CountdownService::syncReferenceDate);

    const QSqlDatabase db = DatabaseManager::instance()->database();
    if (db.isOpen() && initializeDatabase()) {
        loadGoals();
    }
}

CountdownService* CountdownService::instance()
{
    static CountdownService service;
    return &service;
}

CountdownModel* CountdownService::model() const
{
    return m_model;
}

QVariant CountdownService::primaryGoal() const
{
    const QList<CountdownGoal>& goals = m_model->goals();
    if (goals.isEmpty()) {
        return QVariant();
    }

    return goalToVariantMap(goals.first());
}

bool CountdownService::addGoal(const QString& name, const QDate& targetDate)
{
    QString normalizedName;
    if (!validateGoalInput(name, targetDate, &normalizedName)) {
        return false;
    }

    if (!ensureDatabaseReady()) {
        return false;
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    QSqlQuery orderQuery(db);
    orderQuery.prepare(QStringLiteral("SELECT COALESCE(MAX(display_order), -1) + 1 FROM countdown_goals"));
    if (!orderQuery.exec() || !orderQuery.next()) {
        emit errorOccurred(QStringLiteral("获取目标排序失败: ") + orderQuery.lastError().text());
        return false;
    }
    const int displayOrder = orderQuery.value(0).toInt();

    const QDateTime now = QDateTime::currentDateTime();
    QSqlQuery insertQuery(db);
    insertQuery.prepare(QStringLiteral(
        "INSERT INTO countdown_goals (name, target_date, display_order, created_at, updated_at) "
        "VALUES (:name, :targetDate, :displayOrder, :createdAt, :updatedAt)"));
    insertQuery.bindValue(QStringLiteral(":name"), normalizedName);
    insertQuery.bindValue(QStringLiteral(":targetDate"), targetDate.toString(Qt::ISODate));
    insertQuery.bindValue(QStringLiteral(":displayOrder"), displayOrder);
    insertQuery.bindValue(QStringLiteral(":createdAt"), now.toString(Qt::ISODate));
    insertQuery.bindValue(QStringLiteral(":updatedAt"), now.toString(Qt::ISODate));

    if (!insertQuery.exec()) {
        emit errorOccurred(QStringLiteral("添加目标失败: ") + insertQuery.lastError().text());
        return false;
    }

    const int id = insertQuery.lastInsertId().toInt();
    m_model->addGoal(CountdownGoal(id, normalizedName, targetDate, displayOrder, now, now));
    updatePrimaryGoal();
    return true;
}

bool CountdownService::updateGoal(int id, const QString& name, const QDate& targetDate)
{
    QString normalizedName;
    if (!validateGoalInput(name, targetDate, &normalizedName)) {
        return false;
    }

    if (!ensureDatabaseReady()) {
        return false;
    }

    const int index = findGoalIndexById(id);
    if (index < 0) {
        emit errorOccurred(QStringLiteral("目标不存在"));
        return false;
    }

    const QDateTime now = QDateTime::currentDateTime();
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "UPDATE countdown_goals "
        "SET name = :name, target_date = :targetDate, updated_at = :updatedAt "
        "WHERE id = :id"));
    query.bindValue(QStringLiteral(":name"), normalizedName);
    query.bindValue(QStringLiteral(":targetDate"), targetDate.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":updatedAt"), now.toString(Qt::ISODate));
    query.bindValue(QStringLiteral(":id"), id);

    if (!query.exec()) {
        emit errorOccurred(QStringLiteral("更新目标失败: ") + query.lastError().text());
        return false;
    }
    if (query.numRowsAffected() != 1) {
        emit errorOccurred(QStringLiteral("更新目标失败: 目标数据已变化，请刷新后重试"));
        loadGoals();
        return false;
    }

    CountdownGoal updatedGoal = m_model->goals().at(index);
    updatedGoal.setName(normalizedName);
    updatedGoal.setTargetDate(targetDate);
    updatedGoal.setUpdatedAt(now);
    m_model->updateGoal(index, updatedGoal);
    updatePrimaryGoal();
    return true;
}

bool CountdownService::deleteGoal(int id)
{
    if (!ensureDatabaseReady()) {
        return false;
    }

    const int index = findGoalIndexById(id);
    if (index < 0) {
        emit errorOccurred(QStringLiteral("目标不存在"));
        return false;
    }

    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("DELETE FROM countdown_goals WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), id);
    if (!query.exec()) {
        emit errorOccurred(QStringLiteral("删除目标失败: ") + query.lastError().text());
        return false;
    }

    if (query.numRowsAffected() == 0) {
        emit errorOccurred(QStringLiteral("目标不存在"));
        return false;
    }

    m_model->removeGoal(index);
    updatePrimaryGoal();
    return true;
}

bool CountdownService::reorder(int fromIndex, int toIndex)
{
    if (!ensureDatabaseReady()) {
        return false;
    }

    const QList<CountdownGoal> originalGoals = m_model->goals();
    if (fromIndex < 0 || fromIndex >= originalGoals.count()
        || toIndex < 0 || toIndex >= originalGoals.count()
        || fromIndex == toIndex) {
        return false;
    }

    QList<CountdownGoal> reorderedGoals = originalGoals;
    reorderedGoals.move(fromIndex, toIndex);
    for (int i = 0; i < reorderedGoals.count(); ++i) {
        reorderedGoals[i].setDisplayOrder(i);
    }

    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.transaction()) {
        emit errorOccurred(QStringLiteral("开始排序事务失败: ") + db.lastError().text());
        loadGoals();
        return false;
    }

    QSqlQuery query(db);
    query.prepare(QStringLiteral(
        "UPDATE countdown_goals SET display_order = :displayOrder, updated_at = :updatedAt WHERE id = :id"));
    const QString updatedAt = QDateTime::currentDateTime().toString(Qt::ISODate);

    for (const CountdownGoal& goal : std::as_const(reorderedGoals)) {
        query.bindValue(QStringLiteral(":displayOrder"), goal.displayOrder());
        query.bindValue(QStringLiteral(":updatedAt"), updatedAt);
        query.bindValue(QStringLiteral(":id"), goal.id());
        if (!query.exec()) {
            const QString errorText = query.lastError().text();
            db.rollback();
            emit errorOccurred(QStringLiteral("排序失败: ") + errorText);
            m_model->setGoals(originalGoals);
            updatePrimaryGoal();
            return false;
        }
        if (query.numRowsAffected() != 1) {
            db.rollback();
            emit errorOccurred(QStringLiteral("排序失败: 目标数据已变化，请刷新后重试"));
            m_model->setGoals(originalGoals);
            updatePrimaryGoal();
            return false;
        }
    }

    if (!db.commit()) {
        const QString errorText = db.lastError().text();
        db.rollback();
        emit errorOccurred(QStringLiteral("提交排序事务失败: ") + errorText);
        m_model->setGoals(originalGoals);
        updatePrimaryGoal();
        return false;
    }

    // 数据库事务成功后再写回新的 displayOrder，避免模型显示和持久化顺序不一致。
    m_model->setGoals(reorderedGoals);
    updatePrimaryGoal();
    return true;
}

int CountdownService::calculateDaysRemaining(const QDate& targetDate) const
{
    if (!targetDate.isValid()) {
        return 0;
    }

    return m_referenceDate.daysTo(targetDate);
}

bool CountdownService::ensureDatabaseReady()
{
    const QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        emit errorOccurred(QStringLiteral("数据库未初始化"));
        return false;
    }

    // DatabaseManager 在测试或重启时可能用同一路径重新打开数据库。
    // 这里每次确认表结构并重载模型，避免单例缓存指向旧数据库内容。
    if (!initializeDatabase()) {
        emit errorOccurred(QStringLiteral("初始化倒计时数据库失败"));
        return false;
    }

    return loadGoals();
}

bool CountdownService::initializeDatabase()
{
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        qWarning() << "Cannot initialize countdown goals: database is not open";
        return false;
    }

    QSqlQuery query(db);
    if (!query.exec(QStringLiteral(
            "CREATE TABLE IF NOT EXISTS countdown_goals ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "name TEXT NOT NULL, "
            "target_date TEXT NOT NULL, "
            "display_order INTEGER NOT NULL, "
            "created_at TEXT NOT NULL, "
            "updated_at TEXT NOT NULL)"))) {
        qWarning() << "Failed to create countdown_goals table:" << query.lastError().text();
        return false;
    }

    if (!query.exec(QStringLiteral(
            "CREATE INDEX IF NOT EXISTS idx_display_order ON countdown_goals(display_order)"))) {
        qWarning() << "Failed to create countdown display_order index:" << query.lastError().text();
        return false;
    }

    m_databaseReady = true;
    m_databaseName = db.databaseName();
    return true;
}

bool CountdownService::loadGoals()
{
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral(
        "SELECT id, name, target_date, display_order, created_at, updated_at "
        "FROM countdown_goals ORDER BY display_order ASC, id ASC"));

    if (!query.exec()) {
        qWarning() << "Failed to load countdown goals:" << query.lastError().text();
        emit errorOccurred(QStringLiteral("读取倒计时目标失败: ") + query.lastError().text());
        return false;
    }

    QList<CountdownGoal> goals;
    while (query.next()) {
        goals.append(CountdownGoal(
            query.value(0).toInt(),
            query.value(1).toString(),
            QDate::fromString(query.value(2).toString(), Qt::ISODate),
            query.value(3).toInt(),
            parseStoredDateTime(query.value(4).toString()),
            parseStoredDateTime(query.value(5).toString())));
    }

    m_model->setGoals(goals);
    // 换库重载后重推统一基准日；内部同时刷新主目标缓存和通知。
    syncReferenceDate();
    return true;
}

void CountdownService::updatePrimaryGoal()
{
    QVariantMap nextPrimary;
    const QList<CountdownGoal>& goals = m_model->goals();
    if (!goals.isEmpty()) {
        nextPrimary = goalToVariantMap(goals.first());
    }

    if (m_primaryGoalCache == nextPrimary) {
        return;
    }

    m_primaryGoalCache = nextPrimary;
    emit primaryGoalChanged();
}

int CountdownService::findGoalIndexById(int id) const
{
    const QList<CountdownGoal>& goals = m_model->goals();
    for (int i = 0; i < goals.count(); ++i) {
        if (goals.at(i).id() == id) {
            return i;
        }
    }
    return -1;
}

bool CountdownService::validateGoalInput(const QString& name,
                                         const QDate& targetDate,
                                         QString* normalizedName)
{
    const QString trimmedName = name.trimmed();
    if (trimmedName.isEmpty() || trimmedName.length() > kMaxGoalNameLength) {
        emit errorOccurred(QStringLiteral("目标名称长度必须在1-50字符之间"));
        return false;
    }

    if (!targetDate.isValid()) {
        emit errorOccurred(QStringLiteral("目标日期无效"));
        return false;
    }

    if (normalizedName != nullptr) {
        *normalizedName = trimmedName;
    }
    return true;
}

QVariantMap CountdownService::goalToVariantMap(const CountdownGoal& goal) const
{
    QVariantMap map;
    map.insert(QStringLiteral("goalId"), goal.id());
    map.insert(QStringLiteral("name"), goal.name());
    map.insert(QStringLiteral("targetDate"), goal.targetDate());
    map.insert(QStringLiteral("displayOrder"), goal.displayOrder());
    map.insert(QStringLiteral("daysRemaining"), goal.daysRemainingFrom(m_referenceDate));
    return map;
}

void CountdownService::syncReferenceDateTo(const QDate& referenceDate)
{
    m_referenceDate = referenceDate;
    // 列表和横幅必须吃同一基准日，避免一处刷新后另一处仍显示旧天数。
    m_model->setReferenceDate(referenceDate);
    updatePrimaryGoal();
}

void CountdownService::syncReferenceDate()
{
    syncReferenceDateTo(LogicalDay::today(AppSettings::instance()->dayStartHour()));
}
