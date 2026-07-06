// 画廊 delegate 引用外层 root，按项目惯例显式绑定组件作用域（EditTaskDialog 先例）。
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import ".."

// 设置弹窗：本期只有“背景主题”一栏；框架通用，将来其它设置逐步收进来。
// 主题即点即切即持久化（写 appSettingsRef.backgroundTheme），不设确认按钮。
Popup {
    id: root

    property var appSettingsRef: null

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(420, parent ? Math.max(320, parent.width - 64) : 420)
    height: panel.implicitHeight
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

    contentItem: ColumnLayout {
        id: contentColumn

        width: root.width
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

        Button {
            id: closeButton

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
