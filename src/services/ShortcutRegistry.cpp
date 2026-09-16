#include "ShortcutRegistry.h"

#include "AppSettings.h"

#include <QDebug>
#include <QKeyCombination>

namespace {

// 判断某个键码本身是不是修饰键。只按住 ⌘ 不应该被记录成一个快捷键，
// 否则用户一进录制态就会立刻「录到」一个无法触发的组合。
bool isModifierKey(int key)
{
    switch (key) {
    case Qt::Key_Shift:
    case Qt::Key_Control:
    case Qt::Key_Meta:
    case Qt::Key_Alt:
    case Qt::Key_AltGr:
    case Qt::Key_CapsLock:
    case Qt::Key_NumLock:
    case Qt::Key_ScrollLock:
    case Qt::Key_Super_L:
    case Qt::Key_Super_R:
    case Qt::Key_Hyper_L:
    case Qt::Key_Hyper_R:
        return true;
    default:
        return false;
    }
}

// 数出组合里有几个「真」修饰键。Shift 不单独计数：它改变的是字符本身，
// 单靠 Shift 的组合（如 ⇧A）会把普通打字吞掉。
int strongModifierCount(Qt::KeyboardModifiers modifiers)
{
    int count = 0;
    if (modifiers.testFlag(Qt::ControlModifier))
        ++count;
    if (modifiers.testFlag(Qt::MetaModifier))
        ++count;
    if (modifiers.testFlag(Qt::AltModifier))
        ++count;
    return count;
}

QString portableTextOf(const QKeySequence& sequence)
{
    return sequence.isEmpty() ? QString() : sequence.toString(QKeySequence::PortableText);
}

} // namespace

const QVector<ShortcutActionDefinition>& ShortcutRegistry::definitions()
{
    // 默认键位遵循 macOS 习惯：应用内一律 ⌘ 打头（PortableText 里的 Ctrl 在 macOS 上就是 ⌘）。
    //
    // 全局热键的默认值一律留空 = 出厂不占任何系统按键。这不是偷懒：全局热键抢的是整个
    // 系统的按键，任何一组预设都可能和用户已经装着的其他应用撞车，而撞车的表现是
    // 「别的应用那个键突然失灵」，用户很难联想到是番茄Todo干的。改成用户在设置里主动
    // 指定，谁也不会被动踩雷。应用内快捷键没有这个问题——它们只在本应用前台时生效。
    static const QVector<ShortcutActionDefinition> table = {
        { QStringLiteral("view.dashboard"), QStringLiteral("仪表盘"),
          QStringLiteral("导航"), QStringLiteral("Ctrl+1"), false },
        { QStringLiteral("view.today"), QStringLiteral("今日任务"),
          QStringLiteral("导航"), QStringLiteral("Ctrl+2"), false },
        { QStringLiteral("view.focus"), QStringLiteral("专注"),
          QStringLiteral("导航"), QStringLiteral("Ctrl+3"), false },
        { QStringLiteral("view.week"), QStringLiteral("本周计划"),
          QStringLiteral("导航"), QStringLiteral("Ctrl+4"), false },
        { QStringLiteral("view.month"), QStringLiteral("本月目标"),
          QStringLiteral("导航"), QStringLiteral("Ctrl+5"), false },
        { QStringLiteral("view.stats"), QStringLiteral("统计"),
          QStringLiteral("导航"), QStringLiteral("Ctrl+6"), false },
        { QStringLiteral("view.countdown"), QStringLiteral("倒计时"),
          QStringLiteral("导航"), QStringLiteral("Ctrl+7"), false },
        { QStringLiteral("view.goals"), QStringLiteral("长期目标"),
          QStringLiteral("导航"), QStringLiteral("Ctrl+8"), false },

        { QStringLiteral("task.new"), QStringLiteral("新建任务"),
          QStringLiteral("任务"), QStringLiteral("Ctrl+N"), false },

        { QStringLiteral("focus.toggle"), QStringLiteral("开始 / 暂停专注"),
          QStringLiteral("专注"), QStringLiteral("Ctrl+Return"), false },
        { QStringLiteral("focus.stop"), QStringLiteral("结束当前专注"),
          QStringLiteral("专注"), QStringLiteral("Ctrl+Shift+Return"), false },
        { QStringLiteral("focus.immersive"), QStringLiteral("进入 / 退出沉浸模式"),
          QStringLiteral("专注"), QStringLiteral("Ctrl+Shift+F"), false },

        // 知识缺口捕获。它不是切页动作，与 2026-09-03「切页快捷键只覆盖 8 页」那条决策无关。
        // 捕获框自己做得很轻（非模态、一行字、回车即存），但此前只有两颗鼠标按钮能打开它，
        // 其中专注页那颗按既定决策常态透明。真实场景是「在别的窗口做题，发现一块不懂」，
        // 此刻应用在后台——没有键盘入口，这个功能的代价就超过了「算了回头再说」。
        //
        // 默认键位不用 ⌘⇧N：那是「新建任务」的近邻，而两者的产物完全不同
        // （任务必须有日期，知识缺口的常态恰恰是还定不了什么时候处理），
        // 挨在一起反而诱导按错。⌘⇧K 空着，K 取自 knowledge。
        { QStringLiteral("gap.capture"), QStringLiteral("记一笔（知识缺口）"),
          QStringLiteral("任务"), QStringLiteral("Ctrl+Shift+K"), false },

        { QStringLiteral("window.toggleSidebar"), QStringLiteral("显示 / 隐藏侧栏"),
          QStringLiteral("窗口"), QStringLiteral("Ctrl+\\"), false },
        { QStringLiteral("window.settings"), QStringLiteral("打开设置"),
          QStringLiteral("窗口"), QStringLiteral("Ctrl+,"), false },
        { QStringLiteral("window.shortcutHelp"), QStringLiteral("快捷键速查"),
          QStringLiteral("窗口"), QStringLiteral("Ctrl+/"), false },

        { QStringLiteral("global.focusToggle"), QStringLiteral("开始 / 暂停专注（全局）"),
          QStringLiteral("全局"), QString(), true },
        { QStringLiteral("global.focusStop"), QStringLiteral("结束当前专注（全局）"),
          QStringLiteral("全局"), QString(), true },
        { QStringLiteral("global.toggleWindow"), QStringLiteral("召回 / 隐藏主窗口（全局）"),
          QStringLiteral("全局"), QString(), true },
        { QStringLiteral("global.captureGap"), QStringLiteral("记一笔（全局）"),
          QStringLiteral("全局"), QString(), true },
    };
    return table;
}

ShortcutRegistry* ShortcutRegistry::instance()
{
    static ShortcutRegistry registry(AppSettings::instance());
    return &registry;
}

ShortcutRegistry::ShortcutRegistry(AppSettings* settings, QObject* parent)
    : QObject(parent)
    , m_settings(settings)
{
    if (m_settings) {
        // 数据恢复会整体覆盖设置文件；重读后键位可能全变，必须重新注册全局热键，
        // 否则系统里留着的是旧库的键位。
        connect(m_settings, &AppSettings::shortcutOverridesChanged,
                this, [this]() {
            if (m_writingOwnChange) {
                return;
            }
            syncAllGlobalHotkeys();
            emit actionsChanged();
        });
    }
}

ShortcutRegistry::~ShortcutRegistry()
{
    // 析构顺序不可依赖：主动解除关联并注销，避免系统热键回调打到半销毁的对象上。
    setGlobalBackend(nullptr);
}

void ShortcutRegistry::setGlobalBackend(GlobalHotkeyBackend* backend)
{
    if (m_backend == backend)
        return;

    if (m_backend) {
        m_backend->unregisterAll();
        m_backend->setHandler(nullptr);
    }

    m_backend = backend;
    m_failedGlobalActions.clear();

    if (m_backend) {
        m_backend->setHandler(this);
        syncAllGlobalHotkeys();
    }
    emit actionsChanged();
}

const ShortcutActionDefinition* ShortcutRegistry::findDefinition(const QString& actionId) const
{
    for (const ShortcutActionDefinition& definition : definitions()) {
        if (definition.id == actionId)
            return &definition;
    }
    return nullptr;
}

QString ShortcutRegistry::requestedSequence(const ShortcutActionDefinition& definition,
                                            bool* explicitChoice) const
{
    *explicitChoice = false;
    // 「有覆盖键」才读覆盖值——空串是合法覆盖，表示用户主动停用了这个动作，
    // 和「从没改过、用默认」是两种不同的状态。
    if (m_settings && m_settings->hasShortcutOverride(definition.id)) {
        const QString override = m_settings->shortcutOverride(definition.id);
        if (override.isEmpty()) {
            *explicitChoice = true;
            return QString();
        }
        // 非空但不合规 = 配置损坏（手工编辑过、来自格式不同的版本，或被改过的备份）。
        // 与 AppSettings 里所有数值项一致：读取时就挡住坏值，回退到默认键位，
        // 而不是把它交给 QML 或注册进系统——保存时拦下的组合，读取时同样不能放行。
        const QKeySequence parsed =
            QKeySequence::fromString(override, QKeySequence::PortableText);
        const QString invalidReason = validateFor(definition, parsed);
        if (invalidReason.isEmpty()) {
            *explicitChoice = true;
            return portableTextOf(parsed);
        }
        qWarning() << "忽略不合规的快捷键配置:" << definition.id << override << invalidReason;
    }
    return definition.defaultSequence;
}

QHash<QString, ShortcutRegistry::Resolution> ShortcutRegistry::resolveAll() const
{
    struct Request
    {
        const ShortcutActionDefinition* definition;
        QString sequence;
        bool explicitChoice;
    };

    QVector<Request> requests;
    QHash<QString, Resolution> result;
    for (const ShortcutActionDefinition& definition : definitions()) {
        bool explicitChoice = false;
        const QString sequence = requestedSequence(definition, &explicitChoice);
        requests.append({ &definition, sequence, explicitChoice });
        result.insert(definition.id, Resolution());
    }

    // 生效键位不能重复：两个同键的应用内 Shortcut 在 Qt 里判为歧义，两个都不触发；
    // 和全局热键撞车时，按键在系统层就被全局热键吃掉。所以按两轮分配：
    // 先分用户亲手选的键，再分出厂默认——升级新增的默认键撞上老用户的自定义键时，
    // 让路的是默认键。同一轮里按动作清单顺序先到先得，结果与读取顺序无关、每次都一样。
    // 比较用规范化后的键位（同一组键可能有不同写法），返回值仍保持原来的文本。
    QHash<QString, QString> ownerTitles;
    for (const bool explicitPass : { true, false }) {
        for (const Request& request : requests) {
            if (request.explicitChoice != explicitPass || request.sequence.isEmpty()) {
                continue;
            }
            const QString identity = portableTextOf(
                QKeySequence::fromString(request.sequence, QKeySequence::PortableText));
            const auto owner = ownerTitles.constFind(identity);
            if (owner != ownerTitles.constEnd()) {
                result[request.definition->id].conflictTitle = owner.value();
                continue;
            }
            ownerTitles.insert(identity, request.definition->title);
            result[request.definition->id].sequence = request.sequence;
        }
    }
    return result;
}

QString ShortcutRegistry::sequenceFor(const QString& actionId) const
{
    if (!findDefinition(actionId))
        return QString();
    return resolveAll().value(actionId).sequence;
}

QString ShortcutRegistry::displaySequenceFor(const QString& actionId) const
{
    const QString portable = sequenceFor(actionId);
    if (portable.isEmpty())
        return QString();
    return QKeySequence::fromString(portable, QKeySequence::PortableText)
        .toString(QKeySequence::NativeText);
}

QVariantMap ShortcutRegistry::describe(const ShortcutActionDefinition& definition,
                                       const Resolution& resolution) const
{
    const QString portable = resolution.sequence;
    const QKeySequence sequence = QKeySequence::fromString(portable, QKeySequence::PortableText);
    const QKeySequence defaultSequence =
        QKeySequence::fromString(definition.defaultSequence, QKeySequence::PortableText);

    QVariantMap map;
    map.insert(QStringLiteral("id"), definition.id);
    map.insert(QStringLiteral("title"), definition.title);
    map.insert(QStringLiteral("group"), definition.group);
    map.insert(QStringLiteral("sequence"), portable);
    map.insert(QStringLiteral("display"),
               portable.isEmpty() ? QString() : sequence.toString(QKeySequence::NativeText));
    map.insert(QStringLiteral("defaultSequence"), definition.defaultSequence);
    map.insert(QStringLiteral("defaultDisplay"),
               defaultSequence.toString(QKeySequence::NativeText));
    map.insert(QStringLiteral("isDefault"), portable == definition.defaultSequence);
    // 「没有出厂键位」和「有出厂键位但被用户停用」在界面上要说成两句话：
    // 前者是全局热键的正常初始态（等用户指定），后者才是用户关掉了一个原本能用的键。
    map.insert(QStringLiteral("hasDefault"), !definition.defaultSequence.isEmpty());
    // 无修饰键的快捷键在文本输入时必须让路，否则绑了「N」就再也打不出这个字母。
    // 判定放在这里做一次，QML 侧不再自己解析键位字符串。
    map.insert(QStringLiteral("hasModifier"),
               !portable.isEmpty() && sequence.count() == 1
                   && strongModifierCount(sequence[0].keyboardModifiers()) > 0);
    map.insert(QStringLiteral("isGlobal"), definition.global);
    // 想用的键被别的动作占着而让路。界面要说「被谁占用」，不能显示成用户自己停用的。
    map.insert(QStringLiteral("conflictTitle"), resolution.conflictTitle);
    map.insert(QStringLiteral("isDisabled"), portable.isEmpty());
    // 只有全局动作才可能「已保存但系统没接受」；应用内快捷键由 Qt 自己派发，不存在这一状态。
    map.insert(QStringLiteral("registered"),
               !definition.global || portable.isEmpty()
                   || !m_failedGlobalActions.contains(definition.id));
    return map;
}

QVariantList ShortcutRegistry::actions() const
{
    const QHash<QString, Resolution> resolved = resolveAll();
    QVariantList list;
    for (const ShortcutActionDefinition& definition : definitions())
        list.append(describe(definition, resolved.value(definition.id)));
    return list;
}

QVariantList ShortcutRegistry::inAppActions() const
{
    const QHash<QString, Resolution> resolved = resolveAll();
    QVariantList list;
    for (const ShortcutActionDefinition& definition : definitions()) {
        if (!definition.global)
            list.append(describe(definition, resolved.value(definition.id)));
    }
    return list;
}

QVariantList ShortcutRegistry::globalActions() const
{
    const QHash<QString, Resolution> resolved = resolveAll();
    QVariantList list;
    for (const ShortcutActionDefinition& definition : definitions()) {
        if (definition.global)
            list.append(describe(definition, resolved.value(definition.id)));
    }
    return list;
}

QStringList ShortcutRegistry::groups() const
{
    QStringList result;
    for (const ShortcutActionDefinition& definition : definitions()) {
        if (!result.contains(definition.group))
            result.append(definition.group);
    }
    return result;
}

QString ShortcutRegistry::validate(const QKeySequence& sequence)
{
    if (sequence.isEmpty())
        return QStringLiteral("没有识别到有效的按键组合");
    // 只支持单段组合键。多段序列（如 ⌘K 再按 ⌘S）在这个应用里没有使用场景，
    // 允许它反而会让冲突判定和全局热键注册都变复杂。
    if (sequence.count() != 1)
        return QStringLiteral("暂不支持连续按键，请用单个组合键");

    const QKeyCombination combination = sequence[0];
    const int key = combination.key();
    if (key == 0 || key == Qt::Key_unknown || isModifierKey(key))
        return QStringLiteral("请按下一个主键，只按修饰键不算快捷键");

    // 应用内快捷键允许不带修饰键（空格开始/暂停、数字键切页这类）。
    // 它不会吞掉正常打字：焦点在文本输入框上时，无修饰键的快捷键会整体让路
    // （见 AppShortcuts.textInputFocused），带 ⌘/⌃/⌥ 的组合则照常可用。
    //
    // 但这三个键即使让路也仍会瘫掉键盘操作本身，且瘫掉之后就没法再用键盘改回来：
    // Tab 是焦点导航的唯一手段，Escape 是关闭弹窗的唯一手段。
    if (strongModifierCount(combination.keyboardModifiers()) < 1) {
        if (key == Qt::Key_Tab || key == Qt::Key_Backtab)
            return QStringLiteral("Tab 要留给焦点切换，请换一个键或加上修饰键");
        if (key == Qt::Key_Escape)
            return QStringLiteral("Esc 要留给关闭弹窗，请换一个键或加上修饰键");
    }

    return QString();
}

QString ShortcutRegistry::validateFor(const ShortcutActionDefinition& definition,
                                      const QKeySequence& sequence)
{
    const QString invalidReason = validate(sequence);
    if (!invalidReason.isEmpty())
        return invalidReason;
    // 全局热键抢的是整个系统的按键，而且没有「焦点在输入框就让路」这层保护——
    // 单修饰键组合（如 ⌘E、⌘C）会让别的应用里那个键直接失灵。
    if (definition.global && strongModifierCount(sequence[0].keyboardModifiers()) < 2)
        return QStringLiteral("全局快捷键至少要两个修饰键（如 ⌃⌥P），避免抢走其他应用的常用按键");
    return QString();
}

QString ShortcutRegistry::normalize(int key, int modifiers) const
{
    // 小键盘位与输入法组切换位不参与快捷键身份：同一个「1」不该因为按的是小键盘就变成另一组键。
    Qt::KeyboardModifiers mods(static_cast<Qt::KeyboardModifiers>(modifiers));
    mods &= ~Qt::KeypadModifier;
    mods &= ~Qt::GroupSwitchModifier;

    if (key == 0 || key == Qt::Key_unknown || isModifierKey(key))
        return QString();

    const QKeySequence sequence(QKeyCombination(mods, static_cast<Qt::Key>(key)));
    return portableTextOf(sequence);
}

QString ShortcutRegistry::conflictTitleFor(const QString& actionId,
                                           const QString& portableSequence) const
{
    if (portableSequence.isEmpty())
        return QString();

    // 冲突跨作用域判定：全局热键会在系统层先把按键吃掉，与它撞车的应用内快捷键
    // 根本收不到事件，所以「全局」和「应用内」不能各自成一套命名空间。
    const QKeySequence candidate =
        QKeySequence::fromString(portableSequence, QKeySequence::PortableText);
    const QHash<QString, Resolution> resolved = resolveAll();
    for (const ShortcutActionDefinition& definition : definitions()) {
        if (definition.id == actionId)
            continue;
        const QString existing = resolved.value(definition.id).sequence;
        if (existing.isEmpty())
            continue;
        if (QKeySequence::fromString(existing, QKeySequence::PortableText) == candidate)
            return definition.title;
    }
    return QString();
}

QString ShortcutRegistry::assign(const QString& actionId, const QString& portableSequence)
{
    const ShortcutActionDefinition* definition = findDefinition(actionId);
    if (!definition)
        return QStringLiteral("未知的快捷键动作");
    if (!m_settings)
        return QStringLiteral("设置不可用，无法保存快捷键");

    const QKeySequence sequence =
        QKeySequence::fromString(portableSequence, QKeySequence::PortableText);
    const QString invalidReason = validateFor(*definition, sequence);
    if (!invalidReason.isEmpty())
        return invalidReason;

    const QString conflict = conflictTitleFor(actionId, portableTextOf(sequence));
    if (!conflict.isEmpty())
        return QStringLiteral("这组键已分配给「") + conflict + QStringLiteral("」");

    m_writingOwnChange = true;
    const bool saved = m_settings->setShortcutOverride(actionId, portableTextOf(sequence));
    m_writingOwnChange = false;
    if (!saved)
        return QStringLiteral("无法保存快捷键，请检查设置文件权限后重试");

    if (definition->global)
        syncGlobalHotkey(*definition);
    emit actionsChanged();

    // 注册失败不回滚：键位已按用户意愿存下，界面会把这一行标成「系统未接受」，
    // 用户可以直接再改一组，而不是面对一个悄悄变回旧值的输入框。
    return QString();
}

QString ShortcutRegistry::disable(const QString& actionId)
{
    const ShortcutActionDefinition* definition = findDefinition(actionId);
    if (!definition)
        return QStringLiteral("未知的快捷键动作");
    if (!m_settings)
        return QStringLiteral("设置不可用，无法保存快捷键");

    m_writingOwnChange = true;
    const bool saved = m_settings->setShortcutOverride(actionId, QString());
    m_writingOwnChange = false;
    if (!saved)
        return QStringLiteral("无法保存快捷键，请检查设置文件权限后重试");

    if (definition->global)
        syncGlobalHotkey(*definition);
    emit actionsChanged();
    return QString();
}

QString ShortcutRegistry::resetToDefault(const QString& actionId)
{
    const ShortcutActionDefinition* definition = findDefinition(actionId);
    if (!definition)
        return QStringLiteral("未知的快捷键动作");
    if (!m_settings)
        return QStringLiteral("设置不可用，无法保存快捷键");

    // 出厂键可能早被别的动作占用（用户停用本动作后把这组键改给了别人）。
    // 照样清掉覆盖值的话，本动作会因让路而变成「暂未设置」——提示「已恢复默认」却按不出来。
    const QString conflict = conflictTitleFor(actionId, definition->defaultSequence);
    if (!conflict.isEmpty())
        return QStringLiteral("出厂键位已分配给「") + conflict + QStringLiteral("」，请先修改那一项");

    m_writingOwnChange = true;
    const bool saved = m_settings->clearShortcutOverride(actionId);
    m_writingOwnChange = false;
    if (!saved)
        return QStringLiteral("无法恢复默认键位，请检查设置文件权限后重试");

    if (definition->global)
        syncGlobalHotkey(*definition);
    emit actionsChanged();
    return QString();
}

QString ShortcutRegistry::resetAll()
{
    if (!m_settings)
        return QStringLiteral("设置不可用，无法保存快捷键");

    m_writingOwnChange = true;
    const bool saved = m_settings->clearAllShortcutOverrides();
    m_writingOwnChange = false;
    if (!saved)
        return QStringLiteral("无法恢复默认键位，请检查设置文件权限后重试");

    syncAllGlobalHotkeys();
    emit actionsChanged();
    return QString();
}

void ShortcutRegistry::syncGlobalHotkey(const ShortcutActionDefinition& definition)
{
    if (!definition.global || !m_backend)
        return;

    m_failedGlobalActions.removeAll(definition.id);

    const QString portable = sequenceFor(definition.id);
    if (portable.isEmpty()) {
        // 停用：只注销，不视为失败。
        m_backend->unregisterHotkey(definition.id);
        return;
    }

    const QKeySequence sequence =
        QKeySequence::fromString(portable, QKeySequence::PortableText);
    if (m_backend->registerHotkey(definition.id, sequence))
        return;

    m_failedGlobalActions.append(definition.id);
    emit globalRegistrationFailed(definition.id, definition.title);
}

void ShortcutRegistry::syncAllGlobalHotkeys()
{
    if (!m_backend)
        return;
    for (const ShortcutActionDefinition& definition : definitions()) {
        if (definition.global)
            syncGlobalHotkey(definition);
    }
}

void ShortcutRegistry::handleGlobalHotkey(const QString& actionId)
{
    if (!findDefinition(actionId))
        return;
    emit globalActionTriggered(actionId);
}
