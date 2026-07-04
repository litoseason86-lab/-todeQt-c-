import QtQuick
import ".."

// 全局轻提示条：连续 show 时只替换内容并重置计时，不排队，避免低优先级提示堆叠。
Rectangle {
    id: root

    objectName: "globalToast"

    property int displayDurationMs: 3000
    property bool shown: false

    function show(message) {
        label.text = message
        root.shown = true
        hideTimer.restart()
    }

    implicitWidth: label.implicitWidth + Theme.space24 * 2
    implicitHeight: 40
    radius: Theme.radiusLg
    color: Theme.inkStrong
    opacity: root.shown ? 0.92 : 0

    Behavior on opacity {
        NumberAnimation {
            duration: 180
            easing.type: Easing.OutQuad
        }
    }

    Text {
        id: label

        objectName: "toastText"
        anchors.centerIn: parent
        textFormat: Text.PlainText
        color: Theme.surface
        font.pixelSize: Theme.fontMd
    }

    Timer {
        id: hideTimer

        interval: root.displayDurationMs
        onTriggered: root.shown = false
    }
}
