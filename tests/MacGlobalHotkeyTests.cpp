#include <QKeySequence>
#include <QtTest>

#include <Carbon/Carbon.h>

#include "../src/platform/macos/MacGlobalHotkeyBackend.h"

// 只测 Qt 键序列 → macOS 虚拟键码/Carbon 修饰位的翻译。这段是整个全局热键实现里
// 唯一容易写错又不需要真的向系统注册就能验证的部分；注册本身涉及系统状态，
// 交给 ShortcutRegistryTests 里的假后端覆盖。
class MacGlobalHotkeyTests : public QObject
{
    Q_OBJECT

private slots:
    void ctrlMapsToCommandAndMetaMapsToControl();
    void defaultGlobalSequenceTranslates();
    void lettersDigitsAndNamedKeysTranslate();
    void unmappedKeyIsRejected();
    void sequenceWithoutStrongModifierIsRejected();
    void multiStepSequenceIsRejected();
};

void MacGlobalHotkeyTests::ctrlMapsToCommandAndMetaMapsToControl()
{
    quint32 key = 0;
    quint32 modifiers = 0;

    // Qt 在 macOS 上默认交换 Ctrl 与 Meta。这条断言就是把那个约定钉死：
    // 写反的话全局热键会注册到完全不同的一组物理按键上，而且不会有任何报错。
    QVERIFY(MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Ctrl+P")),
                                              &key, &modifiers));
    QCOMPARE(modifiers, static_cast<quint32>(cmdKey));

    QVERIFY(MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Meta+P")),
                                              &key, &modifiers));
    QCOMPARE(modifiers, static_cast<quint32>(controlKey));

    QVERIFY(MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Alt+P")),
                                              &key, &modifiers));
    QCOMPARE(modifiers, static_cast<quint32>(optionKey));
}

void MacGlobalHotkeyTests::defaultGlobalSequenceTranslates()
{
    quint32 key = 0;
    quint32 modifiers = 0;

    // 出厂默认的三组全局热键必须都能翻译，否则用户装上就发现全局键不工作。
    QVERIFY(MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Meta+Alt+P")),
                                              &key, &modifiers));
    QCOMPARE(key, static_cast<quint32>(kVK_ANSI_P));
    QCOMPARE(modifiers, static_cast<quint32>(controlKey | optionKey));

    QVERIFY(MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Meta+Alt+E")),
                                              &key, &modifiers));
    QCOMPARE(key, static_cast<quint32>(kVK_ANSI_E));

    QVERIFY(MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Meta+Alt+T")),
                                              &key, &modifiers));
    QCOMPARE(key, static_cast<quint32>(kVK_ANSI_T));
}

void MacGlobalHotkeyTests::lettersDigitsAndNamedKeysTranslate()
{
    quint32 key = 0;
    quint32 modifiers = 0;

    QVERIFY(MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Ctrl+1")),
                                              &key, &modifiers));
    QCOMPARE(key, static_cast<quint32>(kVK_ANSI_1));

    QVERIFY(MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Ctrl+Space")),
                                              &key, &modifiers));
    QCOMPARE(key, static_cast<quint32>(kVK_Space));

    QVERIFY(MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Ctrl+Return")),
                                              &key, &modifiers));
    QCOMPARE(key, static_cast<quint32>(kVK_Return));

    // macOS 的 kVK_Delete 其实是退格键；映射反了会让「⌘⌫」落到向后删除上。
    QVERIFY(MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Ctrl+Backspace")),
                                              &key, &modifiers));
    QCOMPARE(key, static_cast<quint32>(kVK_Delete));

    QVERIFY(MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Ctrl+Del")),
                                              &key, &modifiers));
    QCOMPARE(key, static_cast<quint32>(kVK_ForwardDelete));

    QVERIFY(MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Ctrl+F1")),
                                              &key, &modifiers));
    QCOMPARE(key, static_cast<quint32>(kVK_F1));

    QVERIFY(MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Ctrl+,")),
                                              &key, &modifiers));
    QCOMPARE(key, static_cast<quint32>(kVK_ANSI_Comma));
}

void MacGlobalHotkeyTests::unmappedKeyIsRejected()
{
    quint32 key = 0;
    quint32 modifiers = 0;

    // 表里没有的键必须如实返回失败，让上层提示用户换键，而不是注册到一个错误的键码上。
    QVERIFY(!MacGlobalHotkeyBackend::translate(QKeySequence(QKeyCombination(
                                                   Qt::ControlModifier, Qt::Key_Insert)),
                                               &key, &modifiers));
    QVERIFY(!MacGlobalHotkeyBackend::translate(QKeySequence(QKeyCombination(
                                                   Qt::ControlModifier, Qt::Key_MediaPlay)),
                                               &key, &modifiers));
}

void MacGlobalHotkeyTests::sequenceWithoutStrongModifierIsRejected()
{
    quint32 key = 0;
    quint32 modifiers = 0;

    // 不带 ⌘/⌃/⌥ 的全局热键会把这个键从整个系统里抢走，任何输入框都别想再用它。
    QVERIFY(!MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("P")),
                                               &key, &modifiers));
    QVERIFY(!MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Shift+P")),
                                               &key, &modifiers));
}

void MacGlobalHotkeyTests::multiStepSequenceIsRejected()
{
    quint32 key = 0;
    quint32 modifiers = 0;

    // Carbon 只支持「修饰键 + 单个主键」，连续按键序列必须在这里被挡住。
    QVERIFY(!MacGlobalHotkeyBackend::translate(QKeySequence(QStringLiteral("Ctrl+K, Ctrl+S")),
                                               &key, &modifiers));
    QVERIFY(!MacGlobalHotkeyBackend::translate(QKeySequence(), &key, &modifiers));
}

QTEST_MAIN(MacGlobalHotkeyTests)
#include "MacGlobalHotkeyTests.moc"
