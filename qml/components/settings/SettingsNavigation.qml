pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../.."

Control {
    id: root

    objectName: "settingsNavigation"
    property int currentIndex: 0
    property bool compact: false
    property bool reduceMotion: false
    readonly property int animationDuration: reduceMotion ? 0 : 100
    signal categoryRequested(int index)

    readonly property var categories: [
        { title: "外观", icon: "appearance", objectName: "settingsCategoryAppearance" },
        { title: "专注", icon: "focus", objectName: "settingsCategoryFocus" },
        { title: "通用", icon: "general", objectName: "settingsCategoryGeneral" },
        { title: "数据与管理", icon: "data", objectName: "settingsCategoryData" },
        { title: "关于", icon: "about", objectName: "settingsCategoryAbout" }
    ]

    implicitWidth: compact ? 168 : 204
    padding: Theme.space12

    background: Rectangle {
        color: Theme.surfaceRaised
        border.color: Theme.borderSubtle
        border.width: 1
        radius: Theme.radiusLg
    }

    contentItem: ColumnLayout {
        spacing: Theme.space4

        // —— 应用标识 ——
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space4
            Layout.topMargin: Theme.space4
            Layout.bottomMargin: Theme.space12
            spacing: Theme.space8

            Rectangle {
                Layout.preferredWidth: 40
                Layout.preferredHeight: 40
                radius: Theme.radiusMd
                color: Theme.accentSoft
                border.color: Theme.accent
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: "番"
                    color: Theme.accentInk
                    font.pixelSize: 22
                    font.weight: Font.Bold
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                    Layout.fillWidth: true
                    text: "番茄Todo"
                    color: Theme.inkStrong
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }

                Text {
                    Layout.fillWidth: true
                    text: "专注 · 规划 · 成长"
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                    elide: Text.ElideRight
                }
            }
        }

        Repeater {
            id: categoryRepeater

            objectName: "settingsCategoryRepeater"
            model: root.categories

            delegate: Button {
                id: categoryButton

                required property var modelData
                required property int index

                objectName: modelData.objectName
                Layout.fillWidth: true
                implicitHeight: 44
                text: modelData.title
                // currentIndex 是唯一选中源；当前项再次点击不能把自身切成未选中。
                checkable: false
                checked: root.currentIndex === index
                activeFocusOnTab: true
                Accessible.name: modelData.title + "设置"
                onClicked: root.categoryRequested(index)
                Keys.onReturnPressed: event => {
                    root.categoryRequested(index)
                    event.accepted = true
                }
                Keys.onEnterPressed: event => {
                    root.categoryRequested(index)
                    event.accepted = true
                }

                background: Rectangle {
                    // 静息态用「全透明的暖色」而非 "transparent"（= 透明黑），
                    // 否则 ColorAnimation 会经过半透明黑，悬停闪灰影。
                    readonly property color hoverTint: Theme.surfaceSunken
                    color: categoryButton.checked
                           ? Theme.accent
                           : (categoryButton.hovered
                              ? hoverTint
                              : Qt.rgba(hoverTint.r, hoverTint.g, hoverTint.b, 0))
                    border.color: categoryButton.activeFocus ? Theme.focusRing : "transparent"
                    border.width: categoryButton.activeFocus ? 2 : 0
                    radius: Theme.radiusMd

                    Behavior on color {
                        ColorAnimation { duration: root.animationDuration }
                    }
                }

                contentItem: RowLayout {
                    spacing: Theme.space8

                    Rectangle {
                        Layout.leftMargin: Theme.space4
                        Layout.preferredWidth: 26
                        Layout.preferredHeight: 26
                        radius: Theme.radiusSm + 2
                        color: categoryButton.checked
                               ? Qt.rgba(1, 1, 1, 0.32)
                               : Theme.surfaceSunken

                        GlyphIcon {
                            anchors.centerIn: parent
                            name: categoryButton.modelData.icon
                            size: 17
                            color: categoryButton.checked ? Theme.accentForeground : Theme.inkSoft
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: categoryButton.text
                        color: categoryButton.checked ? Theme.accentForeground : Theme.ink
                        font.pixelSize: Theme.fontLg
                        font.weight: categoryButton.checked ? Font.DemiBold : Font.Normal
                        elide: Text.ElideRight
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
