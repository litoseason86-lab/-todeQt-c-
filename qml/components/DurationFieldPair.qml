pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 「N 小时 M 分钟」输入对。今日专注目标与任务预计用时共用它——两处要长得一样、
// 越界规则也一样，各抄一份必然漂移，所以做成一个组件由构造保证一致。
//
// 数据流是单向的：totalMinutes 只负责把初值灌进两个输入框，用户输入的结果从
// enteredMinutes 读出。宿主的提交时机各不相同（内联编辑器点保存、对话框点确定），
// 双向绑定只会让「什么时候写回」变得含糊。
//
// 校验分工：这里只管形式合法性（能不能解析、有没有超过上限），
// 语义下限（目标至少 1 分钟 / 预计用时允许留空）留给宿主，因为文案和含义都不同。
RowLayout {
    id: root

    // 初值（分钟）。改它会重灌输入框，除非用户正在这两个框里打字。
    property int totalMinutes: 0
    // 上限（分钟）。默认 24 小时，与「今日专注目标」同一上界。
    property int maximumMinutes: 24 * 60
    // 紧凑模式：横排内联场景用固定窄宽，宽松模式让字段撑满。
    property bool compact: false
    // objectName 前缀，让不同宿主里的字段能被各自的测试定位。
    property string namePrefix: "duration"
    property string accessiblePrefix: qsTr("时长")
    // 分钟框之后的 Tab 下一站；留空则走自然顺序。
    property Item tabTarget: null
    // 让宿主把 Tab 环闭合回第一个输入框。
    readonly property alias firstField: hourField

    readonly property int maximumHours: Math.floor(root.maximumMinutes / 60)
    // 两个框都填了且各自通过 validator。空串不算合法输入。
    // 注意 QIntValidator 的行为：位数与上限相同的越界值（上限 2 小时时输入 9）算
    // Intermediate，输入框会照收，只是 acceptableInput 为假——所以越界必须由下面
    // 的 validationError 兜住，不能指望 validator 拦在输入那一步。
    readonly property bool acceptable: hourField.acceptableInput && minuteField.acceptableInput
                                       && hourField.text.length > 0 && minuteField.text.length > 0
    // 两个框都非空时的字面总分钟数；用于给出「超过上限」这种具体提示。空框时为 -1。
    readonly property int rawMinutes: (hourField.text.length > 0 && minuteField.text.length > 0)
                                      ? Number(hourField.text) * 60 + Number(minuteField.text)
                                      : -1
    // 当前输入的总分钟数；输入不合法时为 0。
    readonly property int enteredMinutes: root.acceptable ? root.rawMinutes : 0
    // 形式校验结果。空串表示可以提交。
    readonly property string validationError: {
        if (root.rawMinutes < 0 || isNaN(root.rawMinutes)) {
            return qsTr("请输入有效的小时和分钟")
        }
        if (root.rawMinutes > root.maximumMinutes) {
            // 卡在整点上限时单独提示，否则用户只会反复试分钟数。
            if (Number(hourField.text) === root.maximumHours) {
                return qsTr("%1 小时是上限，分钟必须为 0").arg(root.maximumHours)
            }
            return qsTr("不能超过 %1 小时").arg(root.maximumHours)
        }
        if (!root.acceptable) {
            return qsTr("请输入有效的小时和分钟")
        }
        return ""
    }

    // 在任一输入框里按下回车。宿主据此触发自己的提交动作。
    signal accepted()

    spacing: Theme.space8

    onTotalMinutesChanged: root.reload()
    Component.onCompleted: root.reload()

    // 把 totalMinutes 灌进两个输入框。用户正在编辑时跳过，避免和光标打架。
    function reload() {
        if (hourField.activeFocus || minuteField.activeFocus) {
            return
        }
        const safe = Math.max(0, Math.min(root.maximumMinutes, Number(root.totalMinutes || 0)))
        hourField.text = String(Math.floor(safe / 60))
        minuteField.text = String(safe % 60)
    }

    function focusFirstField() {
        hourField.forceActiveFocus()
        hourField.selectAll()
    }

    TextField {
        id: hourField

        objectName: root.namePrefix + "HourField"
        Layout.fillWidth: !root.compact
        Layout.preferredWidth: root.compact ? 56 : -1
        Layout.preferredHeight: root.compact ? 32 : 38
        activeFocusOnTab: true
        selectByMouse: true
        horizontalAlignment: TextInput.AlignHCenter
        inputMethodHints: Qt.ImhDigitsOnly
        maximumLength: 2
        font.pixelSize: Theme.fontMd
        color: Theme.inkStrong
        Accessible.name: root.accessiblePrefix + qsTr("小时")
        validator: IntValidator { bottom: 0; top: root.maximumHours }
        KeyNavigation.tab: minuteField
        Keys.onReturnPressed: root.accepted()
        Keys.onEnterPressed: root.accepted()

        background: Rectangle {
            radius: Theme.radiusMd
            color: Theme.surfaceSunken
            border.width: hourField.activeFocus ? 2 : 1
            border.color: hourField.activeFocus ? Theme.accent : Theme.borderSubtle
        }
    }

    Label {
        text: qsTr("小时")
        color: Theme.inkSoft
        font.pixelSize: Theme.fontSm
    }

    TextField {
        id: minuteField

        objectName: root.namePrefix + "MinuteField"
        Layout.fillWidth: !root.compact
        Layout.preferredWidth: root.compact ? 56 : -1
        Layout.preferredHeight: root.compact ? 32 : 38
        activeFocusOnTab: true
        selectByMouse: true
        horizontalAlignment: TextInput.AlignHCenter
        inputMethodHints: Qt.ImhDigitsOnly
        maximumLength: 2
        font.pixelSize: Theme.fontMd
        color: Theme.inkStrong
        Accessible.name: root.accessiblePrefix + qsTr("分钟")
        validator: IntValidator { bottom: 0; top: 59 }
        KeyNavigation.tab: root.tabTarget
        Keys.onReturnPressed: root.accepted()
        Keys.onEnterPressed: root.accepted()

        background: Rectangle {
            radius: Theme.radiusMd
            color: Theme.surfaceSunken
            border.width: minuteField.activeFocus ? 2 : 1
            border.color: minuteField.activeFocus ? Theme.accent : Theme.borderSubtle
        }
    }

    Label {
        text: qsTr("分钟")
        color: Theme.inkSoft
        font.pixelSize: Theme.fontSm
    }
}
