pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import ".."

// 完成任务弹窗：点任务卡上的「完成」打开，让用户记下这次具体完成了哪些内容。
// 确认后由宿主在同一次写入里把任务标为完成并保存这段记录；左侧复选框是「快速完成」，不经过这里。
Popup {
    id: root

    // 退出动画期间 Popup 仍可见，已结束的表单不能再次写库；重新打开才允许新提交。
    property bool submissionClosed: false
    onAboutToShow: root.submissionClosed = false
    onAboutToHide: root.finishEditing()
    // 交互协调器：打开时登记「正在处理这条任务」，期间今日列表暂停刷新、外部 AI 写入会得知用户正忙；
    // 同时由它读回任务的最新数据，避免用列表里过期的快照预填。关闭时必须释放登记。
    property var interactionCoordinatorRef: null
    property string interactionSource: "complete_task_dialog"
    signal openFailed(string message)
    function finishEditing() {
        root.submissionClosed = true
        if (root.interactionCoordinatorRef) root.interactionCoordinatorRef.end(root)
    }
    Component.onDestruction: root.finishEditing()

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

    // 完成记录长度上限，与 TaskManager::kMaxNotesLength 同一口径；宿主从 taskManager.maxNotesLength 注入。
    // TextArea 没有 maximumLength，只能在提交时拦下——服务端超长同样拒绝，不会截断。
    property int maxNoteLength: 2000
    // 宿主注入返回 bool 的写入函数 function(taskId, note)：只有写库成功才关弹窗。
    // 没注入时改发 completionSubmitted 信号，供独立组件和测试使用。
    property var noteSubmitter: null
    signal completionSubmitted(int taskId, string note)

    property int taskId: -1
    property string taskTitle: ""
    property string errorText: ""

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(460, parent ? Math.max(300, parent.width - 64) : 460)
    height: panel.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    function openForTask(task) {
        root.errorText = ""
        if (root.interactionCoordinatorRef) {
            task = root.interactionCoordinatorRef.beginEdit(root, Number(task.id), root.interactionSource)
            if (!task || !task.id) {
                root.errorText = root.interactionCoordinatorRef.lastError
                root.openFailed(root.errorText)
                return false
            }
        }
        root.taskId = Number(task.id)
        root.taskTitle = String(task.title || "")
        // 取消过完成的任务还留着上次写的记录，预填回来接着改，不用重写一遍。
        noteField.text = String(task.completionNote || "")
        root.open()
        noteField.forceActiveFocus()
        noteField.cursorPosition = noteField.length
        return true
    }

    function submit() {
        if (root.submissionClosed)
            return false
        var note = noteField.text.trim()
        // 超长当场拦下并说清楚超了多少。服务端同样会拒绝，但那边只能换来一句笼统的「保存失败」。
        if (note.length > root.maxNoteLength) {
            root.errorText = "完成记录太长了，请控制在 " + root.maxNoteLength + " 字以内（当前 "
                    + note.length + " 字）"
            noteField.forceActiveFocus()
            return false
        }
        var succeeded = true
        if (root.noteSubmitter) {
            // noteSubmitter 由宿主在运行时注入为函数，静态工具只能看到 var 属性。
            // qmllint disable use-proper-function
            succeeded = Boolean(root.noteSubmitter(root.taskId, note))
            // qmllint enable use-proper-function
        } else {
            root.completionSubmitted(root.taskId, note)
        }
        if (!succeeded) {
            // 失败时弹窗留着、草稿不动，用户可以直接重试。
            root.errorText = "保存失败，请检查数据库后重试"
            noteField.forceActiveFocus()
            return false
        }
        root.finishEditing()
        root.close()
        return true
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 0.94
                to: 1.0
                duration: Theme.reduceMotion ? 0 : 220
                easing.type: Easing.OutCubic
            }

            OpacityAnimator {
                from: 0
                to: 1
                duration: Theme.reduceMotion ? 0 : 220
                easing.type: Easing.OutQuad
            }
        }
    }

    exit: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 1.0
                to: 0.94
                duration: Theme.reduceMotion ? 0 : 220
                easing.type: Easing.InQuad
            }

            OpacityAnimator {
                from: 1
                to: 0
                duration: Theme.reduceMotion ? 0 : 220
                easing.type: Easing.InQuad
            }
        }
    }

    Overlay.modal: Rectangle {
        color: Theme.dialogScrim
        opacity: root.opened ? 1 : 0

        Behavior on opacity {
            OpacityAnimator {
                duration: Theme.reduceMotion ? 0 : 180
                easing.type: Easing.InOutQuad
            }
        }
    }

    background: Rectangle {
        id: panel
        objectName: "completeDialogPanel"

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

    contentItem: ColumnLayout {
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
                text: "完成任务"
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
            }
        }

        // 任务标题单独成行：最长 100 字，塞进标题栏会溢出。两行以后省略，全文在卡片上看得到。
        Text {
            objectName: "completeTaskTitle"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            text: root.taskTitle
            textFormat: Text.PlainText
            color: Theme.inkStrong
            font.pixelSize: Theme.fontMd
            font.weight: Font.Medium
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            text: "这次完成了哪些内容？（可不填）"
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontMd
        }

        // 接近上限才出现的字数提示：平时不占视线，快写满时提前知道还剩多少。
        Label {
            objectName: "completeNoteCounter"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            visible: noteField.text.length > root.maxNoteLength * 0.9
            text: noteField.text.length + " / " + root.maxNoteLength
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignRight
            color: noteField.text.length > root.maxNoteLength ? Theme.danger : Theme.inkSoft
            font.pixelSize: Theme.fontSm
        }

        // 记录是这个弹窗的主体，给比编辑弹窗备注框更高的初始高度；写长了在框内滚动。
        ScrollView {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.preferredHeight: 96

            TextArea {
                id: noteField
                objectName: "completeNoteField"

                placeholderText: "做完的页码、题号，还没做完的部分……"
                placeholderTextColor: Theme.inkMuted
                color: Theme.inkStrong
                font.pixelSize: Theme.fontMd
                wrapMode: TextArea.Wrap
                selectByMouse: true
                Accessible.name: "完成记录"
                Accessible.description: "可不填。按 Command 加回车完成"

                // 回车留给换行；⌘↩（Qt 在 macOS 上把 Command 报成 ControlModifier）直接完成，
                // 手不用离开键盘。两个修饰键都认，外接键盘改键后也能用。
                Keys.onPressed: function (event) {
                    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            && (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier))) {
                        event.accepted = true
                        root.submit()
                    }
                }
                // TextArea 默认把 Tab 当成输入字符；抢在它之前把 Tab 用于移动焦点，
                // 否则键盘用户进了输入框就再也够不着下面的按钮。
                KeyNavigation.priority: KeyNavigation.BeforeItem
                KeyNavigation.tab: cancelButton

                onTextChanged: {
                    if (root.errorText.length > 0 && noteField.text.trim().length <= root.maxNoteLength) {
                        root.errorText = ""
                    }
                }

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: Theme.surfaceSunken
                    border.width: noteField.activeFocus ? 2 : 1
                    border.color: noteField.activeFocus ? Theme.focusRing : Theme.borderSubtle
                }
            }
        }

        Text {
            objectName: "completeErrorText"
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
            Layout.alignment: Qt.AlignRight
            Layout.rightMargin: Theme.space16
            Layout.bottomMargin: Theme.space16
            spacing: Theme.space12

            Button {
                id: cancelButton

                objectName: "completeCancelButton"
                text: "取消"
                implicitWidth: 80
                implicitHeight: Theme.controlHeightMd
                KeyNavigation.tab: confirmButton

                onClicked: root.close()

                background: Rectangle {
                    color: cancelButton.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
                    border.color: cancelButton.activeFocus ? Theme.focusRing : Theme.border
                    border.width: cancelButton.activeFocus ? 2 : 1
                    radius: Theme.radiusMd
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
                id: confirmButton

                objectName: "completeConfirmButton"
                text: "完成"
                implicitWidth: 80
                implicitHeight: Theme.controlHeightMd
                KeyNavigation.tab: noteField

                onClicked: root.submit()

                background: Rectangle {
                    color: confirmButton.hovered ? Theme.accentFillStrong : Theme.accentFill
                    border.color: Theme.focusRing
                    border.width: confirmButton.activeFocus ? 2 : 0
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: confirmButton.text
                    textFormat: Text.PlainText
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
