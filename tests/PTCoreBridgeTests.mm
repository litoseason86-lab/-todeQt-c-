#include "../src/platform/ios/bridge/PTBridgeSupport.h"
#include "../src/services/PendingDeletion.h"
#include "../src/services/TaskInteractionCoordinator.h"
#include <QtTest>
#include <limits>

class PTCoreBridgeTests : public QObject {
    Q_OBJECT
private slots:
    void convertsStringsWithoutTruncation();
    void rejectsInvalidDatesAndPreservesTimestamps();
    void rejectsIntegerOverflow();
    void collectsOnlyCallFailures();
    void registryUsesWeakTypedReferences();
};
// 产品保证：中文、空串和超长字符串逐字保留，桥接不偷偷截断输入。
void PTCoreBridgeTests::convertsStringsWithoutTruncation()
{
    @autoreleasepool {
        using namespace PTBridgeSupport;
        const QString longText = QStringLiteral("中文🙂").repeated(10000);
        QCOMPARE(string(string(longText)), longText);
        QCOMPARE(string(@""), QStringLiteral(""));
        QVERIFY([string(QString()) isEqualToString:@""]);
    }
}
// 产品保证：日期严格按 ISO 日历校验，闰日合法，时刻保留毫秒与时区偏移。
void PTCoreBridgeTests::rejectsInvalidDatesAndPreservesTimestamps()
{
    @autoreleasepool {
        using namespace PTBridgeSupport;
        QCOMPARE(date(@"2024-02-29"), QDate(2024, 2, 29));
        QVERIFY(!date(@"2023-02-29").isValid());
        QVERIFY(!date(@"2024-2-29").isValid());
        QVERIFY(!date(@"").isValid());
        QVERIFY(!date(@"2024-02-29extra").isValid());
        QVERIFY([date(QDate(2024, 2, 29)) isEqualToString:@"2024-02-29"]);
        const QDateTime value = QDateTime::fromString(QStringLiteral("2024-02-29T12:34:56.789+08:00"), Qt::ISODateWithMs);
        QVERIFY(value.isValid());
        QCOMPARE(timestamp(timestamp(value)), value);
        QCOMPARE(timestamp(timestamp(value)).time().msec(), 789);
        QVERIFY(!timestamp(@"garbage").isValid());
    }
}
// 产品保证：宽编号超出 C++ int 范围时拒绝，不截断成另一条记录编号。
void PTCoreBridgeTests::rejectsIntegerOverflow()
{
    using namespace PTBridgeSupport;
    int result = 17;
    QVERIFY(integer(-1, &result)); QCOMPARE(result, -1);
    QVERIFY(integer(std::numeric_limits<int>::max(), &result));
    QCOMPARE(result, std::numeric_limits<int>::max());
    QVERIFY(!integer(NSIntegerMax, &result));
    QVERIFY(!integer(NSIntegerMin, &result));
    QCOMPARE(result, std::numeric_limits<int>::max());
}
// 产品保证：同步失败只返回当前调用，背景失败仍可上报，嵌套错误与外层隔离。
void PTCoreBridgeTests::collectsOnlyCallFailures()
{
    PTBridgeSupport::FailureCollector collector;
    QVERIFY(!collector.collect(QStringLiteral("背景")));
    {
        PTBridgeSupport::FailureCollector::Call outer(collector);
        QVERIFY(collector.collect(QStringLiteral("外层")));
        {
            PTBridgeSupport::FailureCollector::Call inner(collector);
            QVERIFY(collector.collect(QStringLiteral("内层")));
            QCOMPARE(inner.error(), QStringLiteral("内层"));
        }
        QCOMPARE(outer.error(), QStringLiteral("外层"));
    }
    QVERIFY(!collector.collect(QStringLiteral("调用后")));
}
// 产品保证：登记按类型取服务，服务释放后自动失效，名字可复用但不能错转类型。
void PTCoreBridgeTests::registryUsesWeakTypedReferences()
{
    using namespace PTBridgeSupport;
    auto *object = new TaskInteractionCoordinator(nullptr);
    registerService(QStringLiteral("test.interactions"), object);
    QCOMPARE(service<TaskInteractionCoordinator>(QStringLiteral("test.interactions")), object);
    QVERIFY(service<PendingDeletion>(QStringLiteral("test.interactions")) == nullptr);
    delete object;
    QVERIFY(registeredService(QStringLiteral("test.interactions")) == nullptr);
    QVERIFY(registeredService(QStringLiteral("unknown")) == nullptr);
}
QTEST_GUILESS_MAIN(PTCoreBridgeTests)
#include "PTCoreBridgeTests.moc"
