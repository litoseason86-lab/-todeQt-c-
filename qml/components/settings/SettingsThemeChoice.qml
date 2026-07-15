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
    implicitHeight: 122
    // 选中态由持久化主题唯一决定；按钮自身不切换 checked，避免再次点击当前主题后视觉失选。
    checkable: false
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
        border.color: root.activeFocus ? Theme.focusRing : (root.checked ? Theme.accent : Theme.border)
        border.width: root.activeFocus ? 2 : 1
        radius: Theme.radiusMd
    }

    contentItem: ColumnLayout {
        spacing: Theme.space4

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 84
            Layout.margins: 3
            Layout.bottomMargin: 0
            radius: Theme.radiusSm
            clip: true
            color: Theme.surfaceSunken

            BackgroundWallpaper {
                anchors.fill: parent
                themeId: root.themeId
                requestedSourceSize: Qt.size(154, 84)
            }

            // 玻璃计时预览环：透出候选主题的玻璃色，中央显示 25:00（用真实计时字体）。
            Rectangle {
                objectName: "settingsThemeGlass-" + root.themeId
                anchors.centerIn: parent
                width: 56
                height: 56
                radius: width / 2
                color: Theme.glassCardForMode(root.themeMode)
                border.color: Theme.glassBorderForMode(root.themeMode)
                border.width: 1.5

                Text {
                    anchors.centerIn: parent
                    text: "25:00"
                    color: root.themeMode === "dark" ? "#f3ead9" : "#463a2b"
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.DemiBold
                    font.family: Theme.fontFamilyClock
                }
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
                    color: Theme.accentForeground
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
