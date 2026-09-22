pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."
import "../RoutineWeekdays.js" as Weekdays

// 单条例行的「重复日」编辑弹窗。从每日例行列表里那条长条上的重复药丸打开。
// 独立成一个弹窗，是因为星期选择放在新增表单里会把表单撑成三行，
// 而且新增和改重复日本来就是两件事：先建规则，之后想改再改。
Popup {
    id: root

    // Basic 风格的默认调色板在夜间主题下是白底米白字，和其它弹窗一样必须接管。
    palette.text: Theme.inputInk
    palette.windowText: Theme.controlInk
    palette.buttonText: Theme.controlInk
    objectName: "routineWeekdayDialog"

    property var routineManagerRef: null
    // 正在编辑的例行；id <= 0 表示没有目标，保存会被挡下。
    property int routineId: -1
    property string routineTitle: ""
    // 弹窗里的选择是草稿：点「保存」才写库，点「取消」或按 Esc 原样丢弃。
    property int selectedWeekdays: Weekdays.EVERY_DAY
    property string errorText: ""

    signal weekdaysSaved(int routineId, int weekdays)

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(360, parent ? Math.max(300, parent.width - 48) : 360)
    implicitHeight: layout.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 0.96
                to: 1.0
                duration: Theme.reduceMotion ? 0 : 160
                easing.type: Easing.OutQuad
            }
            OpacityAnimator {
                from: 0
                to: 1
                duration: Theme.reduceMotion ? 0 : 160
                easing.type: Easing.OutQuad
            }
        }
    }

    exit: Transition {
        OpacityAnimator {
            from: 1
            to: 0
            duration: Theme.reduceMotion ? 0 : 140
            easing.type: Easing.InQuad
        }
    }

    Overlay.modal: Rectangle {
        color: Theme.dialogScrim
        opacity: root.opened ? 1 : 0

        Behavior on opacity {
            OpacityAnimator {
                duration: Theme.reduceMotion ? 0 : 160
                easing.type: Easing.InOutQuad
            }
        }
    }

    // 由列表行调用：带上这条例行当前的重复日，作为草稿的起点。
    function openFor(routine) {
        var id = Number(routine && routine.id)
        if (!(id > 0)) {
            return
        }

        root.routineId = id
        root.routineTitle = String(routine.title || "")
        root.selectedWeekdays = Weekdays.normalize(routine.weekdays)
        root.errorText = ""
        root.open()
    }

    function toggleWeekday(bit) {
        root.selectedWeekdays = Weekdays.toggle(root.selectedWeekdays, bit)
        if (root.selectedWeekdays > 0) {
            root.errorText = ""
        }
    }

    function save() {
        if (!root.routineManagerRef || !root.routineManagerRef.setRoutineWeekdays) {
            root.errorText = "每日例行服务不可用"
            return
        }
        if (root.routineId <= 0) {
            root.errorText = "找不到要修改的例行任务"
            return
        }
        // 一天都不选的例行永远不会生成任务。服务层也会拒绝，这里先拦是为了说清原因，
        // 而不是让用户收到一句笼统的「保存失败」。
        if (root.selectedWeekdays <= 0) {
            root.errorText = "至少选择一个重复的星期"
            return
        }

        if (root.routineManagerRef.setRoutineWeekdays(root.routineId, root.selectedWeekdays)) {
            root.weekdaysSaved(root.routineId, root.selectedWeekdays)
            root.close()
        } else {
            root.errorText = "重复日保存失败，请重试"
        }
    }

    background: Rectangle {
        radius: Theme.radiusMd
        color: Theme.glassDialog
        border.color: Theme.border
        border.width: 1
        layer.enabled: true
        layer.effect: MultiEffect {
            autoPaddingEnabled: true
            shadowEnabled: true
            shadowColor: Theme.shadow
            shadowOpacity: 0.14
            shadowBlur: 0.20
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 4
        }
    }

    contentItem: ColumnLayout {
        id: layout

        spacing: Theme.space12

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space16
            spacing: 2

            Text {
                text: "重复"
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontLg
                font.bold: true
            }

            Text {
                Layout.fillWidth: true
                objectName: "routineWeekdayDialogSubtitle"
                text: root.routineTitle
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
                elide: Text.ElideRight
            }
        }

        // 七个圆点：选中是实心强调色，未选中只有一圈细边，隔着屏幕也能数出选了哪几天。
        RowLayout {
            objectName: "routineWeekdayDialogRow"

            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space8

            Repeater {
                model: Weekdays.DAYS

                delegate: Button {
                    id: weekdayChip

                    // delegate 显式声明消费的模型角色（pragma ComponentBehavior: Bound）。
                    required property var modelData
                    required property int index

                    readonly property bool daySelected: (root.selectedWeekdays & weekdayChip.modelData.bit) !== 0

                    // 编号按 index 拼，0 就是周一，正好等于 QDate::dayOfWeek() - 1，测试里好对照。
                    objectName: "routineWeekdayChip" + weekdayChip.index
                    text: weekdayChip.modelData.shortLabel
                    implicitWidth: 34
                    implicitHeight: 34
                    Accessible.name: weekdayChip.modelData.fullLabel
                    Accessible.description: weekdayChip.daySelected
                        ? qsTr("已选中，点击取消这一天")
                        : qsTr("未选中，点击加上这一天")
                    // 不用 Button 自带的 checkable：checked 由 daySelected 单向反映掩码，
                    // 控件自行翻转 checked 会把绑定打断，之后掩码再变界面就不跟了。
                    onClicked: root.toggleWeekday(weekdayChip.modelData.bit)

                    background: Rectangle {
                        radius: height / 2
                        color: weekdayChip.daySelected
                            ? Theme.accent
                            : (weekdayChip.hovered ? Theme.glassHover : Theme.glassHoverIdle)
                        border.color: weekdayChip.daySelected ? Theme.accentStrong : Theme.border
                        border.width: 1

                        // 未选中的起点用 glassHoverIdle（同色零透明）而不是 transparent：
                        // transparent 是黑基色，过渡中间帧会闪一道灰。
                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.reduceMotion ? 0 : 120
                                easing.type: Easing.OutQuad
                            }
                        }
                    }

                    contentItem: Text {
                        text: weekdayChip.text
                        textFormat: Text.PlainText
                        color: weekdayChip.daySelected ? Theme.accentForeground : Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        font.weight: weekdayChip.daySelected ? Font.Medium : Font.Normal
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        // 常用组合一键到位。之前不做是因为塞在新增表单那一行里太挤，
        // 挪进独立弹窗就有地方了：从「每天」改成「工作日」原本要点掉两天。
        RowLayout {
            objectName: "routineWeekdayPresetRow"

            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space8

            Repeater {
                model: [
                    { label: "每天", mask: Weekdays.EVERY_DAY },
                    { label: "工作日", mask: Weekdays.MON_TO_FRI },
                    { label: "周末", mask: Weekdays.WEEKEND }
                ]

                delegate: Button {
                    id: presetButton

                    required property var modelData

                    readonly property bool presetActive: root.selectedWeekdays === presetButton.modelData.mask

                    objectName: "routineWeekdayPreset" + presetButton.modelData.mask
                    text: presetButton.modelData.label
                    implicitWidth: 64
                    implicitHeight: Theme.controlHeightSm
                    Accessible.name: qsTr("设为%1").arg(presetButton.modelData.label)
                    onClicked: {
                        root.selectedWeekdays = presetButton.modelData.mask
                        root.errorText = ""
                    }

                    background: Rectangle {
                        radius: height / 2
                        color: presetButton.presetActive
                            ? Theme.accentFill
                            : (presetButton.hovered ? Theme.glassHover : Theme.glassHoverIdle)
                        border.color: presetButton.presetActive ? Theme.accentStrong : Theme.border
                        border.width: 1

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.reduceMotion ? 0 : 120
                                easing.type: Easing.OutQuad
                            }
                        }
                    }

                    contentItem: Text {
                        text: presetButton.text
                        textFormat: Text.PlainText
                        color: presetButton.presetActive ? Theme.accentFillInk : Theme.inkSoft
                        font.pixelSize: Theme.fontSm
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            Item { Layout.fillWidth: true }

            Text {
                objectName: "routineWeekdayDialogSummary"
                text: Weekdays.text(root.selectedWeekdays)
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.bottomMargin: Theme.space16
            spacing: Theme.space8

            Label {
                Layout.fillWidth: true
                objectName: "routineWeekdayDialogError"
                text: root.errorText
                textFormat: Text.PlainText
                color: Theme.danger
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
            }

            Button {
                id: cancelButton
                objectName: "routineWeekdayCancelButton"

                text: qsTr("取消")
                implicitWidth: 64
                implicitHeight: Theme.controlHeightMd
                onClicked: root.close()

                background: Rectangle {
                    radius: Theme.radiusSm
                    color: cancelButton.hovered || cancelButton.pressed ? Theme.glassHover : Theme.glassCard
                    border.color: Theme.border
                    border.width: 1
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
                id: saveButton
                objectName: "routineWeekdaySaveButton"

                text: qsTr("保存")
                implicitWidth: 64
                implicitHeight: Theme.controlHeightMd
                onClicked: root.save()

                background: Rectangle {
                    radius: Theme.radiusSm
                    color: saveButton.hovered || saveButton.pressed ? Theme.accentFillStrong : Theme.accentFill
                    border.color: Theme.accent
                    border.width: 1
                }

                contentItem: Text {
                    text: saveButton.text
                    textFormat: Text.PlainText
                    // 淡罩底上不能用近白的 surface 当字色，会直接消失。
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
