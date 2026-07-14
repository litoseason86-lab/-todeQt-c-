import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../.."

Button {
    id: root

    property var appSettingsRef: null
    property string themeId: ""
    property string themeName: ""
    property string themeMode: "light"

    objectName: "settingsThemeChoice-" + themeId
    implicitWidth: 154
    implicitHeight: 104
    checkable: true
    checked: Theme.migrateThemeId(appSettingsRef ? appSettingsRef.backgroundTheme : "warm") === themeId
    activeFocusOnTab: true
    Accessible.name: "背景主题：" + themeName
    Accessible.description: checked ? "当前已选择" : "按下切换主题"
    onClicked: {
        if (appSettingsRef) {
            appSettingsRef.backgroundTheme = themeId
        }
    }

    background: Rectangle {
        color: root.checked ? Theme.accentSoft : "transparent"
        border.color: root.activeFocus || root.checked ? Theme.accent : Theme.border
        border.width: root.activeFocus ? 2 : 1
        radius: Theme.radiusMd
    }

    contentItem: ColumnLayout {
        spacing: Theme.space4

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 66
            Layout.margins: 3
            Layout.bottomMargin: 0
            radius: Theme.radiusSm
            clip: true
            color: Theme.surfaceSunken

            BackgroundWallpaper {
                anchors.fill: parent
                themeId: root.themeId
                requestedSourceSize: Qt.size(154, 66)
            }

            Rectangle {
                objectName: "settingsThemeGlass-" + root.themeId
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Theme.space8
                height: 15
                radius: Theme.radiusSm
                color: Theme.glassCardForMode(root.themeMode)
                border.color: Theme.glassBorderForMode(root.themeMode)
                border.width: 1
            }

            Rectangle {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: Theme.space4
                width: 18
                height: 18
                radius: 9
                color: Theme.accentStrong
                visible: root.checked

                Text {
                    anchors.centerIn: parent
                    text: "✓"
                    color: Theme.surface
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Bold
                }
            }
        }

        Text {
            Layout.fillWidth: true
            text: root.themeName
            color: root.checked ? Theme.inkStrong : Theme.ink
            font.pixelSize: Theme.fontMd
            font.weight: root.checked ? Font.DemiBold : Font.Normal
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }
    }
}
