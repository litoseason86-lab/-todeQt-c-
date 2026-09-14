pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 科目下拉里的「+ 新建科目…」。
//
// 只收一个名字，颜色按现有调色板顺位自动取——建任务建到一半想起要分个新科目，
// 此刻要的是别打断，不是再做一次配色决策。改颜色仍走「设置 → 数据 → 科目管理」。
//
// 只负责收名字并调服务；选中哪一条由调用方在 `created` 里决定，
// 这个组件不碰任何下拉的 currentIndex。
Popup {
    id: root

    // 输入框字色必须接管：Basic 风格默认 palette.text 写死深灰，夜间主题下看不见。
    palette.text: Theme.inputInk
    palette.placeholderText: Theme.inputPlaceholderInk
    palette.highlight: Theme.inputSelection
    palette.highlightedText: Theme.inputSelectedInk

    property var categoryManagerRef: null
    // 与 ColorPicker 同一份暖色阶，保证内联建出来的科目和手动建的看起来是一家。
    readonly property var paletteColors: [
        "#d4a574", "#c9956e", "#be8568", "#b37562", "#a8655c",
        "#9d7556", "#8b6550", "#7a5544", "#694538", "#58352c"
    ]

    property string errorText: ""

    // 新科目建成后发出，携带服务返回的编号与名字。
    signal created(int categoryId, string name)

    function openPrompt() {
        root.errorText = ""
        nameField.text = ""
        root.open()
    }

    // 按已有科目数量顺位取色，排满一轮就回头——与新建科目对话框的默认取色同一思路。
    function nextColor() {
        var existing = root.categoryManagerRef && root.categoryManagerRef.getAllCategories
                ? root.categoryManagerRef.getAllCategories() : []
        return root.paletteColors[existing.length % root.paletteColors.length]
    }

    function submit() {
        var name = nameField.text.trim()
        if (name.length === 0) {
            root.errorText = qsTr("科目名不能为空")
            return
        }
        // 替身或旧上下文可能没有这个方法；先查可调用性，避免运行时 TypeError
        // 把下面为「服务不可用」写的兜底整段跳过。
        if (!root.categoryManagerRef || typeof root.categoryManagerRef.addCategory !== "function") {
            root.errorText = qsTr("科目服务不可用")
            return
        }

        var newId = Number(root.categoryManagerRef.addCategory(name, root.nextColor()))
        if (!(newId > 0)) {
            // 服务拒绝的最常见原因是重名。保留输入让用户直接改，不要清空重打。
            root.errorText = qsTr("没能新建，可能是重名了")
            return
        }

        root.errorText = ""
        nameField.text = ""
        root.close()
        root.created(newId, name)
    }

    objectName: "newCategoryPrompt"
    modal: true
    dim: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    padding: Theme.space16
    width: 300

    onOpened: nameField.forceActiveFocus()

    background: GlassPanel {
        objectName: "newCategoryPromptBackground"
        radius: Theme.radiusLg
        color: Theme.glassBlurAllowed ? Theme.glassDialog : Theme.glassSolidCard
        solidFallback: !Theme.glassBlurAllowed
        panelShadowEnabled: true
    }

    contentItem: ColumnLayout {
        spacing: Theme.space8

        Text {
            Layout.fillWidth: true
            text: qsTr("新建科目")
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontLg
            font.weight: Font.Bold
            color: Theme.inkStrong
        }

        TextField {
            id: nameField
            objectName: "newCategoryPromptField"

            Layout.fillWidth: true
            implicitHeight: Theme.controlHeightLg
            placeholderText: qsTr("科目名")
            maximumLength: 30
            selectByMouse: true
            color: Theme.inputInk
            font.pixelSize: Theme.fontMd

            background: Rectangle {
                objectName: "newCategoryPromptFieldBackground"
                color: Theme.surfaceRaised
                radius: Theme.radiusMd
                border.color: root.errorText.length > 0
                              ? Theme.dangerBorder
                              : (nameField.activeFocus ? Theme.accent : Theme.border)
                border.width: root.errorText.length > 0 || nameField.activeFocus ? 2 : 1
            }

            onTextChanged: if (root.errorText.length > 0) root.errorText = ""
            Keys.onReturnPressed: root.submit()
            Keys.onEnterPressed: root.submit()
        }

        Text {
            objectName: "newCategoryPromptError"
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

            Button {
                id: cancelButton
                objectName: "newCategoryPromptCancel"
                text: qsTr("取消")
                implicitHeight: Theme.controlHeightMd
                onClicked: root.close()

                background: Rectangle {
                    color: cancelButton.hovered ? Theme.surfaceSunken : "transparent"
                    border.color: Theme.border
                    border.width: 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: cancelButton.text
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Button {
                id: confirmButton
                objectName: "newCategoryPromptConfirm"
                text: qsTr("新建")
                implicitHeight: Theme.controlHeightMd
                onClicked: root.submit()

                background: Rectangle {
                    color: confirmButton.hovered ? Theme.accentFillStrong : Theme.accentFill
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
