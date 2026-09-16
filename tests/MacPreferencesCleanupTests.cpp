#include <QDir>
#include <QFile>
#include <QtTest>

#include <CoreFoundation/CoreFoundation.h>

#include "../src/platform/macos/MacPreferencesCleanup.h"

// 旧版恢复失败回滚会把系统全局偏好钉进本应用的偏好域。清理只能删「与全局域值完全相同」
// 的键：删掉后读到的值不变；本应用自己的键、以及值不同的键都必须原样保留。
//
// 用例写的是一个专用的测试偏好域，前后都清空，系统全局域只读不写。
// 域名固定而不按进程号区分：偏好守护进程是异步落盘的，删掉 plist 之后它可能又写回一个
// 空文件；按进程号命名的话每跑一次就多留一个，固定名字最多只留这一个空文件。
class MacPreferencesCleanupTests : public QObject
{
    Q_OBJECT

private slots:
    void init();
    void cleanup();
    void removesOnlyValuesIdenticalToTheGlobalDomain();
    void emptyDomainIsIgnored();

private:
    void setValue(const QString& key, CFPropertyListRef value);
    bool hasValue(const QString& key) const;

    QString m_domain;
};

void MacPreferencesCleanupTests::init()
{
    m_domain = QStringLiteral("com.pomodorotodo.cleanup-tests");
    // 上一次运行中途崩溃可能留下键，先清空再开始。
    cleanup();
}

void MacPreferencesCleanupTests::cleanup()
{
    CFStringRef appId = m_domain.toCFString();
    CFArrayRef keys = CFPreferencesCopyKeyList(appId, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys != nullptr) {
        CFPreferencesSetMultiple(nullptr, keys, appId, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(keys);
    }
    CFPreferencesSynchronize(appId, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(appId);
    QFile::remove(QDir::home().filePath(
        QStringLiteral("Library/Preferences/%1.plist").arg(m_domain)));
}

void MacPreferencesCleanupTests::setValue(const QString& key, CFPropertyListRef value)
{
    CFStringRef appId = m_domain.toCFString();
    CFStringRef cfKey = key.toCFString();
    CFPreferencesSetValue(cfKey, value, appId, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(appId, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(cfKey);
    CFRelease(appId);
}

bool MacPreferencesCleanupTests::hasValue(const QString& key) const
{
    CFStringRef appId = m_domain.toCFString();
    CFStringRef cfKey = key.toCFString();
    CFPropertyListRef value = CFPreferencesCopyValue(
        cfKey, appId, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    const bool present = value != nullptr;
    if (value != nullptr) {
        CFRelease(value);
    }
    CFRelease(cfKey);
    CFRelease(appId);
    return present;
}

void MacPreferencesCleanupTests::removesOnlyValuesIdenticalToTheGlobalDomain()
{
    CFPropertyListRef globalLocale = CFPreferencesCopyValue(
        CFSTR("AppleLocale"), kCFPreferencesAnyApplication,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (globalLocale == nullptr) {
        QSKIP("这台机器的全局偏好域里没有 AppleLocale，无法构造「被钉住的系统值」");
    }

    // 旧版回滚写进来的系统值：和全局域一模一样。
    setValue(QStringLiteral("AppleLocale"), globalLocale);
    CFRelease(globalLocale);
    // 同名但值不同：可能是有意的覆盖（比如只给本应用换语言），不能删。
    // 这个键的系统约定类型是字符串数组，写成别的类型会被偏好系统丢弃。
    CFStringRef language = CFSTR("xx-pomodoro-test");
    CFArrayRef languages = CFArrayCreate(nullptr, reinterpret_cast<const void**>(&language), 1,
                                         &kCFTypeArrayCallBacks);
    setValue(QStringLiteral("AppleLanguages"), languages);
    CFRelease(languages);
    // 本应用自己的键：全局域里没有。
    const int minutes = 42;
    CFNumberRef number = CFNumberCreate(nullptr, kCFNumberIntType, &minutes);
    setValue(QStringLiteral("focus.workMinutes"), number);
    CFRelease(number);

    QCOMPARE(MacPreferencesCleanup::removeValuesPinnedFromGlobalDomain(m_domain), 1);

    QVERIFY2(!hasValue(QStringLiteral("AppleLocale")), "与全局域相同的系统值没有被清掉");
    QVERIFY2(hasValue(QStringLiteral("AppleLanguages")), "值不同的同名键被误删");
    QVERIFY2(hasValue(QStringLiteral("focus.workMinutes")), "本应用自己的设置被误删");

    // 再跑一次什么都不删：清理是幂等的。
    QCOMPARE(MacPreferencesCleanup::removeValuesPinnedFromGlobalDomain(m_domain), 0);
}

void MacPreferencesCleanupTests::emptyDomainIsIgnored()
{
    QCOMPARE(MacPreferencesCleanup::removeValuesPinnedFromGlobalDomain(QString()), 0);
}

QTEST_APPLESS_MAIN(MacPreferencesCleanupTests)
#include "MacPreferencesCleanupTests.moc"
