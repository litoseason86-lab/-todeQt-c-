#include <QKeySequence>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>

#include "../src/services/AppSettings.h"
#include "../src/services/ShortcutRegistry.h"

namespace {

// 假全局热键后端：不碰系统 API，只记录注册请求，并可以按需让某组键「被占用」。
// 有了它，全局热键的注册/注销/失败上报三条路径都能在后台无窗口地验证。
class FakeHotkeyBackend : public GlobalHotkeyBackend
{
public:
    // 键位以 PortableText 存放而不是 QKeySequence：QList 扩容时会「移动构造 + 析构」
    // 源对象，而 Qt 的 ~QKeySequence 不判空 d 指针，被移走的那个一析构就会崩。
    // 断言用字符串比对也更好读。
    struct Registration
    {
        QString actionId;
        QString sequence;
    };

    QVector<Registration> registered;
    QStringList unregistered;
    int unregisterAllCount = 0;
    GlobalHotkeyHandler* handler = nullptr;
    // 命中这组键（PortableText）就模拟「系统或别的应用已占用」。
    QString rejectSequence;

    void setHandler(GlobalHotkeyHandler* newHandler) override { handler = newHandler; }

    bool registerHotkey(const QString& actionId, const QKeySequence& sequence) override
    {
        // 复刻 GlobalHotkeyBackend 写明的约定：重复注册同一个 id 就是「换键」，
        // 后端负责先摘掉旧的。假后端若不照做，就会放过「换键后旧键位还生效」这类缺陷。
        dropRegistration(actionId);
        const QString portable = sequence.toString(QKeySequence::PortableText);
        if (!rejectSequence.isEmpty() && portable == rejectSequence) {
            return false;
        }
        registered.append({ actionId, portable });
        return true;
    }

    void unregisterHotkey(const QString& actionId) override
    {
        unregistered.append(actionId);
        dropRegistration(actionId);
    }

    void unregisterAll() override
    {
        ++unregisterAllCount;
        registered.clear();
    }

    // 当前是否有这个动作的有效注册。
    bool hasRegistration(const QString& actionId) const
    {
        for (const Registration& item : registered) {
            if (item.actionId == actionId) {
                return true;
            }
        }
        return false;
    }

    QString sequenceOf(const QString& actionId) const
    {
        for (const Registration& item : registered) {
            if (item.actionId == actionId) {
                return item.sequence;
            }
        }
        return QString();
    }

    int registrationCount(const QString& actionId) const
    {
        int count = 0;
        for (const Registration& item : registered) {
            if (item.actionId == actionId) {
                ++count;
            }
        }
        return count;
    }

private:
    void dropRegistration(const QString& actionId)
    {
        for (int i = registered.size() - 1; i >= 0; --i) {
            if (registered.at(i).actionId == actionId) {
                registered.removeAt(i);
            }
        }
    }
};

// 从 actions() 的快照里取出某个动作的一项字段。
QVariant fieldOf(const QVariantList& actions, const QString& actionId, const QString& field)
{
    for (const QVariant& entry : actions) {
        const QVariantMap map = entry.toMap();
        if (map.value(QStringLiteral("id")).toString() == actionId) {
            return map.value(field);
        }
    }
    return QVariant();
}

} // namespace

class ShortcutRegistryTests : public QObject
{
    Q_OBJECT

private slots:
    void init();
    void cleanup();

    void defaultsAreUsedWhenNothingOverridden();
    void inAppAndGlobalListsPartitionAllActions();
    void assignPersistsAndNotifies();
    void corruptOverrideFallsBackToTheDefault();
    void inAppActionsAcceptBareKeys();
    void bareTabAndEscapeStayReservedForKeyboardNavigation();
    void assignRejectsConflictWithAnotherActionInAnyScope();
    void assignRejectsSingleModifierGlobalHotkey();
    void disableIsDistinctFromResetToDefault();
    void resetAllRestoresEveryDefault();
    void normalizeDropsKeypadAndRejectsBareModifier();
    void settingBackendRegistersEveryGlobalAction();
    void reassigningGlobalActionReplacesRegistration();
    void rejectedGlobalRegistrationIsReportedAndMarked();
    void clearingBackendUnregistersEverything();
    void backendTriggerIsForwardedForKnownActionsOnly();
    void settingsReloadReRegistersGlobalHotkeys();

private:
    QTemporaryDir m_dir;
    AppSettings* m_settings = nullptr;
};

void ShortcutRegistryTests::init()
{
    // 每个用例一份独立的 ini，避免污染开发机的真实偏好。文件名必须按用例区分：
    // QTemporaryDir 是类成员、整个测试类只建一次，共用同一个文件会让前一个用例
    // 写下的覆盖值渗进后一个用例的「默认键位」断言。
    QVERIFY(m_dir.isValid());
    m_settings = new AppSettings(
        m_dir.filePath(QStringLiteral("shortcuts-%1.ini").arg(QTest::currentTestFunction())),
        this);
}

void ShortcutRegistryTests::cleanup()
{
    delete m_settings;
    m_settings = nullptr;
}

void ShortcutRegistryTests::defaultsAreUsedWhenNothingOverridden()
{
    ShortcutRegistry registry(m_settings);

    QCOMPARE(registry.sequenceFor(QStringLiteral("view.dashboard")), QStringLiteral("Ctrl+1"));
    // 全局热键出厂不占任何系统按键：任何预设都可能和用户已装的其他应用撞车，
    // 而撞车表现是「别的应用那个键失灵」，用户根本联想不到是本应用干的。
    QVERIFY(registry.sequenceFor(QStringLiteral("global.focusToggle")).isEmpty());
    QVERIFY(registry.sequenceFor(QStringLiteral("global.focusStop")).isEmpty());
    QVERIFY(registry.sequenceFor(QStringLiteral("global.toggleWindow")).isEmpty());
    QVERIFY(registry.sequenceFor(QStringLiteral("nope.missing")).isEmpty());

    const QVariantList actions = registry.actions();
    QVERIFY(!actions.isEmpty());
    QCOMPARE(fieldOf(actions, QStringLiteral("view.dashboard"), QStringLiteral("isDefault")).toBool(),
             true);
    QCOMPARE(fieldOf(actions, QStringLiteral("view.dashboard"), QStringLiteral("isDisabled")).toBool(),
             false);
    // 「有出厂键位」是界面区分「已停用」和「未设置」的依据。
    QCOMPARE(fieldOf(actions, QStringLiteral("view.dashboard"), QStringLiteral("hasDefault")).toBool(),
             true);
    QCOMPARE(fieldOf(actions, QStringLiteral("global.focusToggle"), QStringLiteral("hasDefault")).toBool(),
             false);
}

void ShortcutRegistryTests::inAppAndGlobalListsPartitionAllActions()
{
    ShortcutRegistry registry(m_settings);

    // 两个子列表必须正好把全量拆完，不重不漏；QML 侧靠 inAppActions 生成 Shortcut，
    // 漏一个就是某个快捷键悄悄失效。
    QCOMPARE(registry.inAppActions().size() + registry.globalActions().size(),
             registry.actions().size());
    QVERIFY(!registry.globalActions().isEmpty());

    for (const QVariant& entry : registry.globalActions()) {
        QVERIFY(entry.toMap().value(QStringLiteral("isGlobal")).toBool());
    }
    for (const QVariant& entry : registry.inAppActions()) {
        QVERIFY(!entry.toMap().value(QStringLiteral("isGlobal")).toBool());
    }
}

void ShortcutRegistryTests::assignPersistsAndNotifies()
{
    ShortcutRegistry registry(m_settings);
    QSignalSpy spy(&registry, &ShortcutRegistry::actionsChanged);

    QCOMPARE(registry.assign(QStringLiteral("task.new"), QStringLiteral("Ctrl+Shift+N")),
             QString());
    QCOMPARE(registry.sequenceFor(QStringLiteral("task.new")), QStringLiteral("Ctrl+Shift+N"));
    QVERIFY(spy.count() >= 1);

    // 覆盖值必须真的落盘：换一个只读同一份 ini 的实例仍应读到新键位。
    ShortcutRegistry reopened(m_settings);
    QCOMPARE(reopened.sequenceFor(QStringLiteral("task.new")), QStringLiteral("Ctrl+Shift+N"));
    QCOMPARE(fieldOf(reopened.actions(), QStringLiteral("task.new"),
                     QStringLiteral("isDefault")).toBool(), false);
}

void ShortcutRegistryTests::corruptOverrideFallsBackToTheDefault()
{
    // 设置文件可能被手工编辑，也可能来自格式不同的版本。AppSettings 里每个数值项
    // 都在读取时归一化坏值，键位这一项此前没有——坏值会被原样交给 QML，
    // 得到一个既显示不出键位、又不算「已停用」的行。
    QVERIFY(m_settings->setShortcutOverride(QStringLiteral("task.new"),
                                            QStringLiteral("这不是键位")));

    ShortcutRegistry registry(m_settings);
    QCOMPARE(registry.sequenceFor(QStringLiteral("task.new")), QStringLiteral("Ctrl+N"));
    QCOMPARE(fieldOf(registry.actions(), QStringLiteral("task.new"),
                     QStringLiteral("isDisabled")).toBool(), false);

    // 用户主动停用（空串）不是损坏，必须原样保留。
    QVERIFY(m_settings->setShortcutOverride(QStringLiteral("view.week"), QString()));
    ShortcutRegistry reopened(m_settings);
    QVERIFY(reopened.sequenceFor(QStringLiteral("view.week")).isEmpty());
}

void ShortcutRegistryTests::inAppActionsAcceptBareKeys()
{
    ShortcutRegistry registry(m_settings);

    // 应用内快捷键允许只用一个键（空格开始/暂停、数字键切页这类）。它不会吞掉正常打字：
    // 焦点在输入框上时，无修饰键的快捷键由 QML 侧整体让路。
    QCOMPARE(registry.assign(QStringLiteral("focus.toggle"), QStringLiteral("Space")), QString());
    QCOMPARE(registry.sequenceFor(QStringLiteral("focus.toggle")), QStringLiteral("Space"));
    QCOMPARE(registry.assign(QStringLiteral("task.new"), QStringLiteral("N")), QString());
    QCOMPARE(registry.assign(QStringLiteral("view.today"), QStringLiteral("Shift+T")), QString());

    // hasModifier 是 QML 决定「输入时要不要让路」的依据，必须跟着键位走。
    QCOMPARE(fieldOf(registry.actions(), QStringLiteral("task.new"),
                     QStringLiteral("hasModifier")).toBool(), false);
    QCOMPARE(fieldOf(registry.actions(), QStringLiteral("view.dashboard"),
                     QStringLiteral("hasModifier")).toBool(), true);
    // 只带 Shift 不算「带修饰键」：⇧T 打出的就是字符本身，同样得在输入时让路。
    QCOMPARE(fieldOf(registry.actions(), QStringLiteral("view.today"),
                     QStringLiteral("hasModifier")).toBool(), false);
}

void ShortcutRegistryTests::bareTabAndEscapeStayReservedForKeyboardNavigation()
{
    ShortcutRegistry registry(m_settings);

    // 这两个键即使在输入框里让路，也仍会瘫掉键盘操作本身，而且瘫掉之后
    // 没法再用键盘改回来：Tab 是焦点导航的唯一手段，Esc 是关闭弹窗的唯一手段。
    QVERIFY(!registry.assign(QStringLiteral("task.new"), QStringLiteral("Tab")).isEmpty());
    QVERIFY(!registry.assign(QStringLiteral("task.new"), QStringLiteral("Esc")).isEmpty());
    QCOMPARE(registry.sequenceFor(QStringLiteral("task.new")), QStringLiteral("Ctrl+N"));

    // 加上修饰键之后它们就不再和键盘导航抢，允许绑定。
    QCOMPARE(registry.assign(QStringLiteral("task.new"), QStringLiteral("Ctrl+Esc")), QString());

    // 空序列和纯修饰键仍然不是合法快捷键。
    QVERIFY(!registry.assign(QStringLiteral("view.week"), QString()).isEmpty());
}

void ShortcutRegistryTests::assignRejectsConflictWithAnotherActionInAnyScope()
{
    ShortcutRegistry registry(m_settings);

    const QString sameAsDashboard =
        registry.assign(QStringLiteral("task.new"), QStringLiteral("Ctrl+1"));
    QVERIFY(!sameAsDashboard.isEmpty());
    QVERIFY(sameAsDashboard.contains(QStringLiteral("仪表盘")));

    // 跨作用域也要挡：全局热键在系统层先吃掉按键，撞车的应用内快捷键根本收不到事件。
    // 全局键出厂为空，先让用户指定一组再验冲突。
    QCOMPARE(registry.assign(QStringLiteral("global.focusToggle"), QStringLiteral("Meta+Alt+P")),
             QString());
    const QString sameAsGlobal =
        registry.assign(QStringLiteral("task.new"), QStringLiteral("Meta+Alt+P"));
    QVERIFY(!sameAsGlobal.isEmpty());

    QCOMPARE(registry.conflictTitleFor(QStringLiteral("task.new"), QStringLiteral("Ctrl+2")),
             QStringLiteral("今日任务"));
    // 动作与自己不算冲突，否则「原样再保存一次」会被误判。
    QVERIFY(registry.conflictTitleFor(QStringLiteral("task.new"), QStringLiteral("Ctrl+N")).isEmpty());
}

void ShortcutRegistryTests::assignRejectsSingleModifierGlobalHotkey()
{
    ShortcutRegistry registry(m_settings);

    // 单修饰键的全局热键会把这个键从整个系统里抢走，拒绝并给出可执行的提示。
    const QString reason =
        registry.assign(QStringLiteral("global.focusStop"), QStringLiteral("Ctrl+E"));
    QVERIFY(!reason.isEmpty());
    // 拒绝后仍是出厂的「未设置」，不能留下半保存状态。
    QVERIFY(registry.sequenceFor(QStringLiteral("global.focusStop")).isEmpty());

    // 全局键同样不能用单键：它没有「焦点在输入框就让路」这层保护。
    QVERIFY(!registry.assign(QStringLiteral("global.focusStop"), QStringLiteral("E")).isEmpty());
    QVERIFY(registry.sequenceFor(QStringLiteral("global.focusStop")).isEmpty());

    // 同样是单修饰键，应用内动作则完全合法。
    QCOMPARE(registry.assign(QStringLiteral("task.new"), QStringLiteral("Ctrl+E")), QString());
}

void ShortcutRegistryTests::disableIsDistinctFromResetToDefault()
{
    ShortcutRegistry registry(m_settings);

    QCOMPARE(registry.disable(QStringLiteral("task.new")), QString());
    QVERIFY(registry.sequenceFor(QStringLiteral("task.new")).isEmpty());
    QCOMPARE(fieldOf(registry.actions(), QStringLiteral("task.new"),
                     QStringLiteral("isDisabled")).toBool(), true);
    // 停用状态必须跨实例保持，否则重启就「自己恢复」了。
    QVERIFY(ShortcutRegistry(m_settings).sequenceFor(QStringLiteral("task.new")).isEmpty());

    registry.resetToDefault(QStringLiteral("task.new"));
    QCOMPARE(registry.sequenceFor(QStringLiteral("task.new")), QStringLiteral("Ctrl+N"));

    // 停用的动作不占用键位，别的动作可以拿走它原来的键。
    QCOMPARE(registry.disable(QStringLiteral("task.new")), QString());
    QCOMPARE(registry.assign(QStringLiteral("view.goals"), QStringLiteral("Ctrl+N")), QString());
}

void ShortcutRegistryTests::resetAllRestoresEveryDefault()
{
    ShortcutRegistry registry(m_settings);

    QCOMPARE(registry.assign(QStringLiteral("task.new"), QStringLiteral("Ctrl+Shift+N")),
             QString());
    QCOMPARE(registry.disable(QStringLiteral("view.goals")), QString());

    registry.resetAll();

    QCOMPARE(registry.sequenceFor(QStringLiteral("task.new")), QStringLiteral("Ctrl+N"));
    QCOMPARE(registry.sequenceFor(QStringLiteral("view.goals")), QStringLiteral("Ctrl+8"));
    for (const QVariant& entry : registry.actions()) {
        QVERIFY(entry.toMap().value(QStringLiteral("isDefault")).toBool());
    }
}

void ShortcutRegistryTests::normalizeDropsKeypadAndRejectsBareModifier()
{
    ShortcutRegistry registry(m_settings);

    QCOMPARE(registry.normalize(Qt::Key_1, Qt::ControlModifier), QStringLiteral("Ctrl+1"));
    // 小键盘位不参与快捷键身份：同一个「1」不该因为按的是小键盘就变成另一组键。
    QCOMPARE(registry.normalize(Qt::Key_1, Qt::ControlModifier | Qt::KeypadModifier),
             QStringLiteral("Ctrl+1"));
    // 只按住修饰键时不能记成一个快捷键，否则一进录制态就立刻「录到」无法触发的组合。
    QVERIFY(registry.normalize(Qt::Key_Control, Qt::ControlModifier).isEmpty());
    QVERIFY(registry.normalize(Qt::Key_unknown, Qt::ControlModifier).isEmpty());
}

void ShortcutRegistryTests::settingBackendRegistersEveryGlobalAction()
{
    // 后端必须声明在注册表之前：栈上后声明的先析构，反过来写的话注册表析构时
    // 调 unregisterAll() 就会打到已经销毁的后端上（GlobalHotkeyBackend 的注释里
    // 写明了「后端要比注册表活得久，否则宿主必须先显式解绑」）。
    FakeHotkeyBackend backend;
    ShortcutRegistry registry(m_settings);

    registry.setGlobalBackend(&backend);

    QCOMPARE(backend.handler, static_cast<GlobalHotkeyHandler*>(&registry));
    // 出厂状态下一个系统热键都不注册：全新安装的应用不该抢走任何系统按键。
    QVERIFY(backend.registered.isEmpty());

    // 用户主动指定之后才注册。
    QCOMPARE(registry.assign(QStringLiteral("global.focusToggle"), QStringLiteral("Meta+Alt+P")),
             QString());
    QVERIFY(backend.hasRegistration(QStringLiteral("global.focusToggle")));
    // 应用内动作绝不能被注册成系统热键，否则会在所有应用里抢走 ⌘N 这种常用键。
    QVERIFY(!backend.hasRegistration(QStringLiteral("task.new")));
}

void ShortcutRegistryTests::reassigningGlobalActionReplacesRegistration()
{
    // 后端必须声明在注册表之前：栈上后声明的先析构，反过来写的话注册表析构时
    // 调 unregisterAll() 就会打到已经销毁的后端上（GlobalHotkeyBackend 的注释里
    // 写明了「后端要比注册表活得久，否则宿主必须先显式解绑」）。
    FakeHotkeyBackend backend;
    ShortcutRegistry registry(m_settings);
    registry.setGlobalBackend(&backend);

    QCOMPARE(registry.assign(QStringLiteral("global.toggleWindow"),
                             QStringLiteral("Meta+Alt+W")), QString());

    QCOMPARE(backend.sequenceOf(QStringLiteral("global.toggleWindow")),
             QStringLiteral("Meta+Alt+W"));
    // 换键之后只能剩一条登记，否则系统里会同时留着新旧两组键都能触发。
    QCOMPARE(backend.registrationCount(QStringLiteral("global.toggleWindow")), 1);

    // 停用只注销、不再注册。
    QCOMPARE(registry.disable(QStringLiteral("global.toggleWindow")), QString());
    QVERIFY(!backend.hasRegistration(QStringLiteral("global.toggleWindow")));
}

void ShortcutRegistryTests::rejectedGlobalRegistrationIsReportedAndMarked()
{
    // 后端必须声明在注册表之前：栈上后声明的先析构，反过来写的话注册表析构时
    // 调 unregisterAll() 就会打到已经销毁的后端上（GlobalHotkeyBackend 的注释里
    // 写明了「后端要比注册表活得久，否则宿主必须先显式解绑」）。
    FakeHotkeyBackend backend;
    ShortcutRegistry registry(m_settings);
    backend.rejectSequence = QStringLiteral("Meta+Alt+K");
    registry.setGlobalBackend(&backend);

    QSignalSpy spy(&registry, &ShortcutRegistry::globalRegistrationFailed);
    // 系统拒绝时键位仍然保存：界面把这一行标成「未生效」比悄悄变回旧值更好理解。
    QCOMPARE(registry.assign(QStringLiteral("global.focusStop"), QStringLiteral("Meta+Alt+K")),
             QString());

    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(0).toString(), QStringLiteral("global.focusStop"));
    QCOMPARE(registry.sequenceFor(QStringLiteral("global.focusStop")),
             QStringLiteral("Meta+Alt+K"));
    QCOMPARE(fieldOf(registry.actions(), QStringLiteral("global.focusStop"),
                     QStringLiteral("registered")).toBool(), false);

    // 改成一组能注册的键后，未生效标记必须消失。
    QCOMPARE(registry.assign(QStringLiteral("global.focusStop"), QStringLiteral("Meta+Alt+J")),
             QString());
    QCOMPARE(fieldOf(registry.actions(), QStringLiteral("global.focusStop"),
                     QStringLiteral("registered")).toBool(), true);
}

void ShortcutRegistryTests::clearingBackendUnregistersEverything()
{
    // 后端必须声明在注册表之前：栈上后声明的先析构，反过来写的话注册表析构时
    // 调 unregisterAll() 就会打到已经销毁的后端上（GlobalHotkeyBackend 的注释里
    // 写明了「后端要比注册表活得久，否则宿主必须先显式解绑」）。
    FakeHotkeyBackend backend;
    ShortcutRegistry registry(m_settings);
    registry.setGlobalBackend(&backend);

    registry.setGlobalBackend(nullptr);

    QCOMPARE(backend.unregisterAllCount, 1);
    // 解绑后系统热键回调不能再打回来。
    QCOMPARE(backend.handler, static_cast<GlobalHotkeyHandler*>(nullptr));
    QVERIFY(backend.registered.isEmpty());
}

void ShortcutRegistryTests::backendTriggerIsForwardedForKnownActionsOnly()
{
    // 后端必须声明在注册表之前：栈上后声明的先析构，反过来写的话注册表析构时
    // 调 unregisterAll() 就会打到已经销毁的后端上（GlobalHotkeyBackend 的注释里
    // 写明了「后端要比注册表活得久，否则宿主必须先显式解绑」）。
    FakeHotkeyBackend backend;
    ShortcutRegistry registry(m_settings);
    registry.setGlobalBackend(&backend);

    QSignalSpy spy(&registry, &ShortcutRegistry::globalActionTriggered);

    backend.handler->handleGlobalHotkey(QStringLiteral("global.focusToggle"));
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.first().at(0).toString(), QStringLiteral("global.focusToggle"));

    // 未知 id 静默忽略：后端可能残留上一次配置的热键，不该让 QML 收到无法处理的动作。
    backend.handler->handleGlobalHotkey(QStringLiteral("nope.missing"));
    QCOMPARE(spy.count(), 1);
}

void ShortcutRegistryTests::settingsReloadReRegistersGlobalHotkeys()
{
    // 后端必须声明在注册表之前：栈上后声明的先析构，反过来写的话注册表析构时
    // 调 unregisterAll() 就会打到已经销毁的后端上（GlobalHotkeyBackend 的注释里
    // 写明了「后端要比注册表活得久，否则宿主必须先显式解绑」）。
    FakeHotkeyBackend backend;
    ShortcutRegistry registry(m_settings);
    registry.setGlobalBackend(&backend);
    QCOMPARE(registry.assign(QStringLiteral("global.toggleWindow"), QStringLiteral("Meta+Alt+W")),
             QString());
    backend.registered.clear();

    // 数据恢复会整体覆盖设置文件并触发 reload；此时系统里注册的还是旧库的键位，
    // 必须整体重注册一遍。
    m_settings->reload();

    QCOMPARE(backend.sequenceOf(QStringLiteral("global.toggleWindow")),
             QStringLiteral("Meta+Alt+W"));
}

QTEST_MAIN(ShortcutRegistryTests)
#include "ShortcutRegistryTests.moc"
