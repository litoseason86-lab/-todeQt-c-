import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    property var primaryGoal: null
    readonly property bool hasGoal: primaryGoal !== null && primaryGoal !== undefined && primaryGoal.name !== undefined

    signal clicked()
    signal addRequested()

    height: 68
    radius: Theme.radiusLg
    border.color: Theme.border
    border.width: 1
    scale: hitArea.containsMouse ? 1.01 : 1.0
    transformOrigin: Item.Center

    gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: Theme.accentSoft }
        GradientStop { position: 1.0; color: Theme.surfaceRaised }
    }

    layer.enabled: true
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: Theme.shadow
        shadowOpacity: 0.08
        shadowBlur: 0.14
        shadowHorizontalOffset: 0
        shadowVerticalOffset: 2
    }

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
