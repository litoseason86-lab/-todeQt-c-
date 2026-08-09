import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 恢复确认弹窗：明确告知“替换全部数据 + 先自动备份当前数据”，并展示备份元信息。
Popup {
    id: root

    property string backupPath: ""
    property var info: ({})

    signal confirmed(string path)

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    width: Math.min(460, parent ? Math.max(300, parent.width - 64) : 460)
    height: panel.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    function metaLine(labelText, value) {
        return value === undefined || value === null || String(value).length === 0
            ? "" : labelText + "：" + value
    }

    Overlay.modal: Rectangle {
        color: Theme.dialogScrim
    }

    background: Rectangle {
        id: panel

        implicitWidth: root.width
        implicitHeight: contentColumn.implicitHeight
        color: Theme.glassDialog
        border.color: Theme.border
        border.width: 1
        radius: Theme.radiusLg
    }

    contentItem: ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space12

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            color: Theme.surface
            radius: Theme.radiusMd

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Theme.space16
                text: "从备份恢复"
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            text: "恢复将替换当前所有任务、专注记录和设置。程序会先自动备份当前数据，可随时再恢复回来。"
            textFormat: Text.PlainText
            color: Theme.inkStrong
            font.pixelSize: Theme.fontMd
            wrapMode: Text.WordWrap
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: 2

            Text {
                Layout.fillWidth: true
                visible: text.length > 0
                text: root.metaLine("备份时间", root.info ? root.info.created_at : "")
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
            }
            Text {
                Layout.fillWidth: true
                visible: text.length > 0
                text: root.metaLine("应用版本", root.info ? root.info.app_version : "")
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
            }
            Text {
                Layout.fillWidth: true
                visible: text.length > 0
                text: {
                    if (!root.info)
                        return ""
                    var t = root.info.taskCount
                    var s = root.info.sessionCount
                    if (t === undefined && s === undefined)
                        return ""
                    return "包含：任务 " + (t === undefined ? 0 : t) + " 条 · 专注记录 " + (s === undefined ? 0 : s) + " 条"
                }
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
            }
        }

        RowLayout {
            Layout.alignment: Qt.AlignRight
            Layout.rightMargin: Theme.space16
            Layout.bottomMargin: Theme.space16
            Layout.topMargin: Theme.space4
            spacing: Theme.space12

            Button {
                id: cancelButton
                objectName: "restoreCancelButton"
                text: "取消"
                implicitWidth: 80
                implicitHeight: 36
                onClicked: root.close()

                background: Rectangle {
                    color: cancelButton.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
                    border.color: Theme.border
                    border.width: 1
                    radius: Theme.radiusMd
                }
                contentItem: Text {
                    text: cancelButton.text
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Button {
                id: confirmButton
                objectName: "restoreConfirmButton"
                text: "恢复"
                implicitWidth: 96
                implicitHeight: 36
                onClicked: {
                    root.confirmed(root.backupPath)
                    root.close()
                }

                background: Rectangle {
                    color: confirmButton.hovered ? Theme.accentFillStrong : Theme.accentFill
                    radius: Theme.radiusMd
                }
                contentItem: Text {
                    text: confirmButton.text
                    textFormat: Text.PlainText
                    color: Theme.accentFillInk
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
