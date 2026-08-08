#ifndef GLOBALHOTKEYBACKEND_H
#define GLOBALHOTKEYBACKEND_H

#include <QKeySequence>
#include <QString>

// 「全局快捷键」指应用不在前台时也能触发的系统级热键（macOS 上由 Carbon 的
// RegisterEventHotKey 提供）。这一对接口把它拆成平台无关的两半，业务层只依赖这里，
// 真正碰系统 API 的代码全部留在 src/platform/macos，测试可以注入假后端。

// 热键触发后的处理者。后端只负责「这组键被按下了」，动作语义由实现方决定。
class GlobalHotkeyHandler
{
public:
    virtual ~GlobalHotkeyHandler() = default;
    // 由后端在系统热键被按下时调用；约定在 GUI 线程调用，实现方可以直接发信号。
    virtual void handleGlobalHotkey(const QString& actionId) = 0;
};

// 平台后端接口。actionId 是注册的唯一键：重复注册同一个 id 视为「换键」，
// 后端必须先注销旧的再注册新的，避免同一动作在系统里留下两组热键。
class GlobalHotkeyBackend
{
public:
    virtual ~GlobalHotkeyBackend() = default;

    // 处理者不转移所有权。传 nullptr 表示解除关联（宿主析构前必须调用一次，
    // 否则系统热键回调可能打到已销毁的对象上）。
    virtual void setHandler(GlobalHotkeyHandler* handler) = 0;

    // 返回 false 表示这组键无法注册：可能是键位被系统或别的应用占用，
    // 也可能是该组合无法映射到平台键码。调用方据此提示用户换一组，而不是静默失败。
    virtual bool registerHotkey(const QString& actionId, const QKeySequence& sequence) = 0;

    virtual void unregisterHotkey(const QString& actionId) = 0;
    virtual void unregisterAll() = 0;
};

#endif // GLOBALHOTKEYBACKEND_H
