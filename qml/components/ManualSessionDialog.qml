pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

// 手工补录 / 修改一条专注记录。
//
// 忘记开计时、中途强退、计时器绑错任务——这些时间此前永久丢失，而且连带影响统计、
// 周复盘和长期目标。这个弹窗是那块缺失底板的入口。
//
// 补录出来的记录一律记为自由计时，不伪装成番茄（判定在 FocusHistoryService）。
// 这里只负责把「哪天、几点开始、多久、算在哪个任务上」问清楚。
Popup {
    id: root

    // 输入框字色必须接管：Basic 风格默认 palette.text 写死深灰，夜间主题下看不见。
    palette.text: Theme.inputInk
    palette.placeholderText: Theme.inputPlaceholderInk
    palette.highlight: Theme.inputSelection
    palette.highlightedText: Theme.inputSelectedInk
    // 下拉面板与选项行；不接管的话夜间主题下是白底配米白字。
    palette.window: Theme.inputPopupSurface
    palette.mid: Theme.inputPopupBorder
    palette.light: Theme.inputPopupHighlight
    palette.midlight: Theme.inputPopupHighlight
    // 未自定义 background 的下拉框/输入框，闭合状态的底与文字也得接管。
    palette.base: Theme.controlSurface
    palette.button: Theme.controlSurface
    palette.buttonText: Theme.controlInk
    // GroupBox 标题、勾选框文字，以及没显式写 color 的 Label 都吃这个。
    palette.windowText: Theme.controlInk

    // 可选任务列表，元素形如 { id, title }。空列表时只能记「不关联任务」。
    property var tasks: []
    // 编辑中的记录 id；-1 表示新建。
    property int editingSessionId: -1
    property string errorText: ""
    property var originalStart: null
    property int originalDurationSeconds: 0
    property bool durationEdited: false
    property var editHandler: null
    property bool originalIsRest: false
    property int originalTaskId: -1

    readonly property bool editing: root.editingSessionId > 0
    // 第一项恒为「不关联任务」，对应统计里的「未关联专注」。
    readonly property var taskOptions: [{ id: -1, title: qsTr("不关联任务") }].concat(root.tasks)

    // 提交由宿主注入：返回空串表示成功，否则是可以直接显示的失败原因。
    property var submitHandler: null

    signal submitted(int sessionId, date startDateTime, int durationMinutes, int taskId)

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(460, parent ? Math.max(320, parent.width - 64) : 460)
    height: panel.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0

    Overlay.modal: Rectangle { color: Theme.dialogScrim }

    background: Rectangle {
        id: panel
        objectName: "manualSessionPanel"

        implicitWidth: root.width
        implicitHeight: contentColumn.implicitHeight
        color: Theme.glassDialog
        border.color: Theme.border
        border.width: 1
        radius: Theme.radiusLg
    }

    function openForAdd(isoDate, taskList) {
        root.editingSessionId = -1
        root.originalIsRest = false
        recordTypeCombo.currentIndex = 0
        root.originalStart = null
        root.durationEdited = false
        root.tasks = taskList || []
        root.errorText = ""
        dateField.text = String(isoDate || "")
        hourField.text = "09"
        minuteField.text = "00"
        durationFields.totalMinutes = 30
        durationFields.reload()
        taskCombo.currentIndex = 0
        root.open()
        dateField.forceActiveFocus()
    }

    // 候选任务有条数上限，原归属任务未必在里面。缺了它下拉会停在「不关联任务」，
    // 保存时就把这条记录静默改成了未关联。
    function withOriginalTask(taskList, session) {
        if (root.originalTaskId <= 0)
            return taskList
        for (var i = 0; i < taskList.length; ++i) {
            if (Number(taskList[i].id) === root.originalTaskId)
                return taskList
        }
        return [{ id: root.originalTaskId, title: String(session.taskTitle || "") }].concat(taskList)
    }

    function openForEdit(session, taskList) {
        root.editingSessionId = Number(session.id || -1)
        root.errorText = ""
        // startTime 是 ISO 字符串（服务层原样返回），拆成日期与时分两段填。
        const start = new Date(String(session.startTime || ""))
        root.originalIsRest = Boolean(session.isRest)
        recordTypeCombo.currentIndex = root.originalIsRest ? 1 : 0
        root.originalTaskId = Number(session.taskId) > 0 ? Number(session.taskId) : -1
        root.tasks = root.withOriginalTask(taskList || [], session)
        root.originalStart = start
        root.originalDurationSeconds = Number(session.durationSeconds) || 0
        root.durationEdited = false
        if (!isNaN(start.getTime())) {
            dateField.text = Qt.formatDate(start, "yyyy-MM-dd")
            hourField.text = ("0" + start.getHours()).slice(-2)
            minuteField.text = ("0" + start.getMinutes()).slice(-2)
        }
        durationFields.totalMinutes = Math.round(Number(session.durationSeconds || 0) / 60)
        durationFields.reload()
        taskCombo.currentIndex = 0
        for (var i = 0; i < root.taskOptions.length; ++i) {
            if (Number(root.taskOptions[i].id) === root.originalTaskId) {
                taskCombo.currentIndex = i
                break
            }
        }
        root.open()
        dateField.forceActiveFocus()
    }

    function submit() {
        const dateParts = String(dateField.text).split("-")
        const year = Number(dateParts[0])
        const month = Number(dateParts[1])
        const day = Number(dateParts[2])
        if (!/^\d{4}-\d{2}-\d{2}$/.test(String(dateField.text))
                || year < 2000 || year > 2100 || month < 1 || month > 12 || day < 1 || day > 31) {
            root.errorText = qsTr("日期格式应为 YYYY-MM-DD")
            dateField.forceActiveFocus()
            return
        }
        if (!hourField.acceptableInput || !minuteField.acceptableInput
                || hourField.text.length === 0 || minuteField.text.length === 0) {
            root.errorText = qsTr("请输入有效的开始时刻")
            hourField.forceActiveFocus()
            return
        }
        if (durationFields.validationError.length > 0) {
            root.errorText = durationFields.validationError
            durationFields.focusFirstField()
            return
        }

        const start = new Date(year, month - 1, day,
                              Number(hourField.text), Number(minuteField.text), 0)
        // Date 会把 2 月 31 日自动挪到 3 月，必须回读年月日，不能仅判断 NaN。
        if (isNaN(start.getTime()) || start.getFullYear() !== year
                || start.getMonth() !== month - 1 || start.getDate() !== day) {
            root.errorText = qsTr("日期无效")
            dateField.forceActiveFocus()
            return
        }

        const taskId = taskCombo.currentIndex >= 0
                       && taskCombo.currentIndex < root.taskOptions.length
                     ? Number(root.taskOptions[taskCombo.currentIndex].id) : -1

        if (root.editing && root.editHandler) {
            var changes = {}
            if (!root.originalStart || Qt.formatDateTime(start, "yyyy-MM-dd hh:mm")
                    !== Qt.formatDateTime(root.originalStart, "yyyy-MM-dd hh:mm")) {
                changes.startTime = start
            }
            // 未触碰时长输入时不提交整数分钟，数据库保留原来的秒数。
            if (root.durationEdited && durationFields.enteredMinutes !== Math.round(root.originalDurationSeconds / 60))
                changes.durationSeconds = durationFields.enteredMinutes * 60
            if ((recordTypeCombo.currentIndex === 1) !== root.originalIsRest)
                changes.isRest = recordTypeCombo.currentIndex === 1
            if (recordTypeCombo.currentIndex === 0 && taskId !== root.originalTaskId)
                changes.taskId = taskId
            // qmllint disable use-proper-function
            const failure = String(root.editHandler(root.editingSessionId, changes) || "")
            // qmllint enable use-proper-function
            if (failure.length > 0) {
                root.errorText = failure
                return
            }
            root.close()
            return
        }

        if (root.submitHandler) {
            // submitHandler 由宿主在运行时注入为函数，静态工具只能看到 var 属性。
            // qmllint disable use-proper-function
            const failure = String(root.submitHandler(root.editingSessionId, start,
                                                      durationFields.enteredMinutes, taskId) || "")
            // qmllint enable use-proper-function
            if (failure.length > 0) {
                root.errorText = failure
                return
            }
        } else {
            root.submitted(root.editingSessionId, start, durationFields.enteredMinutes, taskId)
        }
        root.close()
    }

    ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space12

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space16
            text: root.editing ? qsTr("修改时间记录") : qsTr("补录专注记录")
            textFormat: Text.PlainText
            color: Theme.inkStrong
            font.pixelSize: Theme.fontXl
            font.weight: Font.Bold
        }

        ComboBox {
            id: recordTypeCombo
            objectName: "sessionRecordType"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            visible: root.editing
            model: [qsTr("专注 · 计入专注统计"), qsTr("休息 · 不计入专注统计")]
            Accessible.name: qsTr("记录类型")
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space8

            Text {
                text: qsTr("日期")
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
            }

            TextField {
                id: dateField
                objectName: "manualSessionDateField"
                Layout.preferredWidth: 128
                implicitHeight: 38
                color: Theme.inkStrong
                placeholderText: "YYYY-MM-DD"
                placeholderTextColor: Theme.inkMuted
                inputMethodHints: Qt.ImhDate

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: Theme.surfaceSunken
                    border.width: dateField.activeFocus ? 2 : 1
                    border.color: dateField.activeFocus ? Theme.accent : Theme.borderSubtle
                }
            }

            Text {
                text: qsTr("开始")
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
            }

            TextField {
                id: hourField
                objectName: "manualSessionHourField"
                Layout.preferredWidth: 48
                implicitHeight: 38
                horizontalAlignment: TextInput.AlignHCenter
                inputMethodHints: Qt.ImhDigitsOnly
                maximumLength: 2
                color: Theme.inkStrong
                validator: IntValidator { bottom: 0; top: 23 }

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: Theme.surfaceSunken
                    border.width: hourField.activeFocus ? 2 : 1
                    border.color: hourField.activeFocus ? Theme.accent : Theme.borderSubtle
                }
            }

            Text {
                text: ":"
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
            }

            TextField {
                id: minuteField
                objectName: "manualSessionMinuteField"
                Layout.preferredWidth: 48
                implicitHeight: 38
                horizontalAlignment: TextInput.AlignHCenter
                inputMethodHints: Qt.ImhDigitsOnly
                maximumLength: 2
                color: Theme.inkStrong
                validator: IntValidator { bottom: 0; top: 59 }

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: Theme.surfaceSunken
                    border.width: minuteField.activeFocus ? 2 : 1
                    border.color: minuteField.activeFocus ? Theme.accent : Theme.borderSubtle
                }
            }

            Item { Layout.fillWidth: true }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space8

            Text {
                text: qsTr("时长")
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
            }

            // 与任务预计用时、今日专注目标、长期目标同一个输入组件。
            DurationFieldPair {
                id: durationFields
                objectName: "manualSessionDurationFields"
                namePrefix: "manualSessionDuration"
                accessiblePrefix: qsTr("专注时长")
                compact: true
                onAccepted: root.submit()
                onUserEdited: root.durationEdited = true
            }

            Item { Layout.fillWidth: true }
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            visible: root.editing && root.originalDurationSeconds % 60 !== 0
            text: qsTr("原计时 %1 秒，未修改时长时保留原值").arg(root.originalDurationSeconds)
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space4
            visible: recordTypeCombo.currentIndex === 0

            Text {
                text: qsTr("算在哪个任务上")
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
            }

            ComboBox {
                id: taskCombo
                objectName: "manualSessionTaskCombo"
                Layout.fillWidth: true
                implicitHeight: 40
                model: root.taskOptions
                textRole: "title"
                currentIndex: 0
            }
        }

        Text {
            objectName: "manualSessionError"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            visible: root.errorText.length > 0
            text: root.errorText
            textFormat: Text.PlainText
            color: Theme.danger
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.AlertMessage
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.bottomMargin: Theme.space16
            spacing: Theme.space8

            Item { Layout.fillWidth: true }

            Button {
                objectName: "manualSessionCancelButton"
                text: qsTr("取消")
                implicitWidth: 84
                implicitHeight: 36
                onClicked: root.close()

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: Qt.rgba(0, 0, 0, 0)
                    border.color: Theme.border
                    border.width: 1
                }
            }

            Button {
                id: confirmButton
                objectName: "manualSessionConfirmButton"
                text: root.editing ? qsTr("保存") : qsTr("补录")
                implicitWidth: 84
                implicitHeight: 36
                onClicked: root.submit()

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: confirmButton.pressed ? Theme.accentFillStrong : Theme.accentFill
                    // 与目标页「新建」同理：淡罩压在弹窗面上没有边界，补一圈同色描边。
                    border.color: Theme.accentFillInk
                    border.width: 1
                }

                contentItem: Text {
                    text: confirmButton.text
                    textFormat: Text.PlainText
                    color: Theme.accentFillInk
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
