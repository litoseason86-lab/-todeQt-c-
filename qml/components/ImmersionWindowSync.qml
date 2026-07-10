import QtQuick

// 沉浸开关与窗口 visibility 的双向同步决策。main.qml 只执行返回值，
// 异步全屏过渡的分支全部收敛在这里，便于 offscreen 单测。
QtObject {
    id: sync

    property int preImmersiveVisibility: Window.Windowed
    // macOS 全屏切换期间会经过中间 visibility；首次观察到 FullScreen 前不能判为系统退出。
    property bool enteringFullScreen: false

    function visibilityForImmersiveChange(active, currentVisibility) {
        if (active) {
            preImmersiveVisibility = currentVisibility
            enteringFullScreen = currentVisibility !== Window.FullScreen
            return Window.FullScreen
        }

        // 用户在进入动画完成前取消时也必须复位护栏，否则后续系统退出无法识别。
        enteringFullScreen = false
        if (preImmersiveVisibility === Window.FullScreen) {
            return Window.FullScreen
        }
        return preImmersiveVisibility
    }

    function immersiveActiveAfterVisibilityChange(visibility, active) {
        if (visibility === Window.FullScreen) {
            enteringFullScreen = false
            return active
        }
        if (enteringFullScreen) {
            return active
        }
        return false
    }
}
