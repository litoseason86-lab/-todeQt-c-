pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../LogicalDay.js" as LogicalDay

Control {
    id: root

    property alias text: dateField.text
    // 页头浮在壁纸上，用玻璃底与相邻按钮一致；弹窗里的实底面上仍用不透明控件色。
    property bool translucent: false
    readonly property bool valid: LogicalDay.parseIsoDate(root.text) !== null
    signal edited()

    // 宽度交给内容：写死宽度会让日期居中后左右各空出一大块，两条边界离文字很远。
    implicitHeight: Theme.controlHeightMd
    padding: 3

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

        // 箭头是次级控件：常态用弱色，指向它时才提到正文色，禁用时进一步弱化。
        readonly property color chevronColor: !dayButton.enabled
                                              ? Theme.inkMuted
                                              : (dayButton.hovered || dayButton.down ? Theme.ink : Theme.inkSoft)

        // 按钮内缩成独立分段：悬停底色不再顶到外框边线上。
        Layout.preferredWidth: 34
        Layout.fillHeight: true
        Layout.topMargin: 1
        Layout.bottomMargin: 1
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
            // 悬停与按下必须是两档：只有一档时按下去没有任何反馈。
            // 同上：起点必须与悬停色同色零透明，否则动画会插出一道灰影。
            color: dayButton.down ? Theme.surfaceSunken
                                  : (dayButton.hovered ? Theme.glassHover : Theme.glassHoverIdle)
            border.width: dayButton.visualFocus ? 2 : 0
            border.color: Theme.focusRing

            Behavior on color {
                ColorAnimation { duration: Theme.reduceMotion ? 0 : 120 }
            }
        }
        contentItem: Item {
            // 两段细线组成箭头，避免字体替换让 ‹ / › 的位置与粗细漂移。
            Rectangle {
                anchors.centerIn: parent
                width: 7
                height: 7
                rotation: dayButton.direction < 0 ? -45 : 135
                color: "transparent"
                scale: dayButton.down ? 0.88 : 1.0
                Rectangle { width: 1.5; height: parent.height; radius: 0.75; color: dayButton.chevronColor }
                Rectangle { width: parent.width; height: 1.5; radius: 0.75; color: dayButton.chevronColor }

                Behavior on scale {
                    NumberAnimation { duration: Theme.reduceMotion ? 0 : 90; easing.type: Easing.OutQuad }
                }
            }
        }
    }

    background: Rectangle {
        radius: Theme.radiusLg
        color: root.translucent ? Theme.glassCard : Theme.controlSurface
        border.width: dateField.activeFocus ? 2 : 1
        border.color: !root.valid
                      ? Theme.dangerBorder
                      : (dateField.activeFocus ? Theme.focusRing
                                               : (root.translucent ? Theme.glassBorder : Theme.border))
    }

    contentItem: RowLayout {
        spacing: 0

        // 按实际字形测量，宽度随主题字体变化仍然正确，不靠估一个常数。
        TextMetrics {
            id: dateMetrics
            font: dateField.font
            text: "2026-09-10"
        }

        DayButton { objectName: "previousDateButton"; direction: -1 }

        TextField {
            id: dateField
            objectName: "isoDateField"
            Layout.fillWidth: true
            Layout.fillHeight: true
            // 文字宽度之外还要留出自身内边距，另加 4px 余量：字形测量与实际排版
            // 有亚像素差，贴着算会把首字符裁掉半个。
            implicitWidth: Math.ceil(dateMetrics.width) + leftPadding + rightPadding + 4
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

        DayButton { objectName: "nextDateButton"; direction: 1 }
    }
}
