#include "SyncedSettings.h"

#include "AppSettings.h"
#include "DatabaseManager.h"
#include "ScheduleService.h"
#include "SyncSchema.h"

#include <QDate>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMetaObject>
#include <QObject>
#include <QVariantList>
#include <QVariantMap>

#include <algorithm>
#include <cmath>
#include <limits>

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

bool isStrictIsoDate(const QString& isoDate)
{
    const QDate date = QDate::fromString(isoDate, Qt::ISODate);
    return date.isValid() && date.toString(Qt::ISODate) == isoDate;
}

bool parseStrictJsonInt(const QJsonValue& value, int* out)
{
    if (!value.isDouble()) {
        return false;
    }
    const double number = value.toDouble();
    if (!std::isfinite(number) || std::floor(number) != number
        || number < std::numeric_limits<int>::min()
        || number > std::numeric_limits<int>::max()) {
        return false;
    }
    *out = static_cast<int>(number);
    return true;
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

// 文本 → 交给课表服务的节次列表。格式不对或超出本版本课表服务的节次数量/起止范围/不重叠约束时返回 false，
// 什么都不写，也不误判成数据库写入故障。
bool parsePeriods(const QString& text, QVariantList* periods)
{
    const QJsonDocument document = QJsonDocument::fromJson(text.toUtf8());
    if (!document.isArray()) {
        return false;
    }
    const QJsonArray array = document.array();
    if (array.isEmpty() || array.size() > ScheduleService::kMaxPeriodCount) {
        return false;
    }
    QList<QPair<int, int>> sorted;
    sorted.reserve(array.size());
    for (const QJsonValue& value : array) {
        const QJsonArray pair = value.toArray();
        int startMinutes = 0;
        int endMinutes = 0;
        if (pair.size() != 2
            || !parseStrictJsonInt(pair.at(0), &startMinutes)
            || !parseStrictJsonInt(pair.at(1), &endMinutes)) {
            return false;
        }
        if (startMinutes < 0 || startMinutes >= ScheduleService::kMinutesPerDay
            || endMinutes <= 0 || endMinutes > ScheduleService::kMinutesPerDay
            || endMinutes <= startMinutes) {
            return false;
        }
        sorted.append({startMinutes, endMinutes});
        periods->append(QVariantMap{{QStringLiteral("startMinutes"), startMinutes},
                                    {QStringLiteral("endMinutes"), endMinutes}});
    }
    std::sort(sorted.begin(), sorted.end(), [](const auto& lhs, const auto& rhs) {
        return lhs.first != rhs.first ? lhs.first < rhs.first : lhs.second < rhs.second;
    });
    for (qsizetype i = 1; i < sorted.size(); ++i) {
        if (sorted.at(i).first < sorted.at(i - 1).second) {
            return false;
        }
    }
    return true;
}

// 仅在调用 AppSettings 写回期间捕获底层 QSettings 写入错误。
struct WriteFailureWatcher {
    QMetaObject::Connection connection;
    bool failed = false;
    QString message;

    explicit WriteFailureWatcher(AppSettings* settings)
    {
        if (!settings) {
            failed = true;
            return;
        }
        connection = QObject::connect(
            settings, &AppSettings::settingsWriteFailed,
            [this](const QString&, const QString& msg) {
                failed = true;
                if (message.isEmpty()) {
                    message = msg;
                }
            });
    }

    ~WriteFailureWatcher()
    {
        if (connection) {
            QObject::disconnect(connection);
        }
    }

    WriteFailureWatcher(const WriteFailureWatcher&) = delete;
    WriteFailureWatcher& operator=(const WriteFailureWatcher&) = delete;
};

} // namespace

QHash<QString, QString> currentValues(bool* ok)
{
    if (ok) {
        *ok = false;
    }
    AppSettings* settings = AppSettings::instance();
    if (!settings || !settings->isBackendHealthy()) {
        return {};
    }
    bool periodsOk = false;
    const QVariantList periodList = ScheduleService::instance()->getPeriods(&periodsOk);
    if (!periodsOk) {
        return {};
    }

    QList<QPair<int, int>> periods;
    for (const QVariant& item : periodList) {
        const QVariantMap period = item.toMap();
        periods.append({period.value(QStringLiteral("startMinutes")).toInt(),
                        period.value(QStringLiteral("endMinutes")).toInt()});
    }

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
    if (!periods.isEmpty()) {
        values.insert(kPeriods, periodsText(periods));
    }
    const QMap<QString, int> goals = settings->dailyFocusGoals();
    for (auto it = goals.cbegin(); it != goals.cend(); ++it) {
        values.insert(SyncSchema::dailyGoalSettingKey(it.key()), QString::number(it.value()));
    }
    if (!settings->isBackendHealthy()) {
        return {};
    }
    if (ok) {
        *ok = true;
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

ApplyStatus applyWithStatus(const QString& key, const QString& value, QString* errorMessage)
{
    const auto failStorage = [errorMessage](const QString& msg) {
        if (errorMessage) {
            *errorMessage = msg;
        }
        return ApplyStatus::StorageFailure;
    };

    AppSettings* settings = AppSettings::instance();
    if (!settings) {
        return failStorage(QStringLiteral("偏好设置服务未就绪"));
    }

    int number = 0;
    const QString goalDate = SyncSchema::dailyGoalDateOf(key);
    if (!goalDate.isEmpty()) {
        if (!isStrictIsoDate(goalDate) || !parseInt(value, &number)
            || number < 1 || number > 24 * 60) {
            return ApplyStatus::Unsupported;
        }
        WriteFailureWatcher watcher(settings);
        if (!settings->setDailyFocusGoal(goalDate, number)
            || watcher.failed || !settings->isBackendHealthy()) {
            return failStorage(watcher.message);
        }
        return ApplyStatus::Applied;
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
            return ApplyStatus::Unsupported;
        }
        WriteFailureWatcher watcher(settings);
        (settings->*integer.value())(number);
        if (watcher.failed || !settings->isBackendHealthy()) {
            return failStorage(watcher.message);
        }
        return ApplyStatus::Applied;
    }
    if (key == kLongBreakEnabled) {
        if (value != QLatin1String("1") && value != QLatin1String("0")) {
            return ApplyStatus::Unsupported;
        }
        WriteFailureWatcher watcher(settings);
        settings->setLongBreakEnabled(value == QLatin1String("1"));
        if (watcher.failed || !settings->isBackendHealthy()) {
            return failStorage(watcher.message);
        }
        return ApplyStatus::Applied;
    }
    if (key == kNickname) {
        WriteFailureWatcher watcher(settings);
        settings->setNickname(value);
        if (watcher.failed || !settings->isBackendHealthy()) {
            return failStorage(watcher.message);
        }
        return ApplyStatus::Applied;
    }
    if (key == kSemesterStartDate) {
        // 非空但不是合法 ISO 日期的远端取值属于格式不支持，不能送进 setSemesterStartDate 冒充存储写失败。
        const QString trimmed = value.trimmed();
        if (!trimmed.isEmpty() && !QDate::fromString(trimmed, Qt::ISODate).isValid()) {
            return ApplyStatus::Unsupported;
        }
        WriteFailureWatcher watcher(settings);
        settings->setSemesterStartDate(value);
        if (watcher.failed || !settings->isBackendHealthy()) {
            return failStorage(watcher.message);
        }
        return ApplyStatus::Applied;
    }
    if (key == kPeriods) {
        QVariantList periods;
        if (!parsePeriods(value, &periods)) {
            return ApplyStatus::Unsupported;
        }
        if (!ScheduleService::instance()->setPeriods(periods)) {
            return failStorage(QStringLiteral("保存课表节次失败"));
        }
        return ApplyStatus::Applied;
    }
    return ApplyStatus::Unsupported;
}

bool apply(const QString& key, const QString& value)
{
    return applyWithStatus(key, value) == ApplyStatus::Applied;
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

ApplyStatus removeWithStatus(const QString& key, QString* errorMessage)
{
    const QString goalDate = SyncSchema::dailyGoalDateOf(key);
    if (goalDate.isEmpty()) {
        return ApplyStatus::Applied;
    }
    if (!isStrictIsoDate(goalDate)) {
        return ApplyStatus::Unsupported;
    }
    AppSettings* settings = AppSettings::instance();
    if (!settings) {
        if (errorMessage) {
            *errorMessage = QStringLiteral("偏好设置服务未就绪");
        }
        return ApplyStatus::StorageFailure;
    }
    WriteFailureWatcher watcher(settings);
    if (!settings->removeDailyFocusGoal(goalDate)
        || watcher.failed || !settings->isBackendHealthy()) {
        if (errorMessage) {
            *errorMessage = watcher.message;
        }
        return ApplyStatus::StorageFailure;
    }
    return ApplyStatus::Applied;
}

bool remove(const QString& key)
{
    return removeWithStatus(key) == ApplyStatus::Applied;
}

} // namespace SyncedSettings
