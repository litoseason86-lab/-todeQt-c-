pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../LogicalDay.js" as LogicalDay

// 知识缺口的新增 / 编辑弹窗。快速捕获只收一行字，剩下的日期、优先级、
// 正文和结论都在这里补齐。
Dialog {
    id: root

    // 输入框字色必须接管：Basic 风格默认 palette.text 写死深灰，夜间主题下看不见。
    palette.text: Theme.inputInk
    palette.placeholderText: Theme.inputPlaceholderInk
    palette.highlight: Theme.inputSelection
    palette.highlightedText: Theme.inputSelectedInk
    palette.base: Theme.controlSurface
    palette.button: Theme.controlSurface
    palette.buttonText: Theme.controlInk
    palette.windowText: Theme.controlInk

    property var gapServiceRef: null
    property var categoryManagerRef: null
    // 未排期时日期输入留空；空是合法输入，表示「还没想好什么时候处理」。
    property string todayIso: ""

    property int editingId: -1
    property string errorText: ""
    readonly property bool editing: root.editingId > 0

    property int selectedPriority: 1
    property int selectedCategoryId: 0
    property bool resolvedState: false
    // 科目下拉的数据源。首项是「不指定」：知识缺口常常是在还没分清属于哪一科时记下的。
    // 存成属性、由 refreshCategories 显式重查，而不是在 model 绑定里直接调 getAllCategories()：
    // 那样只在创建时查一次，之后科目增删、弹窗重新打开都看不到变化。
    property var categoryChoices: [{ id: 0, name: qsTr("不指定") }]

    signal saved()

    function categoryOptions() {
        if (!root.categoryManagerRef || typeof root.categoryManagerRef.getAllCategories !== "function") {
            return []
        }
        return root.categoryManagerRef.getAllCategories()
    }

    // 重查科目，并核对选中的科目是否还在。被删掉就退回「不指定」：
    // 留着旧编号保存会撞外键，整条保存失败，用户却看不出是科目的问题。
    function refreshCategories() {
        var choices = [{ id: 0, name: qsTr("不指定") }].concat(root.categoryOptions())
        var stillExists = false
        for (var i = 0; i < choices.length; ++i) {
            if (Number(choices[i].id) === root.selectedCategoryId) {
                stillExists = true
                break
            }
        }
        if (!stillExists) {
            root.selectedCategoryId = 0
        }
        root.categoryChoices = choices
        root.syncCategoryBox()
    }

    // 下拉的选中项按科目编号显式同步。换 model 时 ComboBox 会自己重置 currentIndex，
    // 声明式绑定未必在那之后重算；与 GoalFormDialog 一样由这里命令式地对齐。
    function syncCategoryBox() {
        for (var i = 0; i < root.categoryChoices.length; ++i) {
            if (Number(root.categoryChoices[i].id) === root.selectedCategoryId) {
                categoryBox.currentIndex = i
                return
            }
        }
        categoryBox.currentIndex = 0
    }

    // 优先级 0（低）是合法值。不能写成 value || 1：|| 会把 0 当成缺值回填成「中」，
    // 用户只改个标题保存，优先级就被悄悄抬了一档。只有真的缺值才用默认。
    function priorityOrDefault(value) {
        if (value === undefined || value === null || value === "") {
            return 1
        }
        var priority = Number(value)
        return isNaN(priority) ? 1 : priority
    }

    function openForAdd() {
        root.editingId = -1
        root.errorText = ""
        titleField.text = ""
        detailField.text = ""
        dueField.text = ""
        resolutionField.text = ""
        root.selectedPriority = 1
        root.selectedCategoryId = 0
        root.resolvedState = false
        // 弹窗是复用的，上次打开时的科目快照可能早已过期。
        root.refreshCategories()
        root.open()
    }

    function openForEdit(gap) {
        root.editingId = Number(gap.id || -1)
        root.errorText = ""
        titleField.text = String(gap.title || "")
        detailField.text = String(gap.detail || "")
        dueField.text = String(gap.dueDate || "")
        resolutionField.text = String(gap.resolution || "")
        root.selectedPriority = root.priorityOrDefault(gap.priority)
        root.selectedCategoryId = Number(gap.categoryId || 0)
        // 已解决的条目才显示结论输入；未解决时写结论没有意义。
        root.resolvedState = Number(gap.status || 0) === 2
        root.refreshCategories()
        root.open()
    }

    function submit() {
        var title = titleField.text.trim()
        if (title.length === 0) {
            root.errorText = "请先填写要记录的内容"
            return
        }
        // 日期允许留空（= 未排期）；填了就必须是合法日期，不能静默退化成未排期。
        var due = dueField.text.trim()
        if (due.length > 0 && LogicalDay.parseIsoDate(due) === null) {
            root.errorText = "日期需要形如 2026-09-11"
            return
        }
        if (!root.gapServiceRef) {
            root.errorText = "记录服务不可用"
            return
        }

        var ok = false
        if (root.editing) {
            if (typeof root.gapServiceRef.updateGap !== "function") {
                root.errorText = "记录服务不可用"
                return
            }
            ok = Boolean(root.gapServiceRef.updateGap(root.editingId, title, root.selectedCategoryId,
                                                      detailField.text, root.selectedPriority, due))
            // 结论单独走 resolveGap：它同时决定 resolved_at，不能混进普通字段更新。
            if (ok && root.resolvedState && typeof root.gapServiceRef.resolveGap === "function") {
                ok = Boolean(root.gapServiceRef.resolveGap(root.editingId, resolutionField.text))
            }
        } else {
            if (typeof root.gapServiceRef.addGap !== "function") {
                root.errorText = "记录服务不可用"
                return
            }
            ok = Number(root.gapServiceRef.addGap(title, root.selectedCategoryId, detailField.text,
                                                  root.selectedPriority, due, 0)) > 0
        }

        if (!ok) {
            // 具体原因由服务的 operationFailed 播报；这里只保证草稿不丢，用户能改了重试。
            root.errorText = "保存失败，请检查后重试"
            return
        }
        root.errorText = ""
        root.saved()
        root.close()
    }

    Connections {
        target: root.categoryManagerRef
        ignoreUnknownSignals: true

        // 弹窗开着时在别处增删了科目，下拉要跟着变。
        function onCategoriesChanged() {
            root.refreshCategories()
        }
    }

    objectName: "knowledgeGapDialog"
    modal: true
    anchors.centerIn: parent
    // 与其它表单弹窗同一口径：窄窗口下跟着收，但不窄过 320。
    width: Math.min(460, parent ? Math.max(320, parent.width - 64) : 460)
    padding: Theme.space24
    closePolicy: Popup.CloseOnEscape
    title: root.editing ? qsTr("编辑知识缺口") : qsTr("新增知识缺口")

    background: Rectangle {
        objectName: "knowledgeGapDialogBackground"
        color: Theme.surface
        radius: Theme.radiusLg
        border.color: Theme.border
        border.width: 1
    }

    header: Text {
        objectName: "knowledgeGapDialogTitle"
        text: root.title
        textFormat: Text.PlainText
        font.pixelSize: Theme.fontXl
        font.weight: Font.Bold
        color: Theme.inkStrong
        leftPadding: Theme.space24
        topPadding: Theme.space24
        rightPadding: Theme.space24
    }

    contentItem: ColumnLayout {
        spacing: Theme.space12

        Text {
            Layout.fillWidth: true
            text: qsTr("内容")
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontSm
            color: Theme.inkSoft
        }

        TextField {
            id: titleField
            objectName: "knowledgeGapTitleField"
            Layout.fillWidth: true
            implicitHeight: Theme.controlHeightLg
            placeholderText: qsTr("要补什么？")
            maximumLength: root.gapServiceRef && root.gapServiceRef.maxTitleLength
                           ? root.gapServiceRef.maxTitleLength : 100
            selectByMouse: true
            color: Theme.inputInk
            onTextChanged: if (root.errorText.length > 0) root.errorText = ""

            background: Rectangle {
                color: Theme.surfaceRaised
                radius: Theme.radiusMd
                border.color: titleField.activeFocus ? Theme.accent : Theme.border
                border.width: titleField.activeFocus ? 2 : 1
            }
        }

        Text {
            Layout.fillWidth: true
            text: qsTr("上下文")
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontSm
            color: Theme.inkSoft
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.preferredHeight: 72
            clip: true

            TextArea {
                id: detailField
                objectName: "knowledgeGapDetailField"
                placeholderText: qsTr("选填")
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                color: Theme.inputInk
                background: Rectangle {
                    color: Theme.surfaceRaised
                    radius: Theme.radiusMd
                    border.color: detailField.activeFocus ? Theme.accent : Theme.border
                    border.width: detailField.activeFocus ? 2 : 1
                }
            }
        }

        // 日期单独占一行。原先日期、「未排期」和优先级挤在同一行，那一行的最小宽度是 464，
        // 弹窗可用宽度只有 412：Layout 会按最小宽度排版，整列控件一起越过右边界。
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.space4

            Text {
                text: qsTr("计划处理日期")
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSm
                color: Theme.inkSoft
            }

            RowLayout {
                spacing: Theme.space8

                DateInput {
                    id: dueField
                    objectName: "knowledgeGapDueField"
                    onEdited: if (root.errorText.length > 0) root.errorText = ""
                }

                // 留空是常态，所以「清空」必须是一个一眼能看到的动作，
                // 而不是让用户自己去把输入框里的字删干净。
                Button {
                    objectName: "knowledgeGapClearDueButton"
                    text: qsTr("未排期")
                    implicitHeight: Theme.controlHeightMd
                    enabled: dueField.text.length > 0
                    onClicked: dueField.text = ""
                }
            }
        }

        // 科目和优先级同一行：科目下拉填满剩余宽度、可以收窄，优先级分段控件定宽。
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space12

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.space4

                Text {
                    text: qsTr("科目")
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSm
                    color: Theme.inkSoft
                }

                ComboBox {
                    id: categoryBox
                    objectName: "knowledgeGapCategoryBox"
                    Layout.fillWidth: true
                    implicitHeight: Theme.controlHeightMd
                    textRole: "name"
                    valueRole: "id"
                    model: root.categoryChoices
                    onActivated: function (index) {
                        root.selectedCategoryId = Number(root.categoryChoices[index].id || 0)
                    }
                }
            }

            ColumnLayout {
                spacing: Theme.space4

                Text {
                    text: qsTr("优先级")
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSm
                    color: Theme.inkSoft
                }

                SegmentedSwitch {
                    objectName: "knowledgeGapPrioritySwitch"
                    segments: [qsTr("低"), qsTr("中"), qsTr("高")]
                    minSegmentWidth: 52
                    currentIndex: root.selectedPriority
                    reduceMotion: Theme.reduceMotion
                    onActivated: function (index) { root.selectedPriority = index }
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.space4
            // 结论只在已解决时才有位置：没想明白之前这个框只会让人困惑。
            visible: root.resolvedState

            Text {
                text: qsTr("结论")
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSm
                color: Theme.inkSoft
            }

            ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: 64
                clip: true

                TextArea {
                    id: resolutionField
                    objectName: "knowledgeGapResolutionField"
                    wrapMode: TextEdit.Wrap
                    selectByMouse: true
                    color: Theme.inputInk
                    background: Rectangle {
                        color: Theme.surfaceRaised
                        radius: Theme.radiusMd
                        border.color: resolutionField.activeFocus ? Theme.accent : Theme.border
                        border.width: resolutionField.activeFocus ? 2 : 1
                    }
                }
            }
        }

        Text {
            objectName: "knowledgeGapDialogError"
            Layout.fillWidth: true
            visible: root.errorText.length > 0
            text: root.errorText
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontSm
            color: Theme.danger
            wrapMode: Text.WordWrap
        }
    }

    footer: RowLayout {
        spacing: Theme.space8

        Item { Layout.fillWidth: true }

        PageActionButton {
            objectName: "knowledgeGapCancelButton"
            text: qsTr("取消")
            // 底边距两个按钮都要给：只给「保存」时这一行被加高，RowLayout 把「取消」
            // 垂直居中，两个按钮会上下错开 12px。
            Layout.bottomMargin: Theme.space24
            onClicked: root.close()
        }

        PageActionButton {
            objectName: "knowledgeGapSaveButton"
            text: qsTr("保存")
            primary: true
            Layout.rightMargin: Theme.space24
            Layout.bottomMargin: Theme.space24
            onClicked: root.submit()
        }
    }
}
