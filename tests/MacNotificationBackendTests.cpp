#include <QtTest>

#include "../src/platform/macos/MacNotificationBackend.h"

class MacNotificationBackendTests : public QObject
{
    Q_OBJECT

private slots:
    void deniedThenReauthorizedQueriesAgainAndDelivers();
    void authorizationQueryFailureDoesNotSubmit();
    void submitFailureKeepsObservedAuthorization();
};

void MacNotificationBackendTests::deniedThenReauthorizedQueriesAgainAndDelivers()
{
    int queryCount = 0;
    int submitCount = 0;
    MacNotificationBackend backend(
        [&queryCount](MacNotificationBackend::AuthorizationResultCallback callback) {
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

void MacNotificationBackendTests::authorizationQueryFailureDoesNotSubmit()
{
    int submitCount = 0;
    MacNotificationBackend backend(
        [](MacNotificationBackend::AuthorizationResultCallback callback) {
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

void MacNotificationBackendTests::submitFailureKeepsObservedAuthorization()
{
    MacNotificationBackend backend(
        [](MacNotificationBackend::AuthorizationResultCallback callback) {
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

QTEST_APPLESS_MAIN(MacNotificationBackendTests)
#include "MacNotificationBackendTests.moc"
