#include "CountdownService.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "LogicalDay.h"
#include "LogicalDayService.h"
#include "TrashStore.h"

#include <QDateTime>
#include <QDebug>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>

#include <algorithm>
#include <limits>
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

    // 换库/同路径重开统一由 DatabaseManager 通知驱动整体重载；
    // 业务操作路径（ensureDatabaseReady）便不再需要防御性的全量刷新。
    connect(DatabaseManager::instance(), &DatabaseManager::databaseChanged, this, [this]() {
        if (initializeDatabase()) {
            reload();
        } else {
            m_databaseReady = false;
            emit operationFailed(QStringLiteral("初始化倒计时数据库失败"));
        }
    });

    const QSqlDatabase db = DatabaseManager::instance()->database();
    if (db.isOpen()) {
        if (initializeDatabase()) {
            reload();
        } else {
            emit operationFailed(QStringLiteral("初始化倒计时数据库失败"));
        }
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
        emit operationFailed(QStringLiteral("获取目标排序失败: ") + orderQuery.lastError().text());
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
        emit operationFailed(QStringLiteral("添加目标失败: ") + insertQuery.lastError().text());
        return false;
    }

    const int id = insertQuery.lastInsertId().toInt();
    m_model->addGoal(CountdownGoal(id, normalizedName, targetDate, displayOrder, now, now));
    updatePrimaryGoal();
    return true;
}

bool CountdownService::updateGoalChanges(int id, const QVariantMap& changes)
{
    const QString nameKey = QStringLiteral("name");
    const QString dateKey = QStringLiteral("targetDate");
    for (auto it = changes.cbegin(); it != changes.cend(); ++it) {
        if (it.key() != nameKey && it.key() != dateKey) {
            emit operationFailed(QStringLiteral("不能修改目标字段：%1").arg(it.key()));
            return false;
        }
        if (it.value().typeId() != QMetaType::QString) {
            emit operationFailed(QStringLiteral("目标名称和日期必须是文字"));
            return false;
        }
    }
    QDate targetDate;
    if (changes.contains(dateKey)) {
        targetDate = QDate::fromString(changes.value(dateKey).toString(), Qt::ISODate);
        if (!targetDate.isValid()) {
            emit operationFailed(QStringLiteral("目标日期无效"));
            return false;
        }
    }
    if (!ensureDatabaseReady()) {
        return false;
    }
    // 当前值从库里读，不用内存里的列表：另一台刚同步进来的修改以库为准。
    QSqlQuery query(DatabaseManager::instance()->database());
    query.prepare(QStringLiteral("SELECT name, target_date FROM countdown_goals WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), id);
    if (!query.exec()) {
        emit operationFailed(QStringLiteral("读取目标失败: ") + query.lastError().text());
        return false;
    }
    if (!query.next()) {
        emit operationFailed(QStringLiteral("目标不存在"));
        return false;
    }
    const QString currentName = query.value(0).toString();
    const QDate currentDate = QDate::fromString(query.value(1).toString(), Qt::ISODate);
    query.finish();
    if (changes.isEmpty()) {
        return true;
    }
    // 没交的字段用库里现在的值再写一遍：值没变，同步就不会把它记成本机修改，也就不会盖掉另一台。
    // 前提是库里的值已按 updateGoal 同一套规则规范化（名称裁剪空白、日期只存 ISO 日期）：现有写入入口和
    // 另一台同步过来的数据都满足。以后新增不经这套规则的写入路径，或改了规范化规则，要改成只更新交进来的列，
    // 否则会顺手改写没交的字段。
    // 数据库只在主线程读写，读和写之间同步插不进来。
    return updateGoal(id, changes.contains(nameKey) ? changes.value(nameKey).toString() : currentName,
                      changes.contains(dateKey) ? targetDate : currentDate);
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
        emit operationFailed(QStringLiteral("目标不存在"));
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
        emit operationFailed(QStringLiteral("更新目标失败: ") + query.lastError().text());
        return false;
    }
    if (query.numRowsAffected() != 1) {
        loadGoals();
        emit operationFailed(QStringLiteral("更新目标失败: 目标数据已变化，请刷新后重试"));
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
        emit operationFailed(QStringLiteral("目标不存在"));
        return false;
    }

    // 先写废纸篓再删除，同一事务：写入失败整体回滚，宁可删不掉也不能删了却没进废纸篓。
    // 列表模型与主目标只在提交成功之后更新，回滚时界面不会先于数据库变化。
    QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.transaction()) {
        emit operationFailed(QStringLiteral("删除目标失败: ") + db.lastError().text());
        return false;
    }
    QString trashError;
    if (!TrashStore::captureCountdownGoal(db, id, &trashError)) {
        db.rollback();
        emit operationFailed(trashError == TrashStore::kMissingRecord
                                 ? QStringLiteral("目标不存在")
                                 : QStringLiteral("删除目标失败: ") + trashError);
        return false;
    }
    QSqlQuery query(db);
    query.prepare(QStringLiteral("DELETE FROM countdown_goals WHERE id = :id"));
    query.bindValue(QStringLiteral(":id"), id);
    if (!query.exec()) {
        const QString reason = query.lastError().text();
        query.finish();
        db.rollback();
        emit operationFailed(QStringLiteral("删除目标失败: ") + reason);
        return false;
    }

    if (query.numRowsAffected() == 0) {
        query.finish();
        db.rollback();
        emit operationFailed(QStringLiteral("目标不存在"));
        return false;
    }
    query.finish();
    if (!db.commit()) {
        const QString reason = db.lastError().text();
        db.rollback();
        emit operationFailed(QStringLiteral("删除目标失败: ") + reason);
        return false;
    }

    m_model->removeGoal(index);
    updatePrimaryGoal();
    emit TrashNotifier::instance()->changed();
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
        const QString failure = QStringLiteral("开始排序事务失败: ") + db.lastError().text();
        // reload 成功会发 goalsReloaded，页面据此清除旧错误；因此必须先刷新再报告本次
        // 写入失败，避免同一调用栈里的成功读操作把真实失败状态立刻覆盖掉。
        loadGoals();
        emit operationFailed(failure);
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
            emit operationFailed(QStringLiteral("排序失败: ") + errorText);
            m_model->setGoals(originalGoals);
            updatePrimaryGoal();
            return false;
        }
        if (query.numRowsAffected() != 1) {
            db.rollback();
            emit operationFailed(QStringLiteral("排序失败: 目标数据已变化，请刷新后重试"));
            m_model->setGoals(originalGoals);
            updatePrimaryGoal();
            return false;
        }
    }

    if (!db.commit()) {
        const QString errorText = db.lastError().text();
        db.rollback();
        emit operationFailed(QStringLiteral("提交排序事务失败: ") + errorText);
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

    // daysTo 返回 64 位；剩余天数对外是 int。正常日期远在范围内，夹一下只防同步进来的荒唐日期截断成乱数。
    return static_cast<int>(std::clamp<qint64>(m_referenceDate.daysTo(targetDate), std::numeric_limits<int>::min(),
                                               std::numeric_limits<int>::max()));
}

bool CountdownService::ensureDatabaseReady()
{
    const QSqlDatabase db = DatabaseManager::instance()->database();
    if (!db.isOpen()) {
        emit operationFailed(QStringLiteral("数据库未初始化"));
        return false;
    }

    // 换库和重开由 databaseChanged 信号整体重载；这里只兜底“信号建立前就绪”的场景。
    // 常规增删改不再全量 reset 模型，避免每次操作都重建列表 delegate 并丢失滚动位置。
    if (m_databaseReady && m_databaseName == db.databaseName()) {
        return true;
    }

    if (!initializeDatabase()) {
        emit operationFailed(QStringLiteral("初始化倒计时数据库失败"));
        return false;
    }

    return true;
}

bool CountdownService::reload()
{
    if (!ensureDatabaseReady()) {
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
        // 查询失败时不能清空旧模型；页面仍可展示上次成功数据和可恢复错误。
        emit operationFailed(QStringLiteral("读取倒计时目标失败: ") + query.lastError().text());
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
    emit goalsReloaded();
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
        emit operationFailed(QStringLiteral("目标名称长度必须在1-50字符之间"));
        return false;
    }

    if (!targetDate.isValid()) {
        emit operationFailed(QStringLiteral("目标日期无效"));
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
