#include "SyncedSettings.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "ScheduleService.h"
#include "SyncSchema.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QVariantList>
#include <QVariantMap>

namespace SyncedSettings {

namespace {

const auto kDayStartHour = QStringLiteral("logic/dayStartHour");
const auto kWorkMinutes = QStringLiteral("focus/workMinutes");
const auto kBreakMinutes = QStringLiteral("focus/breakMinutes");
const auto kLongBreakEnabled = QStringLiteral("focus/longBreakEnabled");
const auto kLongBreakMinutes = QStringLiteral("focus/longBreakMinutes");
const auto kLongBreakInterval = QStringLiteral("focus/longBreakInterval");
const auto kFreeTimerWarningHours = QStringLiteral("focus/freeTimerWarningHours");
const auto kNickname = QStringLiteral("profile/nickname");
const auto kSemesterStartDate = QStringLiteral("schedule/semesterStartDate");
const auto kSemesterWeeks = QStringLiteral("schedule/semesterWeeks");
const auto kPeriods = QStringLiteral("schedule/periods");

// 正在写回的层数：写回里又触发了写回（例如节次写回后课表服务再发信号）也能正确配对。
int g_writeBackDepth = 0;

QString flag(bool value)
{
    return value ? QStringLiteral("1") : QStringLiteral("0");
}

bool parseInt(const QString& text, int* value)
{
    bool ok = false;
    *value = text.toInt(&ok);
    return ok;
}

// 节次表 → 文本：按节次先后的 [[开始, 结束], …]，紧凑写法。
QString periodsText(const QList<QPair<int, int>>& periods)
{
    QJsonArray array;
    for (const auto& period : periods) {
        array.append(QJsonArray{period.first, period.second});
    }
    return QString::fromUtf8(QJsonDocument(array).toJson(QJsonDocument::Compact));
}

QList<QPair<int, int>> currentPeriods()
{
    QList<QPair<int, int>> periods;
    for (const QVariant& item : ScheduleService::instance()->getPeriods()) {
        const QVariantMap period = item.toMap();
        periods.append({period.value(QStringLiteral("startMinutes")).toInt(),
                        period.value(QStringLiteral("endMinutes")).toInt()});
    }
    return periods;
}

// 文本 → 交给课表服务的节次列表。格式不对（不是数组、某一节不是两个整数）时返回 false，什么都不写。
bool parsePeriods(const QString& text, QVariantList* periods)
{
    const QJsonDocument document = QJsonDocument::fromJson(text.toUtf8());
    if (!document.isArray()) {
        return false;
    }
    for (const QJsonValue& value : document.array()) {
        const QJsonArray pair = value.toArray();
        if (pair.size() != 2 || !pair.at(0).isDouble() || !pair.at(1).isDouble()) {
            return false;
        }
        periods->append(QVariantMap{{QStringLiteral("startMinutes"), pair.at(0).toInt()},
                                    {QStringLiteral("endMinutes"), pair.at(1).toInt()}});
    }
    return !periods->isEmpty();
}

} // namespace

QHash<QString, QString> currentValues()
{
    const AppSettings* settings = AppSettings::instance();
    QHash<QString, QString> values{
        {kDayStartHour, QString::number(settings->dayStartHour())},
        {kWorkMinutes, QString::number(settings->workMinutes())},
        {kBreakMinutes, QString::number(settings->breakMinutes())},
        {kLongBreakEnabled, flag(settings->longBreakEnabled())},
        {kLongBreakMinutes, QString::number(settings->longBreakMinutes())},
        {kLongBreakInterval, QString::number(settings->longBreakInterval())},
        {kFreeTimerWarningHours, QString::number(settings->freeTimerWarningHours())},
        {kNickname, settings->nickname()},
        {kSemesterStartDate, settings->semesterStartDate()},
        {kSemesterWeeks, QString::number(settings->semesterWeeks())},
    };
    // 节次表读不出来（库没打开、读失败）时不放这一项：放一个空值进去，会被当成本机把节次清空了发出去。
    const QList<QPair<int, int>> periods = currentPeriods();
    if (!periods.isEmpty()) {
        values.insert(kPeriods, periodsText(periods));
    }
    const QMap<QString, int> goals = settings->dailyFocusGoals();
    for (auto it = goals.cbegin(); it != goals.cend(); ++it) {
        values.insert(SyncSchema::dailyGoalSettingKey(it.key()), QString::number(it.value()));
    }
    return values;
}

bool isFactoryDefault(const QString& key, const QString& value)
{
    static const QHash<QString, QString> defaults{
        {kDayStartHour, QString::number(AppSettings::kDefaultDayStartHour)},
        {kWorkMinutes, QString::number(AppSettings::kDefaultWorkMinutes)},
        {kBreakMinutes, QString::number(AppSettings::kDefaultBreakMinutes)},
        {kLongBreakEnabled, flag(AppSettings::kDefaultLongBreakEnabled)},
        {kLongBreakMinutes, QString::number(AppSettings::kDefaultLongBreakMinutes)},
        {kLongBreakInterval, QString::number(AppSettings::kDefaultLongBreakInterval)},
        {kFreeTimerWarningHours, QString::number(AppSettings::kDefaultFreeTimerWarningHours)},
        {kNickname, QString()},
        {kSemesterStartDate, QString()},
        {kSemesterWeeks, QString::number(AppSettings::kDefaultSemesterWeeks)},
        {kPeriods, periodsText(DatabaseManager::defaultSchedulePeriods())},
    };
    const auto it = defaults.constFind(key);
    return it != defaults.constEnd() && it.value() == value;
}

bool apply(const QString& key, const QString& value)
{
    AppSettings* settings = AppSettings::instance();
    int number = 0;
    const QString goalDate = SyncSchema::dailyGoalDateOf(key);
    if (!goalDate.isEmpty()) {
        return parseInt(value, &number) && settings->setDailyFocusGoal(goalDate, number);
    }
    // 各个 setter 自己会把越界值归一，并在值真的变了时发出变更信号（界面、计时器据此刷新）。
    const QHash<QString, void (AppSettings::*)(int)> integers{
        {kDayStartHour, &AppSettings::setDayStartHour},
        {kWorkMinutes, &AppSettings::setWorkMinutes},
        {kBreakMinutes, &AppSettings::setBreakMinutes},
        {kLongBreakMinutes, &AppSettings::setLongBreakMinutes},
        {kLongBreakInterval, &AppSettings::setLongBreakInterval},
        {kFreeTimerWarningHours, &AppSettings::setFreeTimerWarningHours},
        {kSemesterWeeks, &AppSettings::setSemesterWeeks},
    };
    const auto integer = integers.constFind(key);
    if (integer != integers.constEnd()) {
        if (!parseInt(value, &number)) {
            return false;
        }
        (settings->*integer.value())(number);
        return true;
    }
    if (key == kLongBreakEnabled) {
        if (value != QLatin1String("1") && value != QLatin1String("0")) {
            return false;
        }
        settings->setLongBreakEnabled(value == QLatin1String("1"));
        return true;
    }
    if (key == kNickname) {
        settings->setNickname(value);
        return true;
    }
    if (key == kSemesterStartDate) {
        settings->setSemesterStartDate(value);
        return true;
    }
    if (key == kPeriods) {
        QVariantList periods;
        return parsePeriods(value, &periods) && ScheduleService::instance()->setPeriods(periods);
    }
    return false;
}

WriteBackScope::WriteBackScope()
{
    ++g_writeBackDepth;
}

WriteBackScope::~WriteBackScope()
{
    --g_writeBackDepth;
}

bool isWritingBack()
{
    return g_writeBackDepth > 0;
}

bool remove(const QString& key)
{
    const QString goalDate = SyncSchema::dailyGoalDateOf(key);
    return goalDate.isEmpty() || AppSettings::instance()->removeDailyFocusGoal(goalDate);
}

} // namespace SyncedSettings
