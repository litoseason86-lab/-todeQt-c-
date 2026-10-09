#include <QtTest>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

#include "../src/services/ScheduleWeeks.h"
#include "../src/services/HeatmapBands.h"
#include <limits>

class CaliberTests : public QObject
{
    Q_OBJECT
private slots:
    void scheduleWeeks();
    void heatmapBands();
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

QTEST_GUILESS_MAIN(CaliberTests)
#include "CaliberTests.moc"
