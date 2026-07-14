pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
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
        { title: "外观", glyph: "◐", objectName: "settingsCategoryAppearance" },
        { title: "专注", glyph: "◷", objectName: "settingsCategoryFocus" },
        { title: "通用", glyph: "⌘", objectName: "settingsCategoryGeneral" },
        { title: "数据与管理", glyph: "▤", objectName: "settingsCategoryData" },
        { title: "关于", glyph: "ⓘ", objectName: "settingsCategoryAbout" }
    ]

    implicitWidth: compact ? 148 : 168
    padding: Theme.space12

    background: Rectangle {
        color: Theme.surfaceRaised
        border.color: Theme.borderSubtle
        border.width: 1
        radius: Theme.radiusLg
    }

    contentItem: ColumnLayout {
        spacing: Theme.space4

        Text {
            Layout.leftMargin: Theme.space8
            Layout.topMargin: Theme.space4
            Layout.bottomMargin: Theme.space8
            text: "设置"
            color: Theme.inkStrong
            font.pixelSize: Theme.fontXl
            font.weight: Font.DemiBold
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
                checkable: true
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
                    color: categoryButton.checked
                           ? Theme.accentSoft
                           : (categoryButton.hovered ? Theme.surfaceSunken : "transparent")
                    border.color: categoryButton.activeFocus ? Theme.accent : "transparent"
                    border.width: categoryButton.activeFocus ? 2 : 0
                    radius: Theme.radiusMd

                    Behavior on color {
                        ColorAnimation { duration: root.animationDuration }
                    }
                }

                contentItem: RowLayout {
                    spacing: Theme.space8

                    Text {
                        Layout.preferredWidth: 22
                        text: categoryButton.modelData.glyph
                        color: categoryButton.checked ? Theme.accentInk : Theme.inkSoft
                        font.pixelSize: Theme.fontLg
                        horizontalAlignment: Text.AlignHCenter
                    }

                    Text {
                        Layout.fillWidth: true
                        text: categoryButton.text
                        color: categoryButton.checked ? Theme.inkStrong : Theme.ink
                        font.pixelSize: Theme.fontLg
                        font.weight: categoryButton.checked ? Font.DemiBold : Font.Normal
                        elide: Text.ElideRight
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space8
            Layout.rightMargin: Theme.space8
            Layout.bottomMargin: Theme.space4
            text: "偏好仅保存在这台 Mac"
            color: Theme.inkSoft
            font.pixelSize: Theme.fontMd
            wrapMode: Text.WordWrap
        }
    }
}
