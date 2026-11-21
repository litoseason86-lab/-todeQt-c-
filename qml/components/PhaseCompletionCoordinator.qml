import QtQuick

// 阶段完成协调器：只负责按设置把窗口置前。
// 系统通知、长休息文案与提示音兜底已下沉到 C++ PhaseCompletionNotifier（main.cpp 装配，QML 与 iPad 原生界面共用）。
Item {
    id: root

    required property var windowRef
    required property var focusTimerRef
    property var settingsRef: null

    visible: false

    Connections {
        target: root.focusTimerRef

        function onPhaseCompleted(phase) {
            if (!root.settingsRef || root.settingsRef.raiseOnPhaseComplete) {
                // 启用「关闭窗口隐藏到菜单栏」时，窗口处于 hide 状态；仅 raise/requestActivate 无法唤出，须先 show。
                if (root.windowRef && !root.windowRef.visible && typeof root.windowRef.show === "function") {
                    root.windowRef.show()
                }
                root.windowRef.raise()
                root.windowRef.requestActivate()
            }
        }
    }
}
