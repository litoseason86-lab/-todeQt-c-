import QtQuick
import QtQuick.Layouts
import "../.."

FocusScope {
    id: root

    objectName: "settingsAboutPage"
    property var appSettingsRef: null
    property bool compact: false

    implicitHeight: contentColumn.implicitHeight

    ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space24

        Item { Layout.preferredHeight: Theme.space8 }

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 72
            Layout.preferredHeight: 72
            color: Theme.accentSoft
            border.color: Theme.accent
            border.width: 1
            radius: Theme.radiusLg

            Text {
                anchors.centerIn: parent
                text: "番"
                color: Theme.accentInk
                font.pixelSize: 32
                font.weight: Font.Bold
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.space4

            Text {
                Layout.fillWidth: true
                text: "番茄 Todo"
                color: Theme.inkStrong
                font.pixelSize: Theme.fontXxl
                font.weight: Font.Bold
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                objectName: "settingsAboutVersion"
                Layout.fillWidth: true
                text: Qt.application.version
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                horizontalAlignment: Text.AlignHCenter
                Accessible.name: "版本 " + text
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: aboutDescription.implicitHeight + Theme.space24 * 2
            color: Theme.surfaceRaised
            border.color: Theme.borderSubtle
            border.width: 1
            radius: Theme.radiusMd

            Text {
                id: aboutDescription

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.space24
                text: "一个面向本机使用的任务与专注工具。数据默认留在这台 Mac；卸载应用前请先按需导出。"
                color: Theme.ink
                font.pixelSize: Theme.fontLg
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
        }

        Text {
            Layout.fillWidth: true
            text: "Qt 6 · 本地部署版"
            color: Theme.inkSoft
            font.pixelSize: Theme.fontMd
            horizontalAlignment: Text.AlignHCenter
        }
    }
}
