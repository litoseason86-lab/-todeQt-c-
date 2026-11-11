#include <QtTest>

#include "../src/platform/apple/AppleNotificationBackend.h"

class AppleNotificationBackendTests : public QObject
{
    Q_OBJECT

private slots:
    void deniedThenReauthorizedQueriesAgainAndDelivers();
    void authorizationQueryFailureDoesNotSubmit();
    void submitFailureKeepsObservedAuthorization();
    void foregroundNotificationsStillShowBannerAndPlaySound();
    void scheduleIntervalDeductsAuthorizationWait_data();
    void scheduleIntervalDeductsAuthorizationWait();
};

void AppleNotificationBackendTests::deniedThenReauthorizedQueriesAgainAndDelivers()
{
    int queryCount = 0;
    int submitCount = 0;
    AppleNotificationBackend backend(
        [&queryCount](AppleNotificationBackend::AuthorizationResultCallback callback) {
            ++queryCount;
            callback(queryCount > 1, QStringLiteral("系统通知权限不可用"));
        },
        [&submitCount](const QString&, const QString&, bool,
                       NotificationBackend::DeliveryCallback callback) {
            ++submitCount;
            callback(true, QString());
        });

    int callbackCount = 0;
    bool firstSuccess = true;
    backend.deliver(QStringLiteral("标题"), QStringLiteral("正文"), true,
                    [&callbackCount, &firstSuccess](bool success, const QString&) {
                        ++callbackCount;
                        firstSuccess = success;
                    });
    QCOMPARE(queryCount, 1);
    QCOMPARE(submitCount, 0);
    QCOMPARE(callbackCount, 1);
    QVERIFY(!firstSuccess);
    QVERIFY(!backend.isAuthorized());

    bool secondSuccess = false;
    backend.deliver(QStringLiteral("标题"), QStringLiteral("正文"), false,
                    [&callbackCount, &secondSuccess](bool success, const QString&) {
                        ++callbackCount;
                        secondSuccess = success;
                    });
    QCOMPARE(queryCount, 2);
    QCOMPARE(submitCount, 1);
    QCOMPARE(callbackCount, 2);
    QVERIFY(secondSuccess);
    QVERIFY(backend.isAuthorized());
}

void AppleNotificationBackendTests::authorizationQueryFailureDoesNotSubmit()
{
    int submitCount = 0;
    AppleNotificationBackend backend(
        [](AppleNotificationBackend::AuthorizationResultCallback callback) {
            callback(false, QStringLiteral("授权查询失败"));
        },
        [&submitCount](const QString&, const QString&, bool,
                       NotificationBackend::DeliveryCallback callback) {
            ++submitCount;
            callback(true, QString());
        });

    int callbackCount = 0;
    QString reason;
    backend.deliver(QStringLiteral("标题"), QStringLiteral("正文"), true,
                    [&callbackCount, &reason](bool, const QString& message) {
                        ++callbackCount;
                        reason = message;
                    });

    QCOMPARE(submitCount, 0);
    QCOMPARE(callbackCount, 1);
    QCOMPARE(reason, QStringLiteral("授权查询失败"));
    QVERIFY(!backend.isAuthorized());
}

void AppleNotificationBackendTests::submitFailureKeepsObservedAuthorization()
{
    AppleNotificationBackend backend(
        [](AppleNotificationBackend::AuthorizationResultCallback callback) {
            callback(true, QString());
        },
        [](const QString&, const QString&, bool, NotificationBackend::DeliveryCallback callback) {
            callback(false, QStringLiteral("投递失败"));
        });

    int callbackCount = 0;
    QString reason;
    bool success = true;
    backend.deliver(QStringLiteral("标题"), QStringLiteral("正文"), true,
                    [&callbackCount, &reason, &success](bool delivered, const QString& message) {
                        ++callbackCount;
                        success = delivered;
                        reason = message;
                    });

    QCOMPARE(callbackCount, 1);
    QVERIFY(!success);
    QCOMPARE(reason, QStringLiteral("投递失败"));
    QVERIFY(backend.isAuthorized());
}

void AppleNotificationBackendTests::foregroundNotificationsStillShowBannerAndPlaySound()
{
    // 阶段结束时应用默认会先把窗口拉到前台再发通知。系统对前台应用的通知默认静默，
    // 而投递回调照样报成功、本地提示音也就不补——整个提醒无声无息。
    // 这里直接调用委托的 willPresent 方法，确认前台也要求横幅和声音。
    const AppleNotificationBackend::ForegroundPresentation presentation =
        AppleNotificationBackend::foregroundPresentationForTesting();
    QVERIFY(presentation.handled);
    QVERIFY(presentation.banner);
    QVERIFY(presentation.list);
    QVERIFY(presentation.sound);
}

void AppleNotificationBackendTests::scheduleIntervalDeductsAuthorizationWait_data()
{
    // 保证权限查询等待从原触发间隔中扣除，耗尽期限后不能再预约未来提醒。
    QTest::addColumn<int>("originalSeconds");
    QTest::addColumn<qint64>("waitedNsecs");
    QTest::addColumn<double>("expectedInterval");
    QTest::newRow("没有等待") << 60 << qint64(0) << 60.0;
    QTest::newRow("等待整秒") << 60 << qint64(17000000000LL) << 43.0;
    QTest::newRow("等待不足一秒仍扣除") << 60 << qint64(250000000) << 59.75;
    QTest::newRow("恰好到点") << 60 << qint64(60000000000LL) << 0.0;
    QTest::newRow("超过到点") << 60 << qint64(61000000000LL) << 0.0;
    QTest::newRow("原期限已经到点") << 0 << qint64(0) << 0.0;
}

void AppleNotificationBackendTests::scheduleIntervalDeductsAuthorizationWait()
{
    // 保证预约只使用权限查询后真实剩余的秒数，0 明确表示过期而不是强行延长到一秒。
    QFETCH(int, originalSeconds);
    QFETCH(qint64, waitedNsecs);
    QFETCH(double, expectedInterval);
    QCOMPARE(AppleNotificationBackend::remainingScheduleInterval(originalSeconds, waitedNsecs), expectedInterval);
}

QTEST_APPLESS_MAIN(AppleNotificationBackendTests)
#include "AppleNotificationBackendTests.moc"
