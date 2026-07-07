// 画廊 delegate 引用外层 root，按项目惯例显式绑定组件作用域（EditTaskDialog 先例）。
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import ".."

// 设置弹窗：把低频偏好和管理入口集中收纳，侧栏只保留高频导航。
// 主题即点即切即持久化（写 appSettingsRef.backgroundTheme），不设确认按钮。
Popup {
    id: root

    property var appSettingsRef: null
    signal routineRequested
    signal categoryRequested
    signal exportRequested

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(420, parent ? Math.max(320, parent.width - 64) : 420)
    height: Math.min(contentColumn.implicitHeight,
                     parent ? parent.height - Theme.space32 * 2 : contentColumn.implicitHeight)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    function selectTheme(themeId) {
        // 缺 appSettings（测试/降级）时画廊只展示不写入，与全应用守卫模式一致。
        if (root.appSettingsRef) {
            root.appSettingsRef.backgroundTheme = themeId
        }
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 0.94
                to: 1.0
                duration: 220
                easing.type: Easing.OutCubic
            }

            OpacityAnimator {
                from: 0
                to: 1
                duration: 220
                easing.type: Easing.OutQuad
            }
        }
    }

    exit: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 1.0
                to: 0.94
                duration: 220
                easing.type: Easing.InQuad
            }

            OpacityAnimator {
                from: 1
                to: 0
                duration: 220
                easing.type: Easing.InQuad
            }
        }
    }

    Overlay.modal: Rectangle {
        color: "#66000000"
        opacity: root.opened ? 1 : 0

        Behavior on opacity {
            OpacityAnimator {
                duration: 180
                easing.type: Easing.InOutQuad
            }
        }
    }

    background: Rectangle {
        id: panel
        objectName: "settingsDialogPanel"

        implicitWidth: root.width
        implicitHeight: contentColumn.implicitHeight
        color: Theme.glassDialog
        border.color: Theme.glassBorder
        border.width: 1
        radius: Theme.radiusLg
        layer.enabled: true
        layer.effect: MultiEffect {
            autoPaddingEnabled: true
            shadowEnabled: true
            shadowColor: Theme.shadow
            shadowOpacity: 0.12
            shadowBlur: 0.20
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 4
        }
    }

    contentItem: ScrollView {
        id: settingsScroll

        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        // 主题化竖向滚动条：弹窗小窗体下只滚内容，不把整窗撑出屏幕。
        ScrollBar.vertical: ScrollBar {
            id: settingsScrollBar
            policy: ScrollBar.AsNeeded
            width: 8

            contentItem: Rectangle {
                implicitWidth: 4
                radius: Theme.radiusSm
                color: settingsScrollBar.pressed || settingsScrollBar.hovered ? Theme.accent : Theme.border
            }

            background: Rectangle {
                color: "transparent"
            }
        }

        ColumnLayout {
            id: contentColumn

            width: settingsScroll.availableWidth
            spacing: Theme.space12

            Text {
                Layout.leftMargin: Theme.space16
                Layout.topMargin: Theme.space16
                text: "设置"
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
            }

            Text {
                Layout.leftMargin: Theme.space16
                text: "背景主题"
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
                font.weight: Font.Bold
            }

            GridLayout {
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                columns: 3
                rowSpacing: Theme.space12
                columnSpacing: Theme.space12

                Repeater {
                    id: themeRepeater
                    objectName: "settingsThemeRepeater"

                    model: Theme.backgroundThemes

                    delegate: Column {
                        id: themeCell

                        required property var modelData

                        objectName: "settingsThemeCell-" + themeCell.modelData.id
                        // 选中态直接绑设置属性（函数调用不具备响应性，这里必须是属性链）。
                        readonly property bool selected: root.appSettingsRef
                            ? root.appSettingsRef.backgroundTheme === themeCell.modelData.id
                            : themeCell.modelData.id === "warmPaper"

                        Layout.preferredWidth: 104
                        spacing: Theme.space4

                        Rectangle {
                            id: thumbFrame
                            objectName: "settingsThemeThumb-" + themeCell.modelData.id

                            width: 104
                            height: 66
                            radius: Theme.radiusMd
                            clip: true
                            color: themeCell.selected ? Theme.accentSoft : Qt.rgba(1, 1, 1, 0)
                            border.color: themeCell.selected ? Theme.accent : Theme.border
                            border.width: themeCell.selected ? 2 : 1

                            BackgroundWallpaper {
                                // 缩略图与壁纸层同组件同定义：画廊所见即所得。
                                anchors.fill: parent
                                anchors.margins: 3
                                themeId: themeCell.modelData.id
                            }

                            Rectangle {
                                // 迷你磨砂条：让用户换主题前预感玻璃面板的观感。
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.leftMargin: 10
                                anchors.rightMargin: 10
                                anchors.bottomMargin: 8
                                height: 16
                                radius: Theme.radiusSm
                                color: Theme.glassCard
                                border.color: Theme.glassBorder
                                border.width: 1
                            }

                            Rectangle {
                                anchors.top: parent.top
                                anchors.right: parent.right
                                anchors.margins: 4
                                width: 16
                                height: 16
                                radius: 8
                                color: Theme.accent
                                visible: themeCell.selected

                                Text {
                                    anchors.centerIn: parent
                                    text: "✓"
                                    textFormat: Text.PlainText
                                    color: Theme.surface
                                    font.pixelSize: 10
                                    font.weight: Font.Bold
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.selectTheme(themeCell.modelData.id)
                            }
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: themeCell.modelData.name
                            textFormat: Text.PlainText
                            color: themeCell.selected ? Theme.ink : Theme.inkSoft
                            font.pixelSize: Theme.fontSm
                        }
                    }
                }
            }

            Text {
                Layout.leftMargin: Theme.space16
                text: "偏好"
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
                font.weight: Font.Bold
            }

            PreferenceSwitchRow {
                label: "提示音"
                switchName: "settingsSoundSwitch"
                checkedValue: root.appSettingsRef ? root.appSettingsRef.soundEnabled : true
                onToggledTo: function (value) {
                    if (root.appSettingsRef) {
                        root.appSettingsRef.soundEnabled = value
                    }
                }
            }

            PreferenceSwitchRow {
                label: "减少动效"
                switchName: "settingsReduceMotionSwitch"
                checkedValue: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
                onToggledTo: function (value) {
                    if (root.appSettingsRef) {
                        root.appSettingsRef.reduceMotion = value
                    }
                }
            }

            Text {
                Layout.leftMargin: Theme.space16
                text: "管理"
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
                font.weight: Font.Bold
            }

            ManageEntryRow {
                label: "每日例行"
                rowName: "settingsManageRoutine"
                onActivated: {
                    root.close()
                    root.routineRequested()
                }
            }

            ManageEntryRow {
                label: "科目管理"
                rowName: "settingsManageCategory"
                onActivated: {
                    root.close()
                    root.categoryRequested()
                }
            }

            ManageEntryRow {
                label: "数据导出"
                rowName: "settingsManageExport"
                onActivated: {
                    root.close()
                    root.exportRequested()
                }
            }

            Button {
                id: closeButton
                objectName: "settingsCloseButton"

                Layout.alignment: Qt.AlignRight
                Layout.rightMargin: Theme.space16
                Layout.bottomMargin: Theme.space16
                text: "关闭"
                implicitWidth: 80
                implicitHeight: 36

                onClicked: root.close()

                background: Rectangle {
                    color: closeButton.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
                    border.color: Theme.border
                    border.width: 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: closeButton.text
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    // 偏好开关行：内部 Switch 保留 Basic 控件语义，视觉层改成暖纸轨道和圆钮。
    component PreferenceSwitchRow: RowLayout {
        id: prefRow

        property string label: ""
        property string switchName: ""
        property bool checkedValue: false
        signal toggledTo(bool value)

        Layout.fillWidth: true
        Layout.leftMargin: Theme.space16
        Layout.rightMargin: Theme.space16

        Text {
            Layout.fillWidth: true
            text: prefRow.label
            textFormat: Text.PlainText
            color: Theme.ink
            font.pixelSize: Theme.fontMd
        }

        Switch {
            id: prefSwitch
            objectName: prefRow.switchName

            checked: prefRow.checkedValue
            onToggled: prefRow.toggledTo(checked)

            indicator: Rectangle {
                objectName: prefRow.switchName + "Track"
                implicitWidth: 40
                implicitHeight: 22
                radius: 11
                color: prefSwitch.checked ? Theme.accent : Theme.surfaceSunken
                border.color: Theme.border
                border.width: 1

                Rectangle {
                    objectName: prefRow.switchName + "Thumb"
                    x: prefSwitch.checked ? parent.width - width - 2 : 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 18
                    height: 18
                    radius: 9
                    color: Theme.surface

                    Behavior on x {
                        NumberAnimation {
                            duration: 120
                            easing.type: Easing.OutQuad
                        }
                    }
                }
            }

            contentItem: Item {}
        }
    }

    // 管理入口行：整行可点，右侧箭头只表达“进入下一层”，弹窗本身负责发信号。
    component ManageEntryRow: Rectangle {
        id: manageRow

        property string label: ""
        property string rowName: ""
        signal activated

        objectName: manageRow.rowName
        Layout.fillWidth: true
        Layout.leftMargin: Theme.space16
        Layout.rightMargin: Theme.space16
        implicitHeight: 40
        radius: Theme.radiusMd
        color: manageHover.hovered ? Theme.surfaceSunken : "transparent"

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.space8
            anchors.rightMargin: Theme.space8

            Text {
                Layout.fillWidth: true
                text: manageRow.label
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontMd
            }

            Text {
                text: "›"
                textFormat: Text.PlainText
                color: Theme.inkMuted
                font.pixelSize: Theme.fontLg
            }
        }

        HoverHandler {
            id: manageHover
        }

        TapHandler {
            onTapped: manageRow.activated()
        }
    }
}
