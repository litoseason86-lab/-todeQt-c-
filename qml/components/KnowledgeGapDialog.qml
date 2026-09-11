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

    signal saved()

    function categoryOptions() {
        if (!root.categoryManagerRef || typeof root.categoryManagerRef.getAllCategories !== "function") {
            return []
        }
        return root.categoryManagerRef.getAllCategories()
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
        root.open()
    }

    function openForEdit(gap) {
        root.editingId = Number(gap.id || -1)
        root.errorText = ""
        titleField.text = String(gap.title || "")
        detailField.text = String(gap.detail || "")
        dueField.text = String(gap.dueDate || "")
        resolutionField.text = String(gap.resolution || "")
        root.selectedPriority = Number(gap.priority || 1)
        root.selectedCategoryId = Number(gap.categoryId || 0)
        // 已解决的条目才显示结论输入；未解决时写结论没有意义。
        root.resolvedState = Number(gap.status || 0) === 2
        root.open()
    }

    property int selectedPriority: 1
    property int selectedCategoryId: 0
    property bool resolvedState: false

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

    objectName: "knowledgeGapDialog"
    modal: true
    anchors.centerIn: parent
    width: 460
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

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space12

            ColumnLayout {
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

            Item { Layout.fillWidth: true }

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
                // 首项是「不指定」：知识缺口常常是在还没分清属于哪一科时记下的。
                model: [{ id: 0, name: qsTr("不指定") }].concat(root.categoryOptions())
                currentIndex: {
                    for (var i = 0; i < categoryBox.count; ++i) {
                        if (Number(categoryBox.model[i].id) === root.selectedCategoryId)
                            return i
                    }
                    return 0
                }
                onActivated: function (index) {
                    root.selectedCategoryId = Number(categoryBox.model[index].id || 0)
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
