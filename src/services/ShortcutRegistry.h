#ifndef SHORTCUTREGISTRY_H
#define SHORTCUTREGISTRY_H

#include <QKeySequence>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVector>

#include "GlobalHotkeyBackend.h"

class AppSettings;

// 一个可绑定快捷键的动作的静态定义。默认键位写死在代码里，用户改动只以「覆盖值」
// 的形式存进 AppSettings，因此升级时改默认键位对没自定义过的用户立刻生效。
struct ShortcutActionDefinition
{
    QString id;                  // 稳定标识，同时是设置里的存储键，改名等于丢用户配置
    QString title;               // 设置页显示的中文名
    QString group;               // 分组标题（导航 / 任务 / 专注 / 窗口 / 全局）
    QString defaultSequence;     // QKeySequence 的 PortableText，例如 "Ctrl+1"
    bool global = false;         // true = 系统级热键，应用在后台也触发
};

// 快捷键的唯一事实源：动作清单、默认键位、用户覆盖、冲突判定、全局热键注册全在这里。
// 平台无关——真正调用系统 API 的部分通过 GlobalHotkeyBackend 注入。
//
// macOS 修饰键的对应关系（Qt 默认会交换 Ctrl 与 Meta，容易记反，这里写死一次）：
//   Qt::ControlModifier → ⌘ Command
//   Qt::MetaModifier    → ⌃ Control
//   Qt::AltModifier     → ⌥ Option
//   Qt::ShiftModifier   → ⇧ Shift
// 所以 PortableText 里的 "Ctrl+1" 在 macOS 上显示为 ⌘1，"Meta+Alt+P" 显示为 ⌃⌥P。
class ShortcutRegistry : public QObject, public GlobalHotkeyHandler
{
    Q_OBJECT
    // 三个列表都是给 QML 的只读快照：actions 全量，另两个按作用域切分，
    // 应用内那份直接喂给 MainWindow 的 Shortcut 生成器。
    Q_PROPERTY(QVariantList actions READ actions NOTIFY actionsChanged)
    Q_PROPERTY(QVariantList inAppActions READ inAppActions NOTIFY actionsChanged)
    Q_PROPERTY(QVariantList globalActions READ globalActions NOTIFY actionsChanged)
    Q_PROPERTY(QStringList groups READ groups NOTIFY actionsChanged)

public:
    static ShortcutRegistry* instance();
    explicit ShortcutRegistry(AppSettings* settings, QObject* parent = nullptr);
    ~ShortcutRegistry() override;

    // 后端不转移所有权。设置后立即把当前所有全局动作注册一遍；传 nullptr 先注销全部，
    // 让宿主可以在自己析构前主动断开（不依赖栈上声明顺序）。
    void setGlobalBackend(GlobalHotkeyBackend* backend);

    QVariantList actions() const;
    QVariantList inAppActions() const;
    QVariantList globalActions() const;
    QStringList groups() const;

    // 当前生效的键位（PortableText）。空串表示这个动作已被用户停用。
    Q_INVOKABLE QString sequenceFor(const QString& actionId) const;
    // 面向用户显示的键位（macOS 上是 ⌘⇧F 这种符号形式）。
    Q_INVOKABLE QString displaySequenceFor(const QString& actionId) const;

    // 改键。返回空串表示成功，否则是可以直接显示给用户的中文失败原因
    // （非法组合 / 与别的动作冲突 / 全局热键被系统占用）。
    Q_INVOKABLE QString assign(const QString& actionId, const QString& portableSequence);
    // 停用某个动作：写入空串覆盖值，与「恢复默认」是两件事。
    Q_INVOKABLE QString disable(const QString& actionId);
    Q_INVOKABLE void resetToDefault(const QString& actionId);
    Q_INVOKABLE void resetAll();

    // 把 QML 按键事件的 key + modifiers 规范成 PortableText；无法接受的组合返回空串。
    Q_INVOKABLE QString normalize(int key, int modifiers) const;
    // 这组键当前被哪个动作占用；没有占用返回空串。设置页用它做输入时的即时提示。
    Q_INVOKABLE QString conflictTitleFor(const QString& actionId, const QString& portableSequence) const;

    // GlobalHotkeyHandler：后端在 GUI 线程回调，这里只做一次转发。
    void handleGlobalHotkey(const QString& actionId) override;

signals:
    void actionsChanged();
    // 全局热键被按下。窗口与计时相关的落实动作都在 QML 侧，这里只广播意图。
    void globalActionTriggered(const QString& actionId);
    // 系统拒绝注册（键被别的应用占用）。设置页据此把该行标红，而不是假装改键成功。
    void globalRegistrationFailed(const QString& actionId, const QString& title);

private:
    static const QVector<ShortcutActionDefinition>& definitions();
    const ShortcutActionDefinition* findDefinition(const QString& actionId) const;
    QVariantMap describe(const ShortcutActionDefinition& definition) const;
    // 校验一组键能不能作为快捷键：必须带 ⌘/⌃/⌥ 之一，且主键不能是修饰键本身。
    // 返回空串表示合法，否则是中文原因。
    static QString validate(const QKeySequence& sequence);
    // 全局动作的注册/注销收敛在这里；后端缺席时是安全的空操作。
    void syncGlobalHotkey(const ShortcutActionDefinition& definition);
    void syncAllGlobalHotkeys();

    AppSettings* m_settings;
    GlobalHotkeyBackend* m_backend = nullptr;
    // 自己写设置时会同步收到 shortcutOverridesChanged。没有这个标记，一次改键会走两条
    // 同步路径（定向同步 + 信号触发的全量重同步），把不相关的热键也来回注销一遍，
    // 失败上报也会重复发一次。只有外部来源（数据恢复后的 reload）才需要整体重同步。
    bool m_writingOwnChange = false;
    // 系统拒绝注册的动作。它们在设置页要显示为「未生效」，不能靠重读设置推断出来。
    QStringList m_failedGlobalActions;
};

#endif // SHORTCUTREGISTRY_H
