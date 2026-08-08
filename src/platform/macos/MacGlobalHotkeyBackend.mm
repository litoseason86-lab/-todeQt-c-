#import "MacGlobalHotkeyBackend.h"

#import <Carbon/Carbon.h>

#import <QKeyCombination>
#import <QKeySequence>

#import <iterator>

namespace {

// 热键组的四字符签名。Carbon 用 (signature, id) 两段来标识热键，签名只要在本进程内
// 唯一即可；这里固定成 'ptdo'（PomodoroTodo）。
constexpr OSType kHotkeySignature = 'ptdo';

// Qt 键码 → macOS 虚拟键码。虚拟键码描述的是键盘上的物理位置，与当前输入法无关，
// 所以这张表对中文输入法同样成立。只覆盖能作为快捷键主键的按键；
// 表里没有的键会让 translate() 返回 false，上层据此提示用户换一个键。
bool virtualKeyFor(int qtKey, quint32* outKey)
{
    UInt32 code = 0;
    switch (qtKey) {
    case Qt::Key_A: code = kVK_ANSI_A; break;
    case Qt::Key_B: code = kVK_ANSI_B; break;
    case Qt::Key_C: code = kVK_ANSI_C; break;
    case Qt::Key_D: code = kVK_ANSI_D; break;
    case Qt::Key_E: code = kVK_ANSI_E; break;
    case Qt::Key_F: code = kVK_ANSI_F; break;
    case Qt::Key_G: code = kVK_ANSI_G; break;
    case Qt::Key_H: code = kVK_ANSI_H; break;
    case Qt::Key_I: code = kVK_ANSI_I; break;
    case Qt::Key_J: code = kVK_ANSI_J; break;
    case Qt::Key_K: code = kVK_ANSI_K; break;
    case Qt::Key_L: code = kVK_ANSI_L; break;
    case Qt::Key_M: code = kVK_ANSI_M; break;
    case Qt::Key_N: code = kVK_ANSI_N; break;
    case Qt::Key_O: code = kVK_ANSI_O; break;
    case Qt::Key_P: code = kVK_ANSI_P; break;
    case Qt::Key_Q: code = kVK_ANSI_Q; break;
    case Qt::Key_R: code = kVK_ANSI_R; break;
    case Qt::Key_S: code = kVK_ANSI_S; break;
    case Qt::Key_T: code = kVK_ANSI_T; break;
    case Qt::Key_U: code = kVK_ANSI_U; break;
    case Qt::Key_V: code = kVK_ANSI_V; break;
    case Qt::Key_W: code = kVK_ANSI_W; break;
    case Qt::Key_X: code = kVK_ANSI_X; break;
    case Qt::Key_Y: code = kVK_ANSI_Y; break;
    case Qt::Key_Z: code = kVK_ANSI_Z; break;

    case Qt::Key_0: code = kVK_ANSI_0; break;
    case Qt::Key_1: code = kVK_ANSI_1; break;
    case Qt::Key_2: code = kVK_ANSI_2; break;
    case Qt::Key_3: code = kVK_ANSI_3; break;
    case Qt::Key_4: code = kVK_ANSI_4; break;
    case Qt::Key_5: code = kVK_ANSI_5; break;
    case Qt::Key_6: code = kVK_ANSI_6; break;
    case Qt::Key_7: code = kVK_ANSI_7; break;
    case Qt::Key_8: code = kVK_ANSI_8; break;
    case Qt::Key_9: code = kVK_ANSI_9; break;

    case Qt::Key_F1: code = kVK_F1; break;
    case Qt::Key_F2: code = kVK_F2; break;
    case Qt::Key_F3: code = kVK_F3; break;
    case Qt::Key_F4: code = kVK_F4; break;
    case Qt::Key_F5: code = kVK_F5; break;
    case Qt::Key_F6: code = kVK_F6; break;
    case Qt::Key_F7: code = kVK_F7; break;
    case Qt::Key_F8: code = kVK_F8; break;
    case Qt::Key_F9: code = kVK_F9; break;
    case Qt::Key_F10: code = kVK_F10; break;
    case Qt::Key_F11: code = kVK_F11; break;
    case Qt::Key_F12: code = kVK_F12; break;

    // Return 与小键盘 Enter 在 Qt 里是两个键码，物理上用户不会区分，都映射到主 Return。
    case Qt::Key_Return:
    case Qt::Key_Enter: code = kVK_Return; break;
    case Qt::Key_Space: code = kVK_Space; break;
    case Qt::Key_Tab: code = kVK_Tab; break;
    case Qt::Key_Escape: code = kVK_Escape; break;
    // macOS 的 kVK_Delete 是退格键，kVK_ForwardDelete 才是向后删除，别按名字对。
    case Qt::Key_Backspace: code = kVK_Delete; break;
    case Qt::Key_Delete: code = kVK_ForwardDelete; break;

    case Qt::Key_Left: code = kVK_LeftArrow; break;
    case Qt::Key_Right: code = kVK_RightArrow; break;
    case Qt::Key_Up: code = kVK_UpArrow; break;
    case Qt::Key_Down: code = kVK_DownArrow; break;
    case Qt::Key_Home: code = kVK_Home; break;
    case Qt::Key_End: code = kVK_End; break;
    case Qt::Key_PageUp: code = kVK_PageUp; break;
    case Qt::Key_PageDown: code = kVK_PageDown; break;

    case Qt::Key_Minus: code = kVK_ANSI_Minus; break;
    case Qt::Key_Equal: code = kVK_ANSI_Equal; break;
    case Qt::Key_BracketLeft: code = kVK_ANSI_LeftBracket; break;
    case Qt::Key_BracketRight: code = kVK_ANSI_RightBracket; break;
    case Qt::Key_Backslash: code = kVK_ANSI_Backslash; break;
    case Qt::Key_Semicolon: code = kVK_ANSI_Semicolon; break;
    case Qt::Key_Apostrophe: code = kVK_ANSI_Quote; break;
    case Qt::Key_Comma: code = kVK_ANSI_Comma; break;
    case Qt::Key_Period: code = kVK_ANSI_Period; break;
    case Qt::Key_Slash: code = kVK_ANSI_Slash; break;
    case Qt::Key_QuoteLeft: code = kVK_ANSI_Grave; break;

    default:
        return false;
    }

    *outKey = static_cast<quint32>(code);
    return true;
}

OSStatus hotkeyEventHandler(EventHandlerCallRef /*nextHandler*/, EventRef event, void* userData)
{
    auto* backend = static_cast<MacGlobalHotkeyBackend*>(userData);
    if (!backend) {
        return noErr;
    }

    EventHotKeyID hotkeyId = {};
    const OSStatus status = GetEventParameter(event, kEventParamDirectObject,
                                              typeEventHotKeyID, nullptr,
                                              sizeof(hotkeyId), nullptr, &hotkeyId);
    if (status != noErr || hotkeyId.signature != kHotkeySignature) {
        return noErr;
    }

    // Carbon 的热键回调在主运行循环上触发，也就是 Qt 的 GUI 线程，可以直接同步转发。
    backend->dispatch(static_cast<quint32>(hotkeyId.id));
    return noErr;
}

} // namespace

bool MacGlobalHotkeyBackend::translate(const QKeySequence& sequence,
                                       quint32* virtualKey,
                                       quint32* carbonModifiers)
{
    if (!virtualKey || !carbonModifiers || sequence.count() != 1) {
        return false;
    }

    const QKeyCombination combination = sequence[0];
    quint32 code = 0;
    if (!virtualKeyFor(combination.key(), &code)) {
        return false;
    }

    const Qt::KeyboardModifiers modifiers = combination.keyboardModifiers();
    UInt32 carbon = 0;
    // Qt 在 macOS 上默认交换 Ctrl 与 Meta：QML/QKeySequence 里的 Ctrl 是 ⌘，Meta 才是 ⌃。
    if (modifiers.testFlag(Qt::ControlModifier)) {
        carbon |= cmdKey;
    }
    if (modifiers.testFlag(Qt::MetaModifier)) {
        carbon |= controlKey;
    }
    if (modifiers.testFlag(Qt::AltModifier)) {
        carbon |= optionKey;
    }
    if (modifiers.testFlag(Qt::ShiftModifier)) {
        carbon |= shiftKey;
    }

    // 不带修饰键的全局热键会抢走整个系统里那一个按键，任何输入框都别想再用它。
    if (carbon == 0 || carbon == static_cast<UInt32>(shiftKey)) {
        return false;
    }

    *virtualKey = code;
    *carbonModifiers = static_cast<quint32>(carbon);
    return true;
}

MacGlobalHotkeyBackend::MacGlobalHotkeyBackend() = default;

MacGlobalHotkeyBackend::~MacGlobalHotkeyBackend()
{
    unregisterAll();
    if (m_eventHandler) {
        RemoveEventHandler(static_cast<EventHandlerRef>(m_eventHandler));
        m_eventHandler = nullptr;
    }
}

void MacGlobalHotkeyBackend::setHandler(GlobalHotkeyHandler* handler)
{
    m_handler = handler;
}

void MacGlobalHotkeyBackend::ensureEventHandler()
{
    if (m_eventHandler) {
        return;
    }

    // 事件处理器只装一次，之后所有热键共用它；每次注册都装一个会导致同一次按键回调多次。
    EventTypeSpec eventType = { kEventClassKeyboard, kEventHotKeyPressed };
    EventHandlerRef handlerRef = nullptr;
    const OSStatus status = InstallApplicationEventHandler(&hotkeyEventHandler, 1, &eventType,
                                                          this, &handlerRef);
    if (status == noErr) {
        m_eventHandler = handlerRef;
    }
}

bool MacGlobalHotkeyBackend::registerHotkey(const QString& actionId, const QKeySequence& sequence)
{
    if (actionId.isEmpty()) {
        return false;
    }

    // 同一个动作重复注册视为「换键」：先把旧的从系统里摘掉，否则旧键位会一直留着生效。
    unregisterHotkey(actionId);

    quint32 virtualKey = 0;
    quint32 carbonModifiers = 0;
    if (!translate(sequence, &virtualKey, &carbonModifiers)) {
        return false;
    }

    ensureEventHandler();
    if (!m_eventHandler) {
        return false;
    }

    const quint32 hotkeyNumber = m_nextHotkeyNumber++;
    EventHotKeyID hotkeyId = {};
    hotkeyId.signature = kHotkeySignature;
    hotkeyId.id = static_cast<UInt32>(hotkeyNumber);

    EventHotKeyRef hotkeyRef = nullptr;
    const OSStatus status = RegisterEventHotKey(static_cast<UInt32>(virtualKey),
                                                static_cast<UInt32>(carbonModifiers),
                                                hotkeyId, GetApplicationEventTarget(),
                                                0, &hotkeyRef);
    // 系统或别的应用已经占用这组键时 RegisterEventHotKey 会返回错误，这里不重试、
    // 不降级，直接如实上报失败，让设置页把这一行标成「未生效」。
    if (status != noErr || !hotkeyRef) {
        return false;
    }

    m_hotkeys.insert(actionId, hotkeyRef);
    m_actionByNumber.insert(hotkeyNumber, actionId);
    return true;
}

void MacGlobalHotkeyBackend::unregisterHotkey(const QString& actionId)
{
    const auto it = m_hotkeys.constFind(actionId);
    if (it == m_hotkeys.constEnd()) {
        return;
    }

    UnregisterEventHotKey(static_cast<EventHotKeyRef>(it.value()));
    m_hotkeys.erase(it);

    // 编号表按值反查一次即可：动作数是个位数，不值得再维护一张反向索引。
    for (auto numberIt = m_actionByNumber.begin(); numberIt != m_actionByNumber.end(); ) {
        numberIt = (numberIt.value() == actionId) ? m_actionByNumber.erase(numberIt)
                                                  : std::next(numberIt);
    }
}

void MacGlobalHotkeyBackend::unregisterAll()
{
    for (auto it = m_hotkeys.constBegin(); it != m_hotkeys.constEnd(); ++it) {
        UnregisterEventHotKey(static_cast<EventHotKeyRef>(it.value()));
    }
    m_hotkeys.clear();
    m_actionByNumber.clear();
}

void MacGlobalHotkeyBackend::dispatch(quint32 hotkeyNumber)
{
    if (!m_handler) {
        return;
    }
    const auto it = m_actionByNumber.constFind(hotkeyNumber);
    if (it == m_actionByNumber.constEnd()) {
        return;
    }
    m_handler->handleGlobalHotkey(it.value());
}
