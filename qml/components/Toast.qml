import QtQuick
import ".."

// 全局轻提示条：连续 show 时只替换内容并重置计时，不排队，避免低优先级提示堆叠。
Rectangle {
    id: root

    objectName: "globalToast"

    property int displayDurationMs: 3000
    property bool shown: false
    property string actionText: ""
    property var actionCallback: null
    // 带撤销动作的提示需要给用户更长反应窗口，与延迟删除提交窗口一致。
    property int actionDisplayDurationMs: 5000
    readonly property int yOffset: root.shown ? 0 : 12

    function show(message, action, callback) {
        label.text = message
        root.actionText = action === undefined || action === null ? "" : String(action)
        root.actionCallback = callback === undefined ? null : callback
        hideTimer.interval = root.actionText.length > 0 ? root.actionDisplayDurationMs : root.displayDurationMs
        root.shown = true
        hideTimer.restart()
    }

    function triggerAction() {
        // 先取出回调再关闭提示，避免关闭过程里的外部状态更新把回调清掉。
        var callback = root.actionCallback
        root.actionCallback = null
        root.actionText = ""
        root.shown = false
        hideTimer.stop()
        if (callback) {
            callback()
        }
    }

    implicitWidth: contentRow.implicitWidth + Theme.space24 * 2
    implicitHeight: 40
    radius: Theme.radiusLg
    color: Theme.inkStrong
    opacity: root.shown ? 0.92 : 0
    visible: root.shown || opacity > 0.001
    enabled: root.shown

    Component.onCompleted: root.y = root.yOffset

    onYOffsetChanged: {
        toastMoveAnimation.to = root.yOffset
        toastMoveAnimation.restart()
    }

    Behavior on opacity {
        NumberAnimation {
            duration: 180
            easing.type: Easing.OutQuad
        }
    }

    NumberAnimation {
        id: toastMoveAnimation
        objectName: "toastMoveAnimation"

        target: root
        property: "y"
        duration: 180
        easing.type: Easing.OutQuad
    }

    Row {
        id: contentRow

        anchors.centerIn: parent
        spacing: Theme.space12

        Text {
            id: label

            objectName: "toastText"
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            color: Theme.surface
            font.pixelSize: Theme.fontMd
        }

        Text {
            objectName: "toastActionButton"
            anchors.verticalCenter: parent.verticalCenter
            visible: root.actionText.length > 0
            text: root.actionText
            textFormat: Text.PlainText
            color: Theme.accentSoft
            font.pixelSize: Theme.fontMd
            font.weight: Font.DemiBold

            TapHandler {
                enabled: root.shown && root.actionText.length > 0
                onTapped: root.triggerAction()
            }
        }
    }

    Timer {
        id: hideTimer

        interval: root.displayDurationMs
        onTriggered: {
            root.shown = false
            root.actionCallback = null
            root.actionText = ""
        }
    }
}
