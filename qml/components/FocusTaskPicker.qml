pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 专注页的任务选择器。
//
// 它存在的理由：在此之前专注页根本无法选任务——`selectedTaskId` 只能由计时器回写，
// 或由今日任务页点「开始」时传进来。于是 ⌘↩ 和全局热键在空闲时会把人送到专注页，
// 弹一句「请先选择要专注的任务」，而这一页恰恰做不到这件事，是一条死路。
//
// 只在空闲时出现。计时进行中任务由计时器说了算，换任务要走既有的确认流程，
// 这里退化成一行静态标题（由调用方切换 `interactive`）。
Item {
    id: root

    // 今日任务，顺序沿用 `getTodayTasks()`：未完成在前、已完成在后。
    property var tasks: []
    property int currentTaskId: -1
    property string currentTitle: ""
    // 没有选中任务时显示的提示文字，由调用方按番茄/自由模式给不同措辞。
    property string placeholderText: ""
    // 计时进行中为假：此时只渲染标题，不给任何可点击的外观。
    property bool interactive: true
    property int maxTitleLength: 100
    property bool reduceMotion: false

    signal taskChosen(int taskId, string title)
    // 用户在选择器里直接敲了一个新任务标题。建任务与启动都由调用方完成——
    // 这个组件不持有 TaskManager。
    signal newTaskRequested(string title)

    implicitWidth: titleButton.implicitWidth
    implicitHeight: titleButton.implicitHeight

    function expand() {
        if (!root.interactive) {
            return
        }
        newTaskField.text = ""
        listPopup.open()
    }

    function chooseCurrent() {
        if (taskList.currentIndex < 0 || taskList.currentIndex >= root.candidates.length)
            return
        var task = root.candidates[taskList.currentIndex]
        listPopup.close()
        root.taskChosen(Number(task.id), String(task.title || ""))
    }

    function collapse() {
        listPopup.close()
    }

    readonly property bool expanded: listPopup.opened

    // 当前绑定的那条必须在候选里，哪怕它已完成或已不属于今天——
    // 否则从选择器里走一圈回来会把归属静默改成别的任务。
    readonly property var candidates: {
        var list = []
        var seen = false
        for (var i = 0; i < (root.tasks || []).length; ++i) {
            var task = root.tasks[i]
            if (Number(task.id) === root.currentTaskId) {
                seen = true
            }
            list.push(task)
        }
        if (!seen && root.currentTaskId > 0 && root.currentTitle.length > 0) {
            list.unshift({ id: root.currentTaskId, title: root.currentTitle, completed: false })
        }
        return list
    }

    Button {
        id: titleButton
        objectName: "focusTaskPickerButton"

        anchors.centerIn: parent
        enabled: root.interactive
        // 计时中不要给出任何「可以点」的暗示：不接受焦点，也不响应悬停。
        focusPolicy: root.interactive ? Qt.StrongFocus : Qt.NoFocus
        hoverEnabled: root.interactive
        padding: root.interactive ? Theme.space8 : 0
        Accessible.name: root.currentTitle.length > 0
                         ? qsTr("当前任务 %1，点击更换").arg(root.currentTitle)
                         : qsTr("选择要专注的任务")

        onClicked: root.expand()

        background: Rectangle {
            // 常态透明、悬停才浮出玻璃底——与专注页右上角两颗钮同一套语言。
            visible: root.interactive && (titleButton.hovered || titleButton.visualFocus || listPopup.opened)
            radius: Theme.radiusMd
            color: Theme.glassHover
            border.color: titleButton.visualFocus ? Theme.focusRing : Theme.glassBorder
            border.width: 1
        }

        contentItem: Text {
            objectName: "focusTaskPickerTitle"
            text: root.currentTitle.length > 0 ? root.currentTitle : root.placeholderText
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontXl
            font.bold: true
            // 未选中时用次要色：这一行此刻是提示语不是任务名。
            color: root.currentTitle.length > 0 ? Theme.ink : Theme.inkSoft
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
    }

    Popup {
        id: listPopup
        objectName: "focusTaskPickerPopup"

        // 输入框字色必须接管：Basic 风格默认 palette.text 写死深灰，夜间主题下看不见。
        palette.text: Theme.inputInk
        palette.placeholderText: Theme.inputPlaceholderInk
        palette.highlight: Theme.inputSelection
        palette.highlightedText: Theme.inputSelectedInk

        parent: root
        x: Math.round((root.width - width) / 2)
        y: titleButton.height + Theme.space8
        width: 320
        padding: Theme.space12
        modal: false
        dim: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        onOpened: {
            // 一条都没有时焦点直接落到输入框：此时列表是空的，
            // 聚焦一个什么都选不了的列表等于把死路换个地方。
            if (root.candidates.length === 0) {
                newTaskField.forceActiveFocus()
            } else {
                taskList.currentIndex = 0
                for (var i = 0; i < root.candidates.length; ++i) {
                    if (Number(root.candidates[i].id) === root.currentTaskId)
                        taskList.currentIndex = i
                }
                taskList.forceActiveFocus()
            }
        }

        background: GlassPanel {
            objectName: "focusTaskPickerPopupBackground"
            radius: Theme.radiusLg
            color: Theme.glassBlurAllowed ? Theme.glassDialog : Theme.glassSolidCard
            solidFallback: !Theme.glassBlurAllowed
            panelShadowEnabled: true
        }

        contentItem: ColumnLayout {
            spacing: Theme.space8

            Text {
                Layout.fillWidth: true
                text: qsTr("今天的任务")
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSm
                color: Theme.inkSoft
            }

            ListView {
                id: taskList
                objectName: "focusTaskPickerList"

                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(220, Math.max(contentHeight, 1))
                visible: root.candidates.length > 0
                clip: true
                model: root.candidates
                activeFocusOnTab: true
                keyNavigationEnabled: true
                KeyNavigation.tab: newTaskField
                Keys.onReturnPressed: root.chooseCurrent()
                Keys.onEnterPressed: root.chooseCurrent()
                Keys.onSpacePressed: root.chooseCurrent()
                spacing: 2
                boundsBehavior: Flickable.StopAtBounds

                delegate: ItemDelegate {
                    id: taskRow

                    required property var modelData
                    required property int index

                    readonly property int taskId: Number(taskRow.modelData.id)
                    readonly property bool taskCompleted: Boolean(taskRow.modelData.completed)

                    objectName: "focusTaskPickerRow-" + taskRow.taskId
                    width: ListView.view.width
                    implicitHeight: Theme.controlHeightMd
                    Accessible.name: taskRow.taskCompleted
                                     ? qsTr("%1，已完成").arg(String(taskRow.modelData.title || ""))
                                     : String(taskRow.modelData.title || "")

                    onClicked: {
                        listPopup.close()
                        root.taskChosen(taskRow.taskId, String(taskRow.modelData.title || ""))
                    }

                    background: Rectangle {
                        radius: Theme.radiusSm
                        border.width: taskList.activeFocus && taskList.currentIndex === taskRow.index ? 2 : 0
                        border.color: Theme.focusRing
                        color: taskRow.taskId === root.currentTaskId ? Theme.accentFill
                               : (taskRow.hovered ? Theme.glassHover : "transparent")
                    }

                    contentItem: RowLayout {
                        spacing: Theme.space8

                        Text {
                            Layout.fillWidth: true
                            text: String(taskRow.modelData.title || "")
                            textFormat: Text.PlainText
                            font.pixelSize: Theme.fontMd
                            // 已完成的压暗但仍可选：「今天排的都做完了，还想再练一轮」是真实场景。
                            color: taskRow.taskCompleted ? Theme.inkSoft : Theme.ink
                            elide: Text.ElideRight
                        }

                        Text {
                            visible: taskRow.taskCompleted
                            text: qsTr("已完成")
                            textFormat: Text.PlainText
                            font.pixelSize: Theme.fontXs
                            color: Theme.inkSoft
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: root.candidates.length === 0
                text: qsTr("今天还没有任务，敲一个就开始")
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontMd
                color: Theme.inkSoft
                wrapMode: Text.WordWrap
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.border
            }

            TextField {
                id: newTaskField
                objectName: "focusTaskPickerNewField"

                Layout.fillWidth: true
                implicitHeight: Theme.controlHeightMd
                placeholderText: qsTr("新建今日任务并开始")
                maximumLength: root.maxTitleLength
                color: Theme.inputInk
                font.pixelSize: Theme.fontMd

                background: Rectangle {
                    objectName: "focusTaskPickerNewFieldBackground"
                    radius: Theme.radiusMd
                    color: Theme.surfaceRaised
                    border.color: newTaskField.activeFocus ? Theme.focusRing : Theme.border
                    border.width: newTaskField.activeFocus ? 2 : 1
                }

                onAccepted: {
                    var title = newTaskField.text.trim()
                    if (title.length === 0) {
                        return
                    }
                    newTaskField.text = ""
                    listPopup.close()
                    root.newTaskRequested(title)
                }
            }
        }
    }
}
