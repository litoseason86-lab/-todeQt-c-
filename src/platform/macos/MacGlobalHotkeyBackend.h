#ifndef MACGLOBALHOTKEYBACKEND_H
#define MACGLOBALHOTKEYBACKEND_H

#include "../../services/GlobalHotkeyBackend.h"

#include <QHash>
#include <QString>
#include <QtGlobal>

// macOS 全局热键实现，底层是 Carbon 的 RegisterEventHotKey。
//
// 为什么不用 NSEvent 的全局事件监听：那条路需要用户在「隐私与安全性 → 辅助功能」里
// 给应用授权，一个本地番茄钟为此索要辅助功能权限并不合理。RegisterEventHotKey 不需要
// 任何授权，代价是只能注册「修饰键 + 单个主键」这一种形式，正好也是我们唯一需要的形式。
//
// 头文件保持纯 C++（Carbon 类型全部藏在 .mm 里的 void* 后面），main.cpp 可直接包含。
class MacGlobalHotkeyBackend : public GlobalHotkeyBackend
{
public:
    MacGlobalHotkeyBackend();
    ~MacGlobalHotkeyBackend() override;
    MacGlobalHotkeyBackend(const MacGlobalHotkeyBackend&) = delete;
    MacGlobalHotkeyBackend& operator=(const MacGlobalHotkeyBackend&) = delete;
    MacGlobalHotkeyBackend(MacGlobalHotkeyBackend&&) = delete;
    MacGlobalHotkeyBackend& operator=(MacGlobalHotkeyBackend&&) = delete;

    void setHandler(GlobalHotkeyHandler* handler) override;
    bool registerHotkey(const QString& actionId, const QKeySequence& sequence) override;
    void unregisterHotkey(const QString& actionId) override;
    void unregisterAll() override;

    // 把 Qt 的键序列翻译成 macOS 虚拟键码与 Carbon 修饰位。返回 false 表示这组键
    // 无法映射（键不在支持表里，或没带任何修饰键）。公开出来是为了能在不碰系统热键
    // 注册的前提下单测这段翻译——它是整个实现里唯一容易写错的部分。
    //
    // 修饰键对应关系按 Qt 在 macOS 上的默认约定（Ctrl 与 Meta 是交换的）：
    //   Qt::ControlModifier → cmdKey(⌘)   Qt::MetaModifier → controlKey(⌃)
    //   Qt::AltModifier     → optionKey(⌥) Qt::ShiftModifier → shiftKey(⇧)
    static bool translate(const QKeySequence& sequence,
                          quint32* virtualKey,
                          quint32* carbonModifiers);

    // 供事件回调使用：把平台热键编号翻回动作 id 并转发给处理者。
    void dispatch(quint32 hotkeyNumber);

private:
    void ensureEventHandler();

    void* m_eventHandler = nullptr;              // EventHandlerRef
    QHash<QString, void*> m_hotkeys;             // actionId → EventHotKeyRef
    QHash<quint32, QString> m_actionByNumber;    // 平台热键编号 → actionId
    quint32 m_nextHotkeyNumber = 1;
    GlobalHotkeyHandler* m_handler = nullptr;
};

#endif // MACGLOBALHOTKEYBACKEND_H
