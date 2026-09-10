pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../LogicalDay.js" as LogicalDay

Control {
    id: root

    property alias text: dateField.text
    readonly property bool valid: LogicalDay.parseIsoDate(root.text) !== null
    signal edited()

    implicitWidth: 244
    implicitHeight: 40
    padding: 2

    function step(days) {
        var date = LogicalDay.parseIsoDate(root.text)
        if (!date) return
        // 使用日历加减，跨月、闰年与夏令时切换都由日期对象处理。
        date.setDate(date.getDate() + days)
        var next = Qt.formatDate(date, "yyyy-MM-dd")
        if (LogicalDay.parseIsoDate(next)) {
            root.text = next
            root.edited()
        }
    }

    component DayButton: Button {
        id: dayButton
        required property int direction

        Layout.preferredWidth: 36
        Layout.fillHeight: true
        enabled: root.valid
        focusPolicy: Qt.StrongFocus
        hoverEnabled: true
        Accessible.name: direction < 0 ? qsTr("前一天") : qsTr("后一天")
        ToolTip.visible: hovered || visualFocus
        ToolTip.text: Accessible.name
        ToolTip.delay: 500
        onClicked: root.step(direction)

        background: Rectangle {
            radius: Theme.radiusMd
            color: dayButton.down || dayButton.hovered ? Theme.surfaceSunken : "transparent"
            border.width: dayButton.visualFocus ? 2 : 0
            border.color: Theme.focusRing
        }
        contentItem: Item {
            // 两段细线组成箭头，避免字体替换让 ‹ / › 的位置与粗细漂移。
            Rectangle {
                anchors.centerIn: parent
                width: 7
                height: 7
                rotation: dayButton.direction < 0 ? -45 : 135
                color: "transparent"
                Rectangle { width: 1.5; height: parent.height; radius: 0.75; color: dayButton.enabled ? Theme.ink : Theme.inkMuted }
                Rectangle { width: parent.width; height: 1.5; radius: 0.75; color: dayButton.enabled ? Theme.ink : Theme.inkMuted }
            }
        }
    }

    background: Rectangle {
        radius: Theme.radiusLg
        color: Theme.controlSurface
        border.width: dateField.activeFocus ? 2 : 1
        border.color: !root.valid ? Theme.dangerBorder : (dateField.activeFocus ? Theme.focusRing : Theme.border)
    }

    contentItem: RowLayout {
        spacing: 0

        DayButton { objectName: "previousDateButton"; direction: -1 }

        Rectangle {
            Layout.preferredWidth: 1
            Layout.preferredHeight: 16
            color: Theme.border
        }

        TextField {
            id: dateField
            objectName: "isoDateField"
            Layout.fillWidth: true
            Layout.fillHeight: true
            implicitWidth: 156
            leftPadding: Theme.space8
            rightPadding: Theme.space8
            placeholderText: "YYYY-MM-DD"
            Accessible.name: qsTr("日期，年-月-日")
            Accessible.description: root.valid ? qsTr("输入日期，或使用两侧按钮逐日查看") : qsTr("请输入有效日期，格式为 YYYY-MM-DD")
            color: Theme.inputInk
            // 占位色不能用 inkMuted：它是「占位/禁用」色，在本控件的 controlSurface 底上
            // 只有 3.1:1（夜间 3.55:1），低于门禁的 4.5:1，格式提示会看不清。
            placeholderTextColor: Theme.inkSoft
            selectionColor: Theme.inputSelection
            selectedTextColor: Theme.inputSelectedInk
            font.pixelSize: Theme.fontMd
            font.weight: Font.Medium
            horizontalAlignment: TextInput.AlignHCenter
            verticalAlignment: TextInput.AlignVCenter
            selectByMouse: true
            maximumLength: 10
            background: Item {}
            onTextEdited: root.edited()
        }

        Rectangle {
            Layout.preferredWidth: 1
            Layout.preferredHeight: 16
            color: Theme.border
        }

        DayButton { objectName: "nextDateButton"; direction: 1 }
    }
}
