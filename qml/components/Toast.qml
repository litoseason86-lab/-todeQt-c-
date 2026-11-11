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

    // 只在提示条当前挂着的正是这个动作时收起。发起方的动作已经失效（比如删除已经落库、
    // 撤销不再可能），但提示条可能早被别的提示顶掉——那时不能把无关的提示误关。
    function dismissAction(callback) {
        if (!callback || root.actionCallback !== callback) {
            return
        }
        root.actionCallback = null
        root.actionText = ""
        root.shown = false
        hideTimer.stop()
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

    // 自然宽度只从未换行文字和动作计算，不反向读取 Row 的受限宽度，避免父子尺寸绑定成环。
    readonly property real actionWidth: actionButton.visible ? actionButton.implicitWidth + contentRow.spacing : 0
    readonly property real naturalWidth: label.implicitWidth + root.actionWidth + Theme.space24 * 2
    implicitWidth: parent ? Math.min(root.naturalWidth, Math.max(0, parent.width - Theme.space24 * 2)) : root.naturalWidth
    // 保留原单行 40px 的上下留白；两行文字增加的高度直接加到提示条，不挤压动作。
    implicitHeight: Math.max(40, contentRow.implicitHeight + 40 - Math.ceil(labelMetrics.height))
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
            duration: Theme.reduceMotion ? 0 : 180
            easing.type: Easing.OutQuad
        }
    }

    NumberAnimation {
        id: toastMoveAnimation
        objectName: "toastMoveAnimation"

        target: root
        property: "y"
        duration: Theme.reduceMotion ? 0 : 180
        easing.type: Easing.OutQuad
    }

    TextMetrics {
        id: labelMetrics
        font: label.font
        text: label.text
    }

    Row {
        id: contentRow

        anchors.centerIn: parent
        spacing: Theme.space12

        Text {
            id: label

            objectName: "toastText"
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, Math.max(0, root.width - Theme.space24 * 2 - root.actionWidth))
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            textFormat: Text.PlainText
            Accessible.name: text
            color: Theme.surface
            font.pixelSize: Theme.fontMd
        }

        Text {
            id: actionButton

            objectName: "toastActionButton"
            anchors.verticalCenter: parent.verticalCenter
            visible: root.actionText.length > 0
            text: root.actionText
            textFormat: Text.PlainText
            color: Theme.accentSoft
            font.pixelSize: Theme.fontMd
            font.weight: Font.DemiBold
            font.underline: activeFocus
            activeFocusOnTab: root.shown && root.actionText.length > 0
            Accessible.role: Accessible.Button
            Accessible.name: root.actionText
            Accessible.onPressAction: root.triggerAction()
            Keys.onReturnPressed: root.triggerAction()
            Keys.onSpacePressed: root.triggerAction()

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
