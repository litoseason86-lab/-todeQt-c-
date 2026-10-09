#include <QtTest>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

#include "../src/services/ScheduleWeeks.h"

class CaliberTests : public QObject
{
    Q_OBJECT
private slots:
    void scheduleWeeks();
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

QTEST_GUILESS_MAIN(CaliberTests)
#include "CaliberTests.moc"
