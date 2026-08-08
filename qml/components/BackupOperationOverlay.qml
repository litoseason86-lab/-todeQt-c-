import QtQuick
import QtQuick.Controls.Basic
import ".."

// 数据库整体替换期间的模态阻断层：避免用户把旧页面中的任务 ID 继续写入新数据库。
Rectangle {
    id: root

    required property string message
    property bool reduceMotion: false

    color: Theme.modalScrim
    focus: true
    Accessible.role: Accessible.AlertMessage
    Accessible.name: message

    Component.onCompleted: forceActiveFocus()
    Keys.onPressed: event => {
        // 恢复事务不能被 Escape 或快捷键从界面层中断；完成或回滚后由服务自动解除。
        event.accepted = true
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        hoverEnabled: true
    }

    // 减少动效时旋转指示器会被整个移除，于是遮罩上只剩一行静止文字——而它还吞掉
    // Escape，用户没有任何办法区分「正在跑」和「已经卡死」。减少动效应该降级动画，
    // 不是删掉反馈，所以补一个每秒递增的耗时读数作为存活信号。
    // 它是信息而不是装饰动画，不违反「无限循环动画必须停止」那条规则。
    readonly property bool showsElapsedInstead: root.reduceMotion || Theme.reduceMotion
    property int elapsedSeconds: 0

    Timer {
        objectName: "backupOverlayElapsedTimer"
        interval: 1000
        repeat: true
        running: root.showsElapsedInstead
        onTriggered: root.elapsedSeconds += 1
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(360, parent.width - Theme.space32 * 2)
        height: 124
        radius: Theme.radiusLg
        color: Theme.surfaceRaised
        border.color: Theme.border
        border.width: 1

        BusyIndicator {
            id: indicator

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Theme.space24
            width: 32
            height: 32
            running: !root.showsElapsedInstead
            visible: running
        }

        Text {
            objectName: "backupOverlayElapsedText"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Theme.space24
            height: 32
            visible: root.showsElapsedInstead
            text: qsTr("已用 %1 秒").arg(root.elapsedSeconds)
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontMd
            verticalAlignment: Text.AlignVCenter
        }

        Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Theme.space24
            text: root.message.length > 0 ? root.message : "正在处理数据"
            textFormat: Text.PlainText
            color: Theme.inkStrong
            font.pixelSize: Theme.fontLg
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
    }
}
