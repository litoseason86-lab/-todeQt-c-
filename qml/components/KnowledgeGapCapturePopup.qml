pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 知识缺口的快速捕获框。
//
// 刻意做成非模态 Popup 而不是 Dialog：这个框的使用场景就是「正在专注，忽然发现
// 有一块不懂，但现在不能停下来」。一旦它变成模态弹窗、或者顺手把计时暂停，
// 记一笔的代价就超过了「算了回头再说」，这个功能也就等于没有。
// 所以它只做一件事：收一行字，回车存下，然后消失。日期、优先级、正文
// 全部留到清单页去补。
Popup {
    id: root

    // 输入框字色必须接管：Basic 风格默认 palette.text 写死深灰，夜间主题下看不见。
    palette.text: Theme.inputInk
    palette.placeholderText: Theme.inputPlaceholderInk
    palette.highlight: Theme.inputSelection
    palette.highlightedText: Theme.inputSelectedInk

    property var gapServiceRef: null
    // 来源任务：捕获时自动带上，之后在清单页能看出这条是在做什么的时候记的。
    property int sourceTaskId: 0
    property string sourceTaskTitle: ""
    property int categoryId: 0

    signal captured(string title)
    signal captureFailed(string message)

    function openWithSource(taskId, taskTitle, catId) {
        root.sourceTaskId = Number(taskId || 0)
        root.sourceTaskTitle = taskTitle === undefined || taskTitle === null ? "" : String(taskTitle)
        root.categoryId = Number(catId || 0)
        root.errorText = ""
        inputField.text = ""
        root.open()
    }

    property string errorText: ""

    function submit() {
        var text = inputField.text.trim()
        if (text.length === 0) {
            root.errorText = "先写一句，哪怕只是几个关键词"
            return
        }
        // 服务替身可能没有这个方法；先查可调用性再调用，避免运行时 TypeError。
        if (!root.gapServiceRef || typeof root.gapServiceRef.captureGap !== "function") {
            root.errorText = "记录服务不可用"
            return
        }
        var newId = Number(root.gapServiceRef.captureGap(text, root.categoryId, root.sourceTaskId))
        if (!(newId > 0)) {
            // 具体原因由服务的 operationFailed 播报，这里只保证输入不被清掉，用户能重试。
            root.errorText = "没能存下来，请再试一次"
            root.captureFailed(text)
            return
        }
        root.errorText = ""
        inputField.text = ""
        root.captured(text)
        root.close()
    }

    objectName: "knowledgeGapCapturePopup"
    // 非模态：底下的计时器照常跑，用户想放弃直接点别处或按 Esc。
    modal: false
    dim: false
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    padding: Theme.space16
    width: 360

    onOpened: inputField.forceActiveFocus()

    background: GlassPanel {
        objectName: "knowledgeGapCapturePopupBackground"
        radius: Theme.radiusLg
        color: Theme.glassBlurAllowed ? Theme.glassDialog : Theme.glassSolidCard
        solidFallback: !Theme.glassBlurAllowed
        panelShadowEnabled: true
    }

    contentItem: ColumnLayout {
        spacing: Theme.space8

        Text {
            objectName: "knowledgeGapCaptureTitle"
            Layout.fillWidth: true
            text: qsTr("记一笔")
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontLg
            font.weight: Font.Bold
            color: Theme.inkStrong
        }

        Text {
            objectName: "knowledgeGapCaptureSource"
            Layout.fillWidth: true
            visible: root.sourceTaskTitle.length > 0
            text: qsTr("来自：%1").arg(root.sourceTaskTitle)
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontSm
            color: Theme.inkSoft
            elide: Text.ElideRight
        }

        TextField {
            id: inputField
            objectName: "knowledgeGapCaptureField"

            Layout.fillWidth: true
            implicitHeight: Theme.controlHeightLg
            placeholderText: qsTr("要补什么？")
            // 与 KnowledgeGapService::kMaxTitleLength 保持一致；超长粘贴在输入端截断。
            maximumLength: root.gapServiceRef && root.gapServiceRef.maxTitleLength
                           ? root.gapServiceRef.maxTitleLength : 100
            selectByMouse: true
            color: Theme.inputInk

            background: Rectangle {
                objectName: "knowledgeGapCaptureFieldBackground"
                color: Theme.surfaceRaised
                radius: Theme.radiusMd
                border.color: root.errorText.length > 0
                              ? Theme.dangerBorder
                              : (inputField.activeFocus ? Theme.focusRing : Theme.border)
                border.width: root.errorText.length > 0 || inputField.activeFocus ? 2 : 1
            }

            onTextChanged: if (root.errorText.length > 0) root.errorText = ""
            // 回车即存是这个框存在的全部意义，不要求用户去够鼠标。
            Keys.onReturnPressed: root.submit()
            Keys.onEnterPressed: root.submit()
        }

        Text {
            objectName: "knowledgeGapCaptureError"
            Layout.fillWidth: true
            visible: root.errorText.length > 0
            text: root.errorText
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontSm
            color: Theme.danger
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space8

            Item { Layout.fillWidth: true }

            // 原来这里还有一行「回车保存，之后在「知识缺口」里补日期」。
            // 回车保存是输入框的通用行为，不需要教；后面能补什么，用户翻到那一页自然看得见。
            // 这个框的全部价值是「快」，多一行字读就多一分打断。
            PageActionButton {
                objectName: "knowledgeGapCaptureSaveButton"
                text: qsTr("记下")
                primary: true
                onClicked: root.submit()
            }
        }
    }
}
