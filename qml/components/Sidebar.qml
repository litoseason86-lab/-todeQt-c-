import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root

    width: 208
    color: "#faf8f3"

    property string currentView: "today"
    signal itemClicked(string viewName)

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 4

        Text {
            text: "番茄Todo"
            font.pixelSize: 20
            font.bold: true
            color: "#5d4e37"
            Layout.bottomMargin: 18
        }

        Text {
            text: "时间视图"
            font.pixelSize: 12
            font.bold: true
            color: "#8b7355"
            Layout.bottomMargin: 6
        }

        SidebarItem {
            text: "今日任务"
            marker: "今"
            isActive: root.currentView === "today"
            onClicked: root.itemClicked("today")
        }

        SidebarItem {
            text: "专注计时"
            marker: "专"
            isActive: root.currentView === "focus"
            onClicked: root.itemClicked("focus")
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: "#e8dfc8"
            Layout.topMargin: 16
            Layout.bottomMargin: 16
        }

        SidebarItem {
            text: "本周计划"
            marker: "周"
            enabled: false
        }

        SidebarItem {
            text: "数据统计"
            marker: "数"
            enabled: false
        }

        Item {
            Layout.fillHeight: true
        }

        Text {
            text: "MVP 草案"
            font.pixelSize: 12
            color: "#a0896b"
        }
    }

    component SidebarItem: Rectangle {
        id: item

        property string text: ""
        property string marker: ""
        property bool isActive: false
        signal clicked()

        Layout.fillWidth: true
        Layout.preferredHeight: 44
        radius: 6
        color: item.isActive ? "#f0e6d2" : (mouseArea.containsMouse && item.enabled ? "#faf6ee" : "transparent")
        opacity: item.enabled ? 1.0 : 0.55

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 8

            Rectangle {
                Layout.preferredWidth: 22
                Layout.preferredHeight: 22
                radius: 4
                color: item.isActive ? "#d4a574" : "#e8dfc8"

                Text {
                    anchors.centerIn: parent
                    text: item.marker
                    font.pixelSize: 12
                    font.bold: true
                    color: item.isActive ? "#fffef9" : "#8b7355"
                }
            }

            Text {
                Layout.fillWidth: true
                text: item.text
                font.pixelSize: 14
                color: item.isActive ? "#5d4e37" : "#8b7355"
                elide: Text.ElideRight
            }
        }

        MouseArea {
            id: mouseArea

            anchors.fill: parent
            hoverEnabled: true
            enabled: item.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: item.clicked()
        }
    }
}
