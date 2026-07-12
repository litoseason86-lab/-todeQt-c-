import QtQuick
import QtQuick.Layouts
import ".."

// 与页面其它玻璃卡同一基底（glassCard + 玻璃描边 + 受光棱边 + 柔影），
// 不再自带暖色渐变，避免在冷色壁纸上显得发黄突兀。
GlassPanel {
    id: root

    property var primaryGoal: null
    readonly property bool hasGoal: primaryGoal !== null && primaryGoal !== undefined && primaryGoal.name !== undefined

    signal clicked()
    signal addRequested()

    height: 68
    scale: hitArea.containsMouse ? 1.01 : 1.0
    transformOrigin: Item.Center

    function dayText() {
        if (!root.hasGoal) {
            return "";
        }
        var days = Number(root.primaryGoal.daysRemaining || 0);
        return days >= 0 ? Math.abs(days) + "天" : "已过期 " + Math.abs(days) + "天";
    }

    function activate() {
        // MouseArea 和测试共用同一条入口，避免点击坐标差异造成行为分叉。
        root.hasGoal ? root.clicked() : root.addRequested();
    }

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 4
        color: Theme.accent
        radius: Theme.radiusLg
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.space16
        anchors.rightMargin: Theme.space16
        spacing: Theme.space16

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.space4

            Text {
                text: root.hasGoal ? root.primaryGoal.name : "+ 添加目标倒计时"
                font.pixelSize: Theme.fontLg
                font.weight: Font.Medium
                color: Theme.ink
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Text {
                text: root.hasGoal ? Qt.formatDate(root.primaryGoal.targetDate, "yyyy年MM月dd日") : "把最重要的日期固定在今天任务上方。"
                font.pixelSize: Theme.fontXs
                color: Theme.inkSoft
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }

        Text {
            visible: root.hasGoal
            text: root.dayText()
            font.pixelSize: Theme.fontXxl
            font.weight: Font.Bold
            color: Theme.accent
        }
    }

    MouseArea {
        id: hitArea

        objectName: "countdownBannerHitArea"
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activate()
    }

    Behavior on scale {
        NumberAnimation {
            duration: 150
            easing.type: Easing.OutQuad
        }
    }
}
