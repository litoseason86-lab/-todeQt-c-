pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import ".."
import "../ScheduleWeeks.js" as ScheduleWeeks

// 课表项的新增/编辑弹窗。同一个弹窗承担两种用途，靠 editingEntryId 区分：
// -1 是新增，正数是编辑（此时多出一个删除入口）。
Popup {
    id: root

    // 输入框字色必须接管：Basic 风格默认 palette.text 写死深灰，夜间主题下看不见。
    palette.text: Theme.inputInk
    palette.placeholderText: Theme.inputPlaceholderInk
    palette.highlight: Theme.inputSelection
    palette.highlightedText: Theme.inputSelectedInk
    palette.window: Theme.inputPopupSurface
    palette.mid: Theme.inputPopupBorder
    palette.light: Theme.inputPopupHighlight
    palette.midlight: Theme.inputPopupHighlight
    palette.base: Theme.controlSurface
    palette.button: Theme.controlSurface
    palette.buttonText: Theme.controlInk
    palette.windowText: Theme.controlInk

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(520, parent ? Math.max(300, parent.width - 64) : 520)
    height: Math.min(panel.implicitHeight, parent ? parent.height - 48 : panel.implicitHeight)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    property var scheduleServiceRef: null
    property var categoryManagerRef: null
    property int semesterWeeks: 20
    property var periods: []
    property int editingEntryId: -1
    property string errorText: ""
    property string conflictText: ""
    property var categoryOptions: [{ id: -1, name: "不设置科目", color: "" }]

    signal deleteRequested(int entryId, string title)

    // 节次下拉的显示项。服务返回的节次只有编号与起止分钟数，
    // 这里补出「第 3 节 10:00–10:45」这样的可读标签供 ComboBox 直接用。
    readonly property var periodOptions: {
        var options = []
        for (var i = 0; i < root.periods.length; ++i) {
            var period = root.periods[i]
            options.push({
                label: "第 " + period.index + " 节  "
                       + ScheduleWeeks.formatMinutes(period.startMinutes) + "–"
                       + ScheduleWeeks.formatMinutes(period.endMinutes),
                startMinutes: Number(period.startMinutes),
                endMinutes: Number(period.endMinutes)
            })
        }
        return options
    }

    readonly property var weekdayNames: ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    readonly property var parityNames: ["每周", "仅单周", "仅双周"]
    readonly property bool editing: root.editingEntryId > 0

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"; from: 0.94; to: 1.0
                duration: Theme.reduceMotion ? 0 : 220; easing.type: Easing.OutCubic
            }
            OpacityAnimator {
                from: 0; to: 1
                duration: Theme.reduceMotion ? 0 : 220; easing.type: Easing.OutQuad
            }
        }
    }

    exit: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"; from: 1.0; to: 0.94
                duration: Theme.reduceMotion ? 0 : 220; easing.type: Easing.InQuad
            }
            OpacityAnimator {
                from: 1; to: 0
                duration: Theme.reduceMotion ? 0 : 220; easing.type: Easing.InQuad
            }
        }
    }

    Overlay.modal: Rectangle {
        color: Theme.dialogScrim
        opacity: root.opened ? 1 : 0

        Behavior on opacity {
            OpacityAnimator {
                duration: Theme.reduceMotion ? 0 : 180; easing.type: Easing.InOutQuad
            }
        }
    }

    function refreshCategories() {
        var loaded = []
        if (root.categoryManagerRef && root.categoryManagerRef.getAllCategories) {
            loaded = root.categoryManagerRef.getAllCategories()
        }
        root.categoryOptions = [{ id: -1, name: "不设置科目", color: "" }].concat(loaded)
    }

    function categoryIndexForId(categoryId) {
        for (var i = 0; i < root.categoryOptions.length; ++i) {
            if (Number(root.categoryOptions[i].id) === Number(categoryId)) {
                return i
            }
        }
        return 0
    }

    // 新增：预填调用方点中的那一天与时段，用户少改几个字段。
    function openForNew(weekday, startMinutes) {
        root.editingEntryId = -1
        root.refreshCategories()
        titleField.text = ""
        locationField.text = ""
        weekdayCombo.currentIndex = Math.max(0, Math.min(6, Number(weekday) - 1))
        var start = Number(startMinutes)
        startField.text = ScheduleWeeks.formatMinutes(start)
        // 默认排 45 分钟一节，且不跨零点。
        endField.text = ScheduleWeeks.formatMinutes(Math.min(24 * 60, start + 45))
        weekStartField.text = "1"
        weekEndField.text = String(root.semesterWeeks)
        parityCombo.currentIndex = 0
        categoryCombo.currentIndex = 0
        root.errorText = ""
        root.conflictText = ""
        root.open()
    }

    function openForEdit(entry) {
        root.editingEntryId = Number(entry.id)
        root.refreshCategories()
        titleField.text = String(entry.title || "")
        locationField.text = String(entry.location || "")
        weekdayCombo.currentIndex = Math.max(0, Math.min(6, Number(entry.weekday) - 1))
        startField.text = ScheduleWeeks.formatMinutes(Number(entry.startMinutes))
        endField.text = ScheduleWeeks.formatMinutes(Number(entry.endMinutes))
        weekStartField.text = String(Number(entry.weekStart))
        weekEndField.text = String(Number(entry.weekEnd))
        parityCombo.currentIndex = Math.max(0, Math.min(2, Number(entry.weekParity)))
        categoryCombo.currentIndex = root.categoryIndexForId(entry.categoryId)
        root.errorText = ""
        root.conflictText = ""
        root.open()
    }

    // 收集并校验表单。返回 null 表示校验未通过，errorText 已被写好。
    function collectInput() {
        var title = titleField.text.trim()
        if (title.length === 0) {
            root.errorText = "课程名称不能为空"
            titleField.forceActiveFocus()
            return null
        }

        var startMinutes = ScheduleWeeks.parseMinutes(startField.text)
        if (startMinutes < 0) {
            root.errorText = "开始时间格式应为 HH:mm"
            startField.forceActiveFocus()
            return null
        }
        var endMinutes = ScheduleWeeks.parseMinutes(endField.text)
        if (endMinutes < 0) {
            root.errorText = "结束时间格式应为 HH:mm"
            endField.forceActiveFocus()
            return null
        }
        if (endMinutes <= startMinutes) {
            root.errorText = "结束时间必须晚于开始时间"
            endField.forceActiveFocus()
            return null
        }

        var weekStart = parseInt(weekStartField.text, 10)
        var weekEnd = parseInt(weekEndField.text, 10)
        if (isNaN(weekStart) || isNaN(weekEnd) || weekStart < 1 || weekEnd < 1) {
            root.errorText = "周次必须是大于 0 的整数"
            weekStartField.forceActiveFocus()
            return null
        }
        if (weekEnd < weekStart) {
            root.errorText = "结束周次不能早于开始周次"
            weekEndField.forceActiveFocus()
            return null
        }

        var categoryId = -1
        if (categoryCombo.currentIndex >= 0
                && categoryCombo.currentIndex < root.categoryOptions.length) {
            categoryId = Number(root.categoryOptions[categoryCombo.currentIndex].id || -1)
        }

        return {
            title: title,
            location: locationField.text.trim(),
            weekday: weekdayCombo.currentIndex + 1,
            startMinutes: startMinutes,
            endMinutes: endMinutes,
            weekStart: weekStart,
            weekEnd: weekEnd,
            weekParity: parityCombo.currentIndex,
            categoryId: categoryId
        }
    }

    // 冲突只提示不拦截：同一时段并列两门可选课是真实排法。
    function refreshConflictHint() {
        root.conflictText = ""
        if (!root.scheduleServiceRef) {
            return
        }
        var input = null
        // 校验失败时不提示冲突——那会在用户还没填完时先弹一条无关的话。
        var savedError = root.errorText
        input = root.collectInput()
        root.errorText = savedError
        if (!input) {
            return
        }
        var conflicts = root.scheduleServiceRef.findConflicts(
            input.weekday, input.startMinutes, input.endMinutes,
            input.weekStart, input.weekEnd, input.weekParity, root.editingEntryId)
        if (conflicts.length > 0) {
            root.conflictText = "与「" + conflicts[0].title + "」时间重叠，仍可保存"
        }
    }

    function submit() {
        var input = root.collectInput()
        if (!input) {
            return
        }
        if (!root.scheduleServiceRef) {
            root.errorText = "课表服务不可用"
            return
        }

        var succeeded = root.editing
            ? root.scheduleServiceRef.updateEntry(
                  root.editingEntryId, input.title, input.weekday,
                  input.startMinutes, input.endMinutes, input.location,
                  input.categoryId, input.weekStart, input.weekEnd, input.weekParity)
            : root.scheduleServiceRef.addEntry(
                  input.title, input.weekday, input.startMinutes, input.endMinutes,
                  input.location, input.categoryId,
                  input.weekStart, input.weekEnd, input.weekParity)

        if (!succeeded) {
            // 具体原因由服务的 operationFailed 写进 errorText；这里只兜一个通用兜底。
            if (root.errorText.length === 0) {
                root.errorText = "保存失败，请重试"
            }
            return
        }
        root.close()
    }

    Connections {
        target: root.scheduleServiceRef
        ignoreUnknownSignals: true
        enabled: root.visible

        function onOperationFailed(message) {
            root.errorText = String(message || "操作失败")
        }
    }

    Component.onCompleted: root.refreshCategories()

    background: Rectangle {
        id: panel

        objectName: "dialogPanel"
        implicitWidth: root.width
        implicitHeight: contentColumn.implicitHeight
        color: Theme.glassDialog
        border.color: Theme.border
        border.width: 1
        radius: Theme.radiusLg
        layer.enabled: true
        layer.effect: MultiEffect {
            autoPaddingEnabled: true
            shadowEnabled: true
            shadowColor: Theme.shadow
            shadowOpacity: 0.12
            shadowBlur: 0.20
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 4
        }
    }

    contentItem: Flickable {
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        ColumnLayout {
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
                    text: root.editing ? "编辑课程" : "添加课程"
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontLg
                    font.weight: Font.Bold
                }
            }

            FieldLabel { text: "课程名称" }

            StyledField {
                id: titleField

                objectName: "scheduleTitleField"
                placeholderText: "例如：高等数学"
                maximumLength: 60
                hasError: root.errorText.length > 0
                onTextEdited: if (text.trim().length > 0) root.errorText = ""
                Keys.onReturnPressed: root.submit()
                Keys.onEnterPressed: root.submit()
            }

            FieldLabel { text: "地点（可选）" }

            StyledField {
                id: locationField

                objectName: "scheduleLocationField"
                placeholderText: "例如：A101"
                maximumLength: 60
            }

            FieldLabel { text: "星期与时间" }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                spacing: Theme.space8

                StyledCombo {
                    id: weekdayCombo

                    objectName: "scheduleWeekdayCombo"
                    Layout.preferredWidth: 96
                    model: root.weekdayNames
                    onActivated: root.refreshConflictHint()
                }

                StyledField {
                    id: startField

                    objectName: "scheduleStartField"
                    Layout.preferredWidth: 88
                    Layout.fillWidth: false
                    placeholderText: "08:00"
                    inputMethodHints: Qt.ImhPreferNumbers
                    onEditingFinished: root.refreshConflictHint()
                }

                Text {
                    text: "至"
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                }

                StyledField {
                    id: endField

                    objectName: "scheduleEndField"
                    Layout.preferredWidth: 88
                    Layout.fillWidth: false
                    placeholderText: "09:40"
                    inputMethodHints: Qt.ImhPreferNumbers
                    onEditingFinished: root.refreshConflictHint()
                }

                Item { Layout.fillWidth: true }
            }

            // 节次快填：把「第 N 节」的起止时间写进上面两个输入框。
            // 底层始终存起止时间，节次只是录入捷径，因此工作日程也能用同一套字段。
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                spacing: Theme.space8
                visible: root.periods.length > 0

                Text {
                    text: "按节次填充"
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                }

                StyledCombo {
                    id: periodCombo

                    objectName: "schedulePeriodCombo"
                    Layout.fillWidth: true
                    model: root.periodOptions
                    textRole: "label"
                    currentIndex: -1
                    displayText: "选择节次…"

                    onActivated: function (index) {
                        if (index < 0 || index >= root.periodOptions.length) {
                            return
                        }
                        startField.text = ScheduleWeeks.formatMinutes(root.periodOptions[index].startMinutes)
                        endField.text = ScheduleWeeks.formatMinutes(root.periodOptions[index].endMinutes)
                        // 选完立刻回到占位文案，让它保持「一次性动作」而不是一个已选状态。
                        periodCombo.currentIndex = -1
                        root.refreshConflictHint()
                    }
                }
            }

            FieldLabel { text: "生效周次" }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                spacing: Theme.space8

                Text {
                    text: "第"
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                }

                StyledField {
                    id: weekStartField

                    objectName: "scheduleWeekStartField"
                    Layout.preferredWidth: 64
                    Layout.fillWidth: false
                    validator: IntValidator { bottom: 1; top: 60 }
                    inputMethodHints: Qt.ImhDigitsOnly
                    onEditingFinished: root.refreshConflictHint()
                }

                Text {
                    text: "至"
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                }

                StyledField {
                    id: weekEndField

                    objectName: "scheduleWeekEndField"
                    Layout.preferredWidth: 64
                    Layout.fillWidth: false
                    validator: IntValidator { bottom: 1; top: 60 }
                    inputMethodHints: Qt.ImhDigitsOnly
                    onEditingFinished: root.refreshConflictHint()
                }

                Text {
                    text: "周"
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                }

                StyledCombo {
                    id: parityCombo

                    objectName: "scheduleParityCombo"
                    Layout.fillWidth: true
                    model: root.parityNames
                    onActivated: root.refreshConflictHint()
                }
            }

            FieldLabel { text: "科目分类（可选）" }

            StyledCombo {
                id: categoryCombo

                objectName: "scheduleCategoryCombo"
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                model: root.categoryOptions
                textRole: "name"
            }

            // 冲突是提示不是错误，用中性的强调色而不是危险色，避免用户以为保存被拒了。
            Label {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                visible: root.conflictText.length > 0 && root.errorText.length === 0
                text: root.conflictText
                textFormat: Text.PlainText
                color: Theme.accentInk
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
            }

            Label {
                objectName: "scheduleDialogError"
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                visible: root.errorText.length > 0
                text: root.errorText
                textFormat: Text.PlainText
                color: Theme.danger
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                Layout.bottomMargin: Theme.space16
                spacing: Theme.space8

                Button {
                    id: deleteButton

                    objectName: "scheduleDeleteButton"
                    text: "删除"
                    visible: root.editing
                    implicitWidth: 76
                    implicitHeight: 44

                    background: Rectangle {
                        color: deleteButton.pressed || deleteButton.hovered
                               ? Theme.dangerSoft : Theme.glassCard
                        border.color: deleteButton.hovered || deleteButton.pressed
                                      ? Theme.danger : Theme.border
                        border.width: 1
                        radius: Theme.radiusMd

                        Behavior on color {
                            ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad }
                        }
                    }

                    contentItem: Text {
                        text: deleteButton.text
                        textFormat: Text.PlainText
                        color: deleteButton.hovered || deleteButton.pressed ? Theme.surface : Theme.danger
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    onClicked: {
                        root.deleteRequested(root.editingEntryId, titleField.text.trim())
                        root.close()
                    }
                }

                Item { Layout.fillWidth: true }

                Button {
                    id: cancelButton

                    objectName: "scheduleCancelButton"
                    text: "取消"
                    implicitWidth: 76
                    implicitHeight: 44

                    background: Rectangle {
                        color: cancelButton.pressed || cancelButton.hovered
                               ? Theme.glassHover : Theme.glassCard
                        border.color: cancelButton.hovered || cancelButton.pressed
                                      ? Theme.accent : Theme.border
                        border.width: 1
                        radius: Theme.radiusMd

                        Behavior on color {
                            ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad }
                        }
                    }

                    contentItem: Text {
                        text: cancelButton.text
                        textFormat: Text.PlainText
                        color: Theme.ink
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    onClicked: root.close()
                }

                Button {
                    id: submitButton

                    objectName: "scheduleSubmitButton"
                    text: root.editing ? "保存" : "添加"
                    implicitWidth: 76
                    implicitHeight: 44

                    background: Rectangle {
                        color: submitButton.pressed || submitButton.hovered
                               ? Theme.accentFillStrong : Theme.accentFill
                        border.color: submitButton.hovered || submitButton.pressed
                                      ? Theme.accentStrong : Theme.accent
                        border.width: 1
                        radius: Theme.radiusMd

                        Behavior on color {
                            ColorAnimation { duration: Theme.reduceMotion ? 0 : 160; easing.type: Easing.OutQuad }
                        }
                    }

                    contentItem: Text {
                        text: submitButton.text
                        textFormat: Text.PlainText
                        color: Theme.accentFillInk
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    onClicked: root.submit()
                }
            }
        }
    }

    // —— 表单里反复出现的三种控件，抽成局部组件避免每个字段重抄一遍样式 ——

    component FieldLabel: Label {
        Layout.fillWidth: true
        Layout.leftMargin: Theme.space16
        Layout.rightMargin: Theme.space16
        Layout.topMargin: Theme.space4
        color: Theme.ink
        font.pixelSize: Theme.fontMd
        font.weight: Font.Medium
    }

    component StyledField: TextField {
        id: styledField

        property bool hasError: false

        Layout.fillWidth: true
        Layout.leftMargin: Theme.space16
        Layout.rightMargin: Theme.space16
        implicitHeight: 40
        selectByMouse: true

        background: Rectangle {
            color: Theme.surfaceRaised
            border.color: styledField.hasError ? Theme.dangerBorder
                          : (styledField.activeFocus ? Theme.accent : Theme.border)
            border.width: styledField.hasError || styledField.activeFocus ? 2 : 1
            radius: Theme.radiusMd

            Behavior on border.color {
                ColorAnimation { duration: Theme.reduceMotion ? 0 : 180; easing.type: Easing.OutQuad }
            }
        }
    }

    component StyledCombo: ComboBox {
        id: styledCombo

        implicitHeight: 40
        leftPadding: Theme.space12
        rightPadding: 32

        background: Rectangle {
            color: styledCombo.down || styledCombo.pressed ? Theme.accentSoft
                   : (styledCombo.hovered ? Theme.surfaceSunken : Theme.surfaceRaised)
            border.color: styledCombo.down || styledCombo.pressed ? Theme.accent : Theme.border
            border.width: styledCombo.down || styledCombo.pressed ? 2 : 1
            radius: Theme.radiusMd

            Behavior on border.color {
                ColorAnimation { duration: Theme.reduceMotion ? 0 : 180; easing.type: Easing.OutQuad }
            }
        }

        indicator: Text {
            x: styledCombo.width - width - 14
            y: Math.round((styledCombo.height - height) / 2)
            text: "▾"
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
            rotation: styledCombo.down ? 180 : 0
            transformOrigin: Item.Center

            Behavior on rotation {
                NumberAnimation { duration: Theme.reduceMotion ? 0 : 180; easing.type: Easing.OutQuad }
            }
        }

        contentItem: Text {
            leftPadding: 0
            rightPadding: styledCombo.indicator.width
            text: styledCombo.displayText
            textFormat: Text.PlainText
            color: Theme.inputInk
            font.pixelSize: Theme.fontMd
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }
}
