import QtQuick
import QtQuick.Layouts
import "../.."

FocusScope {
    id: root

    objectName: "settingsAboutPage"
    property var appSettingsRef: null
    property bool compact: false
    // 由 SettingsDialog 注入的可视区高度；内容不满一屏时整块垂直居中，
    // 避免"内容顶在上面、下方一大片空"的失衡观感。
    property real viewportHeight: 0

    implicitHeight: Math.max(contentColumn.implicitHeight, viewportHeight)

    ColumnLayout {
        id: contentColumn

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(400, root.width)
        spacing: Theme.space12

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 88
            Layout.preferredHeight: 88
            color: Theme.accentSoft
            border.color: Theme.accent
            border.width: 1
            // 比通用圆角大一档，接近 macOS 应用图标的观感。
            radius: 22

            Text {
                anchors.centerIn: parent
                text: "番"
                color: Theme.accentInk
                font.pixelSize: 40
                font.weight: Font.Bold
            }
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.space4
            text: "番茄 Todo"
            color: Theme.inkStrong
            font.pixelSize: Theme.fontXxl
            font.weight: Font.Bold
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "专注 · 规划 · 成长"
            color: Theme.inkSoft
            font.pixelSize: Theme.fontMd
        }

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.space4
            width: versionRow.implicitWidth + Theme.space16
            height: 24
            radius: 12
            color: Theme.surfaceSunken

            Row {
                id: versionRow

                anchors.centerIn: parent
                spacing: Theme.space4

                Text {
                    text: "版本"
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                }

                Text {
                    objectName: "settingsAboutVersion"
                    text: Qt.application.version
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                    Accessible.name: "版本 " + text
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: Theme.space16
            implicitHeight: infoRows.implicitHeight + Theme.space8 * 2
            color: Theme.surfaceRaised
            border.color: Theme.borderSubtle
            border.width: 1
            radius: Theme.radiusLg

            ColumnLayout {
                id: infoRows

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.space8
                anchors.leftMargin: Theme.space16
                anchors.rightMargin: Theme.space16
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40

                    Text {
                        text: "框架"
                        color: Theme.ink
                        font.pixelSize: Theme.fontMd
                    }

                    Item { Layout.fillWidth: true }

                    Text {
                        text: "Qt 6 · 本地部署版"
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 1
                    color: Theme.borderSubtle
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40

                    Text {
                        text: "数据存储"
                        color: Theme.ink
                        font.pixelSize: Theme.fontMd
                    }

                    Item { Layout.fillWidth: true }

                    Text {
                        text: "仅保存在这台 Mac"
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.topMargin: Theme.space4
            text: "卸载应用前，请先在「数据与管理」中按需导出数据。"
            color: Theme.inkMuted
            font.pixelSize: Theme.fontSm
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
    }
}
