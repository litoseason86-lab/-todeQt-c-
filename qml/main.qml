import QtQuick
import QtQuick.Controls
import "."
import "components"

ApplicationWindow {
    id: root

    // 这里是 QML 应用入口，只负责窗口尺寸和装载真正的主界面。
    visible: true
    width: 1024
    height: 768
    minimumWidth: 860
    minimumHeight: 620
    title: mainContent.windowTitleText
    color: Theme.surface

    MainWindow {
        id: mainContent

        anchors.fill: parent
    }

    onClosing: function(close) {
        // 撤销窗口尚未结束时关闭应用，必须先同步提交；失败则阻止退出，避免任务下次启动“复活”。
        if (!mainContent.commitPendingDelete()) {
            close.accepted = false
        }
    }

    ImmersionWindowSync {
        id: immersionSync
    }

    Connections {
        target: mainContent

        function onFocusImmersiveActiveChanged() {
            root.visibility = immersionSync.visibilityForImmersiveChange(
                        mainContent.focusImmersiveActive, root.visibility)
        }
    }

    // 系统手势或绿灯退出原生全屏时，反向归零沉浸事实源。
    onVisibilityChanged: {
        if (!immersionSync.immersiveActiveAfterVisibilityChange(
                    root.visibility, mainContent.focusImmersiveActive)
                && mainContent.focusImmersiveActive) {
            mainContent.focusImmersiveActive = false
        }
    }

    // 阶段结束只做视觉提醒：把窗口拉回前台，避免用户错过番茄钟切换。
    Connections {
        // 说明：qmllint 无法解析运行时注入的上下文属性，这里只对这一个引用放行。
        // qmllint disable unqualified
        target: typeof focusTimer === "undefined" ? null : focusTimer
        // qmllint enable unqualified

        function onPhaseCompleted(phase) {
            // 置前提醒默认开启；关掉后仅靠提示音，不打断当前窗口。缺少 appSettings 时保持原行为。
            // qmllint disable unqualified
            if (typeof appSettings === "undefined" || !appSettings || appSettings.raiseOnPhaseComplete) {
                root.raise();
                root.requestActivate();
            }
            // 提示音默认开启；缺少 appSettings 时保持默认行为，不阻断原有提醒。
            if (typeof appSettings === "undefined" || !appSettings || appSettings.soundEnabled) {
                if (typeof phaseSoundService !== "undefined" && phaseSoundService) {
                    phaseSoundService.playPhaseCompleteChime();
                }
            }
            // qmllint enable unqualified
        }
    }
}
