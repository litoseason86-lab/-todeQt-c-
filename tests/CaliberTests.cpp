#include <QtTest>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

#include "../src/services/ScheduleWeeks.h"
#include "../src/services/HeatmapBands.h"
#include <limits>
#include "../src/services/LogicalDay.h"
#include "../src/services/RoutineRules.h"
#include "../src/services/StatisticsPeriod.h"

class CaliberTests : public QObject
{
    Q_OBJECT
private slots:
    void scheduleWeeks();
    void heatmapBands();
    void logicalDay();
    void routineWeekdays();
    void statisticsPeriod();
};

// 读表失败必须使测试失败，不能把零条数据当成口径通过。
static QJsonArray fixtures(const char* name)
{
    QFile file(QString::fromUtf8(CALIBERS_DIR) + QLatin1Char('/') + QLatin1String(name) + QStringLiteral(".json"));
    if (!file.open(QIODevice::ReadOnly)) { QTest::qFail(qPrintable(file.errorString()), __FILE__, __LINE__); return {}; }
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(file.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !document.isArray() || document.array().isEmpty()) {
        QTest::qFail("口径表必须是非空 JSON 数组", __FILE__, __LINE__); return {};
    }
    return document.array();
}

// 学期周次以自然周一为锚点，闰日、跨年和相邻时段都遵守同一张跨端对照表。
void CaliberTests::scheduleWeeks()
{
    const QJsonArray rows = fixtures("schedule-weeks");
    QVERIFY(!rows.isEmpty());
    for (const QJsonValue& row : rows) {
        const QJsonObject data = row.toObject();
        const QJsonObject input = data.value("input").toObject();
        const QString op = input.value("op").toString();
        const QString start = input.value("start").toString();
        const QDate date = QDate::fromString(input.value("date").toString(), Qt::ISODate);
        QJsonValue actual;
        QDate result;
        if (op == "weekIndexForDate") actual = ScheduleWeeks::weekIndexForDate(start, date);
        else if (op == "overlaps") actual = ScheduleWeeks::overlaps(input.value("aStart").toDouble(), input.value("aEnd").toDouble(),
            input.value("bStart").toDouble(), input.value("bEnd").toDouble());
        else {
            if (op == "mondayOf") result = ScheduleWeeks::mondayOf(date);
            else if (op == "parseSemesterStart") result = ScheduleWeeks::parseSemesterStart(start);
            else if (op == "mondayOfWeek") result = ScheduleWeeks::mondayOfWeek(start, input.value("week").toInt());
            else if (op == "dateOfWeekday") result = ScheduleWeeks::dateOfWeekday(start, input.value("week").toInt(), input.value("weekday").toInt());
            else QFAIL("未知周次操作");
            actual = result.isValid() ? QJsonValue(result.toString(Qt::ISODate)) : QJsonValue(QJsonValue::Null);
        }
        QVERIFY2(actual == data.value("expected"), qPrintable(data.value("reason").toString() + QStringLiteral("：") + op));
    }
}

// 非有限值用标签表达，JSON null 与数字串沿用 JS Number 的输入口径。
static double number(const QJsonValue& input)
{
    if (input.isNull()) return 0;
    if (input.isDouble()) return input.toDouble();
    if (input.isString()) {
        bool ok = false;
        const double result = input.toString().toDouble(&ok);
        return ok ? result : std::numeric_limits<double>::quiet_NaN();
    }
    const QString special = input.toObject().value("special").toString();
    if (special == "Infinity") return std::numeric_limits<double>::infinity();
    if (special == "-Infinity") return -std::numeric_limits<double>::infinity();
    return std::numeric_limits<double>::quiet_NaN();
}

// 不足一分钟也有投入，阈值等号归入下一档，坏数据不能成为最高档。
void CaliberTests::heatmapBands()
{
    const QJsonArray rows = fixtures("heatmap-bands");
    QVERIFY(!rows.isEmpty());
    for (const QJsonValue& row : rows) {
        const QJsonObject data = row.toObject();
        QCOMPARE(HeatmapBands::bandForMinutes(number(data.value("input"))), data.value("expected").toInt());
    }
}

// 凌晨归属由本地时分与日界决定，不以经过毫秒替代日历天。
void CaliberTests::logicalDay()
{
    const QJsonArray rows = fixtures("logical-day");
    QVERIFY(!rows.isEmpty());
    for (const QJsonValue& row : rows) {
        const QJsonObject data = row.toObject();
        const QJsonObject input = data.value("input").toObject();
        // 表中不带时区的文本固定为 UTC 构造，仅比较墙钟字段，隔离运行机器的时区。
        const QDateTime timestamp = QDateTime::fromString(input.value("timestamp").toString() + QLatin1Char('Z'), Qt::ISODate);
        QVERIFY(timestamp.isValid());
        QCOMPARE(LogicalDay::dateOf(timestamp, input.value("dayStartHour").toInt()).toString(Qt::ISODate), data.value("expected").toString());
    }
}

// 每日例行有效范围与星期位序必须和界面共用表，越界星期不生成任务。
void CaliberTests::routineWeekdays()
{
    const QJsonArray rows = fixtures("routine-weekdays");
    QVERIFY(!rows.isEmpty());
    for (const QJsonValue& row : rows) {
        const QJsonObject data = row.toObject();
        const QJsonObject input = data.value("input").toObject(), expected = data.value("expected").toObject();
        const int mask = input.value("mask").toInt();
        const int bit = RoutineRules::maskForDayOfWeek(input.value("dayOfWeek").toInt());
        QCOMPARE(RoutineRules::isValidWeekdayMask(mask), expected.value("valid").toBool());
        QCOMPARE(bit, expected.value("bit").toInt());
        QCOMPARE((mask & bit) != 0, expected.value("matches").toBool());
    }
}

// 统计页翻周期：周一开头、月从 1 号起，跨年与闰月按日历走；当前期不能再往后翻，比较对象的距离跨年不算错。
// 周一归位与 Mac StatisticsFormat.js 的 mondayOf / endOfWeek 读同一张表；翻页、当前期与比较距离
// 是 Mac StatisticsView.qml 内联的规则，没有 JS 函数可读表，所以在这里逐条写明。
void CaliberTests::statisticsPeriod()
{
    using StatisticsPeriod::Range;
    const QJsonArray rows = fixtures("statistics-format");
    int checked = 0;
    for (const QJsonValue& row : rows) {
        const QJsonObject data = row.toObject();
        const QJsonObject input = data.value("input").toObject();
        const QString op = input.value("op").toString();
        if (op != QLatin1String("mondayOf") && op != QLatin1String("endOfWeek")) continue;
        // 表里的本地日期可能带时分，只取日期部分；周期计算只看日历日。
        const QDate date = QDate::fromString(input.value("args").toArray().at(0).toObject().value("date").toString().left(10), Qt::ISODate);
        const StatisticsPeriod::Period week = StatisticsPeriod::forAnchor(date, Range::Week, 0, date);
        const QDate actual = op == QLatin1String("mondayOf") ? week.start : week.end;
        QVERIFY2(actual.toString(Qt::ISODate) == data.value("expected").toString(), qPrintable(data.value("reason").toString()));
        ++checked;
    }
    // 表里没有这两种操作时用例必须失败，不能零条通过。
    QVERIFY(checked >= 4);

    struct Case { const char* anchor; Range range; int shift; const char* today;
                  const char* start; const char* end; int distance; bool current; bool canAdvance; };
    const Case cases[] = {
        // 1 月 31 日往后翻一月落在 2 月整月（闰年 29 日），不是 3 月 2 日；离当前 3 月隔一期，比较对象是上上月。
        {"2024-01-31", Range::Month, 1, "2024-03-01", "2024-02-01", "2024-02-29", 2, false, true},
        // 1 月往前翻跨年到上一年 12 月；比较对象 11 月离当前 1 月两个月（按 年*12+月，跨年不算成 -10）。
        {"2027-01-15", Range::Month, -1, "2027-01-20", "2026-12-01", "2026-12-31", 2, false, true},
        // 周五所在周跨年：周一在上一年，逻辑今日是同周周日，仍算当前周，不能往后翻。
        {"2027-01-01", Range::Week, 0, "2027-01-03", "2026-12-28", "2027-01-03", 1, true, false},
        {"2027-01-01", Range::Week, -1, "2027-01-03", "2026-12-21", "2026-12-27", 2, false, true},
        // 逻辑今日是周日时不能被推到下一周：上周仍是距离 2、可往后翻。
        {"2026-09-01", Range::Week, -1, "2026-09-06", "2026-08-24", "2026-08-30", 2, false, true},
        // 翻到逻辑今日之后的日子：不是当前期，也不能再往后翻。
        {"2024-02-28", Range::Day, 1, "2024-02-28", "2024-02-29", "2024-02-29", 0, false, false},
        {"2024-03-01", Range::Day, -1, "2024-03-01", "2024-02-29", "2024-02-29", 2, false, true},
    };
    for (const Case& c : cases) {
        const StatisticsPeriod::Period period = StatisticsPeriod::forAnchor(
            QDate::fromString(QLatin1String(c.anchor), Qt::ISODate), c.range, c.shift, QDate::fromString(QLatin1String(c.today), Qt::ISODate));
        const QString label = QStringLiteral("%1 平移 %2").arg(QLatin1String(c.anchor)).arg(c.shift);
        QVERIFY2(period.isValid(), qPrintable(label));
        QCOMPARE(period.start.toString(Qt::ISODate), QLatin1String(c.start));
        QCOMPARE(period.end.toString(Qt::ISODate), QLatin1String(c.end));
        QCOMPARE(period.comparisonDistance, c.distance);
        QCOMPARE(period.current, c.current);
        QCOMPARE(period.canAdvance, c.canAdvance);
    }

    StatisticsPeriod::Range range = Range::Day;
    QVERIFY(StatisticsPeriod::parseRange(QStringLiteral("month"), &range));
    QCOMPARE(range, Range::Month);
    QVERIFY(!StatisticsPeriod::parseRange(QStringLiteral("Month"), &range));
    QVERIFY(!StatisticsPeriod::parseRange(QString(), &range));
    QVERIFY(!StatisticsPeriod::forAnchor(QDate(), Range::Day, 0, QDate(2024, 2, 28)).isValid());
    QVERIFY(!StatisticsPeriod::forAnchor(QDate(2024, 2, 28), Range::Week, 0, QDate()).isValid());
}

QTEST_GUILESS_MAIN(CaliberTests)
#include "CaliberTests.moc"
