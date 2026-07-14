pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../.."

FocusScope {
    id: root

    objectName: "settingsDataPage"
    property var appSettingsRef: null
    property bool compact: false
    signal routineRequested
    signal categoryRequested
    signal exportRequested

    implicitHeight: contentColumn.implicitHeight

    ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space24

        SettingsSection {
            title: "管理"
            description: "这些入口会关闭设置，并打开对应的管理窗口。"

            ManageButton {
                objectName: "settingsManageRoutine"
                text: "每日例行"
                caption: "管理自动生成的重复任务"
                onClicked: root.routineRequested()
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            ManageButton {
                objectName: "settingsManageCategory"
                text: "科目管理"
                caption: "维护任务分类、名称和颜色"
                onClicked: root.categoryRequested()
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            ManageButton {
                objectName: "settingsManageExport"
                text: "数据导出"
                caption: "把任务与专注记录导出为本机文件"
                onClicked: root.exportRequested()
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: localDataColumn.implicitHeight + Theme.space24
            color: Theme.surfaceSunken
            border.color: Theme.borderSubtle
            border.width: 1
            radius: Theme.radiusMd

            ColumnLayout {
                id: localDataColumn

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.space12
                spacing: Theme.space4

                Text {
                    Layout.fillWidth: true
                    text: "本机数据"
                    color: Theme.inkStrong
                    font.pixelSize: Theme.fontLg
                    font.weight: Font.DemiBold
                }

                Text {
                    Layout.fillWidth: true
                    text: "任务、专注记录和偏好保存在这台 Mac。应用当前不提供账号、云同步或自动备份。"
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                    wrapMode: Text.WordWrap
                }
            }
        }
    }

    component ManageButton: Button {
        id: control

        required property string caption

        Layout.fillWidth: true
        implicitHeight: 60
        activeFocusOnTab: true
        Accessible.name: text
        Accessible.description: caption

        background: Rectangle {
            color: control.hovered ? Theme.surfaceSunken : "transparent"
            border.color: control.activeFocus ? Theme.accent : "transparent"
            border.width: control.activeFocus ? 2 : 0
            radius: Theme.radiusMd
        }

        contentItem: RowLayout {
            spacing: Theme.space12

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Text {
                    Layout.fillWidth: true
                    text: control.text
                    color: Theme.ink
                    font.pixelSize: Theme.fontLg
                }

                Text {
                    Layout.fillWidth: true
                    text: control.caption
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                    elide: Text.ElideRight
                }
            }

            Text {
                text: "›"
                color: Theme.inkSoft
                font.pixelSize: Theme.fontXl
            }
        }
    }
}
