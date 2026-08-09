pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../LogicalDay.js" as LogicalDay

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

    property var goalServiceRef: null
    property var categoryManagerRef: null
    property var settingsRef: null
    property date currentDateOverride
    property int editingGoalId: -1
    property string errorText: ""
    property var categories: []
    // 编辑期间科目可能被另一个窗口删除。单独保存 id，不能只从 ComboBox 的旧索引推断，
    // 否则模型刷新后会把用户未确认的“第一项”误写回目标。
    property int selectedCategoryId: -1
    property bool refreshingCategorySelection: false
    readonly property bool longTerm: longTermCheck.checked
    readonly property bool editing: root.editingGoalId > 0
    readonly property int maxTitleLength: root.goalServiceRef
                                                  ? Number(root.goalServiceRef.maxTitleLength || 100)
                                                  : 100
    readonly property int maxTargetPomodoros: root.goalServiceRef
                                                      ? Number(root.goalServiceRef.maxTargetPomodoros || 9999)
                                                      : 9999

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    width: Math.min(500, parent ? Math.max(320, parent.width - Theme.space32) : 500)
    height: Math.min(formColumn.implicitHeight, parent ? parent.height - Theme.space32 : 620)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    function todayIso() {
        const configuredHour = root.settingsRef ? root.settingsRef.dayStartHour : undefined
        const dayStartHour = configuredHour === undefined || configuredHour === null
                ? 4 : Number(configuredHour)
        const overrideDate = new Date(root.currentDateOverride)
        const now = isNaN(overrideDate.getTime()) ? new Date() : overrideDate
        return Qt.formatDate(LogicalDay.todayDate(dayStartHour, now), "yyyy-MM-dd")
    }

    function dateToIso(value) {
        if (value instanceof Date && !isNaN(value.getTime()))
            return Qt.formatDate(value, "yyyy-MM-dd")
        var text = String(value || "")
        return /^\d{4}-\d{2}-\d{2}$/.test(text) ? text : ""
    }

    function parseIsoDate(text) {
        var match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(text || ""))
        if (!match)
            return null
        // 用本地正午规避 DST 或 UTC 换日导致日期前后漂移；服务端只取 QDate，不关心时刻。
        var value = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]), 12, 0, 0)
        if (value.getFullYear() !== Number(match[1])
                || value.getMonth() !== Number(match[2]) - 1
                || value.getDate() !== Number(match[3]))
            return null
        return value
    }

    function refreshCategories(desiredCategoryId, selectFirstWhenMissing) {
        root.refreshingCategorySelection = true
        root.categories = root.categoryManagerRef && root.categoryManagerRef.getAllCategories
                ? root.categoryManagerRef.getAllCategories() : []
        categoryCombo.currentIndex = -1
        for (var i = 0; i < root.categories.length; ++i) {
            if (Number(root.categories[i].id) === Number(desiredCategoryId)) {
                categoryCombo.currentIndex = i
                break
            }
        }
        if (categoryCombo.currentIndex < 0 && selectFirstWhenMissing && root.categories.length > 0)
            categoryCombo.currentIndex = 0
        root.selectedCategoryId = categoryCombo.currentIndex >= 0
                ? Number(root.categories[categoryCombo.currentIndex].id) : -1
        root.refreshingCategorySelection = false
    }

    function openForAdd() {
        root.editingGoalId = -1
        root.errorText = ""
        titleField.text = ""
        targetField.text = "100"
        startDateField.text = root.todayIso()
        deadlineField.text = ""
        longTermCheck.checked = true
        // 新建目标没有历史选择，默认首项只是便利，不会改写既有数据。
        root.refreshCategories(-1, true)
        root.open()
    }

    function openForEdit(goal) {
        root.editingGoalId = Number(goal.id || -1)
        root.errorText = ""
        titleField.text = String(goal.title || "")
        targetField.text = String(goal.targetPomodoros || 1)
        startDateField.text = root.dateToIso(goal.startDate) || root.todayIso()
        deadlineField.text = root.dateToIso(goal.deadline)
        longTermCheck.checked = deadlineField.text.length === 0
        // 编辑既有目标时，缺失的原科目必须保持未选择状态，要求用户明确确认新归属。
        root.refreshCategories(goal.categoryId, false)
        root.open()
    }

    function submit() {
        root.errorText = ""
        var title = titleField.text.trim()
        if (title.length === 0) {
            root.errorText = qsTr("目标名称不能为空")
            titleField.forceActiveFocus()
            return false
        }
        if (categoryCombo.currentIndex < 0 || categoryCombo.currentIndex >= root.categories.length) {
            root.errorText = qsTr("请先为目标选择科目")
            categoryCombo.forceActiveFocus()
            return false
        }
        var target = Number(targetField.text)
        if (!Number.isInteger(target) || target < 1 || target > root.maxTargetPomodoros) {
            root.errorText = qsTr("目标番茄数必须在 1 到 %1 之间").arg(root.maxTargetPomodoros)
            targetField.forceActiveFocus()
            return false
        }
        var startDate = root.parseIsoDate(startDateField.text)
        if (!startDate) {
            root.errorText = qsTr("起始日期格式应为 YYYY-MM-DD")
            startDateField.forceActiveFocus()
            return false
        }
        var deadline = undefined
        if (!root.longTerm) {
            deadline = root.parseIsoDate(deadlineField.text)
            if (!deadline) {
                root.errorText = qsTr("截止日期格式应为 YYYY-MM-DD")
                deadlineField.forceActiveFocus()
                return false
            }
            if (deadline < startDate) {
                root.errorText = qsTr("截止日期不能早于起始日期")
                deadlineField.forceActiveFocus()
                return false
            }
        }

        var categoryId = Number(root.categories[categoryCombo.currentIndex].id)
        if (!root.goalServiceRef) {
            root.errorText = qsTr("目标服务不可用")
            return false
        }
        var succeeded = root.editing
                ? root.goalServiceRef.updateGoal(root.editingGoalId, title, categoryId,
                                                 target, startDate, deadline)
                : root.goalServiceRef.addGoal(title, categoryId, target, startDate, deadline)
        if (!succeeded) {
            if (root.errorText.length === 0)
                root.errorText = qsTr("保存失败，请检查输入或数据库后重试")
            return false
        }
        root.close()
        return true
    }

    Connections {
        target: root.categoryManagerRef
        ignoreUnknownSignals: true

        function onCategoriesChanged() {
            root.refreshCategories(root.selectedCategoryId, !root.editing)
        }
        function onOperationFailed(message) {
            root.errorText = String(message || qsTr("科目加载失败"))
        }
    }

    Connections {
        target: root.goalServiceRef
        ignoreUnknownSignals: true

        function onOperationFailed(message) {
            root.errorText = String(message || qsTr("保存失败"))
        }
    }

    onOpened: titleField.forceActiveFocus()

    Overlay.modal: Rectangle { color: Theme.dialogScrim }

    background: Rectangle {
        color: Theme.glassBlurAllowed ? Theme.glassDialog : Theme.glassSolidCard
        border.color: Theme.glassBorder
        border.width: 1
        radius: Theme.radiusLg
    }

    contentItem: Flickable {
        id: formFlickable

        contentWidth: width
        contentHeight: formColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: formColumn

            width: formFlickable.width
            spacing: Theme.space12

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                Layout.topMargin: Theme.space16

                Text {
                    Layout.fillWidth: true
                    text: root.editing ? qsTr("编辑目标") : qsTr("新建目标")
                    color: Theme.inkStrong
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.Bold
                }

                FormButton {
                    text: qsTr("取消")
                    implicitHeight: 44
                    onClicked: root.close()
                }
            }

            Label {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                text: qsTr("目标名称")
                color: Theme.ink
            }

            TextField {
                id: titleField
                objectName: "goalTitleField"

                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                implicitHeight: 44
                maximumLength: root.maxTitleLength
                placeholderText: qsTr("例如：完成 100 个算法番茄")
                selectByMouse: true
            }

            Label {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                text: qsTr("科目")
                color: Theme.ink
            }

            ComboBox {
                id: categoryCombo
                objectName: "goalCategoryCombo"

                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                implicitHeight: 44
                model: root.categories
                textRole: "name"
                displayText: currentIndex >= 0 && currentIndex < root.categories.length
                             ? String(root.categories[currentIndex].name || "")
                             : qsTr("选择科目")
                Accessible.description: root.editing && currentIndex < 0
                                        ? qsTr("原科目已删除，请重新选择") : ""
                onCurrentIndexChanged: {
                    if (!root.refreshingCategorySelection && currentIndex >= 0
                            && currentIndex < root.categories.length) {
                        root.selectedCategoryId = Number(root.categories[currentIndex].id)
                    }
                }
            }

            Text {
                id: missingCategoryHint
                objectName: "goalCategoryMissingHint"

                visible: root.editing && categoryCombo.currentIndex < 0
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                text: qsTr("原科目已删除，请重新选择")
                color: Theme.danger
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                spacing: Theme.space12

                ColumnLayout {
                    Layout.fillWidth: true
                    Label { text: qsTr("目标番茄数"); color: Theme.ink }
                    TextField {
                        id: targetField
                        objectName: "goalTargetField"
                        Layout.fillWidth: true
                        implicitHeight: 44
                        inputMethodHints: Qt.ImhDigitsOnly
                        validator: IntValidator { bottom: 1; top: root.maxTargetPomodoros }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Label { text: qsTr("起始日期"); color: Theme.ink }
                    TextField {
                        id: startDateField
                        objectName: "goalStartDateField"
                        Layout.fillWidth: true
                        implicitHeight: 44
                        placeholderText: "YYYY-MM-DD"
                        inputMethodHints: Qt.ImhDate
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                text: qsTr("填过去的日期可把已有专注记录计入进度")
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
            }

            CheckBox {
                id: longTermCheck
                objectName: "goalLongTermCheck"
                Layout.leftMargin: Theme.space16
                text: qsTr("长期目标（不设截止日期）")
                // 复选框是用户直接操作的状态源；longTerm 只从 checked 派生，
                // 避免控件状态与截止日期启用状态之间形成双向写入环。
            }

            TextField {
                id: deadlineField
                objectName: "goalDeadlineField"

                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                implicitHeight: 44
                enabled: !root.longTerm
                placeholderText: qsTr("截止日期 YYYY-MM-DD")
                inputMethodHints: Qt.ImhDate
            }

            Text {
                id: errorLabel
                objectName: "goalFormError"

                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                text: root.errorText
                color: Theme.danger
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
            }

            FormButton {
                objectName: "goalSaveButton"
                Layout.alignment: Qt.AlignRight
                Layout.rightMargin: Theme.space16
                Layout.bottomMargin: Theme.space16
                implicitWidth: 96
                implicitHeight: 44
                accentAction: true
                text: root.editing ? qsTr("保存修改") : qsTr("创建目标")
                onClicked: root.submit()
            }
        }
    }

    component FormButton: Button {
        id: formButton

        property bool accentAction: false

        hoverEnabled: true
        background: Rectangle {
            color: formButton.accentAction
                   ? (formButton.down || formButton.hovered
                      ? Theme.accentFillStrong : Theme.accentFill)
                   : (formButton.down || formButton.hovered
                      ? Theme.glassHover : Theme.glassCard)
            border.color: formButton.accentAction ? Theme.accent : Theme.border
            border.width: 1
            radius: Theme.radiusMd
        }
        contentItem: Text {
            text: formButton.text
            color: formButton.accentAction ? Theme.accentFillInk : Theme.ink
            font.pixelSize: Theme.fontMd
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }
}
