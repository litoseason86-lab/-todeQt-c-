import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    property int goalId: -1
    property string goalName: ""
    property date targetDate: new Date()
    property int daysRemaining: 0
    property bool canMoveUp: false
    property bool canMoveDown: false

    signal clicked()
    signal deleteRequested(int goalId)
    signal moveUpRequested()
    signal moveDownRequested()

    height: 62
    radius: Theme.radiusLg
    color: Theme.surfaceRaised
    border.color: hitArea.containsMouse ? Theme.accent : Theme.border
    border.width: 1
    layer.enabled: hitArea.containsMouse
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
        var days = Number(root.daysRemaining || 0);
        return days >= 0 ? Math.abs(days) + "天" : "已过期 " + Math.abs(days) + "天";
    }

    MouseArea {
        id: hitArea

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton
        onClicked: root.clicked()
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.space12
        anchors.rightMargin: Theme.space12
        spacing: Theme.space12

        Text {
            text: "≡"
            font.pixelSize: Theme.fontXl
            color: Theme.inkMuted
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 3

            Text {
                text: root.goalName
                font.pixelSize: Theme.fontLg
                font.weight: Font.Medium
                color: Theme.ink
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Text {
                text: Qt.formatDate(root.targetDate, "yyyy年MM月dd日")
                font.pixelSize: Theme.fontXs
                color: Theme.inkSoft
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }

        Text {
            text: root.dayText()
            font.pixelSize: Theme.fontLg
            font.weight: Font.Bold
            color: Theme.accent
        }

        Button {
            text: "↑"
            enabled: root.canMoveUp
            implicitWidth: 34
            implicitHeight: 34
            onClicked: root.moveUpRequested()
        }

        Button {
            text: "↓"
            enabled: root.canMoveDown
            implicitWidth: 34
            implicitHeight: 34
            onClicked: root.moveDownRequested()
        }

        Button {
            text: "删除"
            implicitWidth: 52
            implicitHeight: 34
            onClicked: root.deleteRequested(root.goalId)
        }
    }
}
