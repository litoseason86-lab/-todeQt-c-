import QtQuick
import QtQuick.Controls
import "."

ApplicationWindow {
    id: root

    // 这里是 QML 应用入口，只负责窗口尺寸和装载真正的主界面。
    visible: true
    width: 1024
    height: 768
    minimumWidth: 860
    minimumHeight: 620
    title: "番茄Todo"
    color: Theme.surface

    MainWindow {
        anchors.fill: parent
    }

    // 阶段结束只做视觉提醒：把窗口拉回前台，避免用户错过番茄钟切换。
    Connections {
        // 说明：qmllint 无法解析运行时注入的上下文属性，这里只对这一个引用放行。
        // qmllint disable unqualified
        target: typeof focusTimer === "undefined" ? null : focusTimer
        // qmllint enable unqualified

        function onPhaseCompleted(phase) {
            root.raise();
            root.requestActivate();
        }
    }
}
