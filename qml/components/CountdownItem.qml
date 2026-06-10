import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts

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
    radius: 8
    color: hitArea.containsMouse ? "#fffaf1" : "#faf8f3"
    border.color: hitArea.containsMouse ? "#d4a574" : "#e8dfc8"
    border.width: 1
    layer.enabled: hitArea.containsMouse
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: "#000000"
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
        anchors.leftMargin: 14
        anchors.rightMargin: 10
        spacing: 10

        Text {
            text: "≡"
            font.pixelSize: 18
            color: "#a0896b"
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 3

            Text {
                text: root.goalName
                font.pixelSize: 15
                font.weight: Font.Medium
                color: "#5d4e37"
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Text {
                text: Qt.formatDate(root.targetDate, "yyyy年MM月dd日")
                font.pixelSize: 11
                color: "#8b7355"
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }

        Text {
            text: root.dayText()
            font.pixelSize: 15
            font.weight: Font.Bold
            color: "#d4a574"
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
