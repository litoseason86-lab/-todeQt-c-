import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

Popup {
    id: root

    property bool acknowledgedOnce: false

    signal acknowledged()

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    width: Math.min(560, parent ? Math.max(320, parent.width - Theme.space32) : 560)
    height: Math.min(contentColumn.implicitHeight,
                     parent ? Math.max(0, parent.height - Theme.space32) : 620)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    function acknowledge() {
        if (root.acknowledgedOnce) {
            return
        }
        root.acknowledgedOnce = true
        root.acknowledged()
        root.close()
    }

    onOpened: {
        // 失败写盘后主入口会重新打开同一实例，此时允许用户再次明确确认。
        root.acknowledgedOnce = false
        acknowledgeButton.forceActiveFocus()
    }

    Overlay.modal: Rectangle {
        color: Theme.modalScrim
    }

    background: Rectangle {
        color: Theme.glassBlurAllowed ? Theme.glassDialog : Theme.glassSolidCard
        border.color: Theme.glassBorder
        border.width: 1
        radius: Theme.radiusLg
    }

    contentItem: ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space16

        Text {
            id: titleText
            objectName: "naturalCompletionNoticeTitle"

            Layout.fillWidth: true
            Layout.leftMargin: Theme.space24
            Layout.rightMargin: Theme.space24
            Layout.topMargin: Theme.space24
            text: qsTr("完整番茄计数规则已更新")
            textFormat: Text.PlainText
            color: Theme.inkStrong
            font.pixelSize: Theme.fontXl
            font.weight: Font.Bold
            wrapMode: Text.WordWrap
        }

        Text {
            id: bodyText
            objectName: "naturalCompletionNoticeBody"

            Layout.fillWidth: true
            Layout.leftMargin: Theme.space24
            Layout.rightMargin: Theme.space24
            text: qsTr("升级后，只有自然计时到点的番茄会计入番茄数量、长期目标和相关统计。手动提前停止仍会保留专注时长，但不计为完整番茄。历史记录已按兼容规则保留，因此升级日前后的数字口径可能不同。")
            textFormat: Text.PlainText
            color: Theme.ink
            font.pixelSize: Theme.fontMd
            wrapMode: Text.WordWrap
        }

        Button {
            id: acknowledgeButton
            objectName: "naturalCompletionNoticeAcknowledgeButton"

            Layout.alignment: Qt.AlignRight
            Layout.rightMargin: Theme.space24
            Layout.bottomMargin: Theme.space24
            Layout.minimumWidth: 96
            Layout.minimumHeight: 44
            implicitWidth: 96
            implicitHeight: 44
            text: qsTr("知道了")
            activeFocusOnTab: true
            Accessible.name: text
            onClicked: root.acknowledge()
            Keys.onReturnPressed: event => {
                root.acknowledge()
                event.accepted = true
            }
            Keys.onEnterPressed: event => {
                root.acknowledge()
                event.accepted = true
            }
            Keys.onSpacePressed: event => {
                root.acknowledge()
                event.accepted = true
            }

            background: Rectangle {
                color: acknowledgeButton.pressed ? Theme.accentFillStrong
                                                  : (acknowledgeButton.hovered
                                                     ? Theme.accentFillStrong : Theme.accentFill)
                border.color: acknowledgeButton.activeFocus ? Theme.focusRing : Theme.accentFillStrong
                border.width: acknowledgeButton.activeFocus ? 2 : 1
                radius: Theme.radiusMd
            }

            contentItem: Text {
                text: acknowledgeButton.text
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
