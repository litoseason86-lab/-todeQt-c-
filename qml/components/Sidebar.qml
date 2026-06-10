import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

Rectangle {
    id: root

    width: 208
    readonly property color sidebarBackgroundColor: "#faf8f3"
    color: root.sidebarBackgroundColor

    property string currentView: "today"
    property var categoryManagerRef: null
    property var exportServiceRef: null
    signal itemClicked(string viewName)
    signal categoryManagementRequested
    signal dataExportRequested

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 4

        Text {
            text: "番茄Todo"
            font.pixelSize: 20
            font.weight: Font.Bold
            color: "#5d4e37"
            Layout.bottomMargin: 18
        }

        Text {
            text: "时间视图"
            font.pixelSize: 12
            font.weight: Font.Bold
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
            opacity: 0.8
        }

        SidebarItem {
            text: "本周计划"
            marker: "周"
            isActive: root.currentView === "week"
            onClicked: root.itemClicked("week")
        }

        SidebarItem {
            text: "专注历史"
            marker: "月"
            isActive: root.currentView === "month"
            onClicked: root.itemClicked("month")
        }

        SidebarItem {
            text: "数据统计"
            marker: "数"
            isActive: root.currentView === "stats"
            onClicked: root.itemClicked("stats")
        }

        SidebarItem {
            text: "目标倒计时"
            marker: "倒"
            isActive: root.currentView === "countdown"
            onClicked: root.itemClicked("countdown")
        }

        Item {
            Layout.fillHeight: true
        }

        SidebarItem {
            text: "科目管理"
            marker: "科"
            isActive: false
            onClicked: root.categoryManagementRequested()
        }

        SidebarItem {
            text: "数据导出"
            marker: "导"
            isActive: false
            onClicked: root.dataExportRequested()
        }

        Text {
            text: "三阶段"
            font.pixelSize: 12
            font.weight: Font.Normal
            color: "#a0896b"
            opacity: 0.7
        }
    }

    component SidebarItem: Rectangle {
        id: item

        property string text: ""
        property string marker: ""
        property bool isActive: false
        // 显式状态能抵消 MouseArea 和 HoverHandler 在不同设备上的悬停事件差异。
        property bool pointerInside: false
        readonly property bool visualHovered: item.enabled && item.pointerInside
        signal clicked

        function setPointerInside(inside) {
            item.pointerInside = item.enabled && inside;
        }

        objectName: "sidebarItem-" + item.marker
        Layout.fillWidth: true
        Layout.preferredHeight: 44
        radius: 6
        color: item.isActive ? "#f0e6d2" : (item.visualHovered ? "#faf6ee" : root.sidebarBackgroundColor)
        border.color: item.isActive ? "#d4a574" : (item.visualHovered ? "#e8dfc8" : root.sidebarBackgroundColor)
        border.width: item.isActive || item.visualHovered ? 1 : 0
        opacity: item.enabled ? 1.0 : 0.55
        // 侧边栏只用颜色和边框反馈，避免悬浮或选中时先出现阴影造成顿挫。
        layer.enabled: false

        Behavior on color {
            ColorAnimation {
                duration: 70
                easing.type: Easing.OutQuad
            }
        }

        Behavior on border.color {
            ColorAnimation {
                duration: 70
                easing.type: Easing.OutQuad
            }
        }

        Behavior on border.width {
            NumberAnimation {
                duration: 70
                easing.type: Easing.OutQuad
            }
        }

        onEnabledChanged: {
            if (!item.enabled) {
                item.pointerInside = false;
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 8

            Rectangle {
                objectName: "sidebarMarker-" + item.marker
                Layout.preferredWidth: 22
                Layout.preferredHeight: 22
                radius: 4
                color: item.isActive ? "#d4a574" : "#e8dfc8"

                Behavior on color {
                    ColorAnimation {
                        duration: 70
                        easing.type: Easing.OutQuad
                    }
                }

                Text {
                    anchors.centerIn: parent
                    text: item.marker
                    font.pixelSize: 12
                    font.weight: Font.Bold
                    color: item.isActive ? "#fffef9" : "#8b7355"

                    Behavior on color {
                        ColorAnimation {
                            duration: 70
                            easing.type: Easing.OutQuad
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: item.text
                font.pixelSize: 14
                font.weight: item.isActive ? Font.Medium : Font.Normal
                color: item.isActive ? "#5d4e37" : "#8b7355"
                elide: Text.ElideRight
            }
        }

        MouseArea {
            id: mouseArea

            objectName: "sidebarHitArea-" + item.marker
            anchors.fill: parent
            hoverEnabled: true
            enabled: item.enabled
            cursorShape: Qt.PointingHandCursor
            onEntered: item.setPointerInside(true)
            onExited: item.setPointerInside(false)
            onClicked: item.clicked()
        }

        HoverHandler {
            id: hoverHandler
            enabled: item.enabled
            // 某些 Qt/macOS 触控板路径可能绕过 MouseArea 的进入/离开事件。
            onHoveredChanged: item.setPointerInside(hovered)
        }
    }
}
