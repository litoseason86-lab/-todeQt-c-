pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

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

    property var manager: null
    property var categories: []
    property string errorText: ""
    property string newCategoryColor: "#d4a574"
    property int editingCategoryId: -1
    // 编辑状态由 id 推导，让同一套表单同时服务新增和更新。
    property bool editingCategory: editingCategoryId > 0

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(540, parent ? Math.max(320, parent.width - 64) : 540)
    height: Math.min(620, parent ? Math.max(360, parent.height - 64) : 620)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 0.96
                to: 1.0
                duration: Theme.reduceMotion ? 0 : 180
                easing.type: Easing.OutQuad
            }
            OpacityAnimator {
                from: 0
                to: 1
                duration: Theme.reduceMotion ? 0 : 180
                easing.type: Easing.OutQuad
            }
        }
    }

    exit: Transition {
        OpacityAnimator {
            from: 1
            to: 0
            duration: Theme.reduceMotion ? 0 : 160
            easing.type: Easing.InQuad
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

    Component.onCompleted: refresh()
    onOpened: refresh()

    Connections {
        target: root.manager
        ignoreUnknownSignals: true

        function onCategoriesChanged() {
            root.refresh()
        }

        function onOperationFailed(message) {
            root.errorText = String(message || "科目加载失败")
        }
    }

    function refresh() {
        if (root.manager && root.manager.getAllCategories) {
            root.categories = root.manager.getAllCategories()
        } else {
            root.categories = []
        }
    }

    function resetAddForm() {
        categoryNameInput.text = ""
        root.editingCategoryId = -1
        root.newCategoryColor = "#d4a574"
        colorPicker.selectedColor = root.newCategoryColor
        root.errorText = ""
        addCategoryPanel.visible = false
    }

    function beginAdd() {
        root.resetAddForm()
        root.errorText = ""
        addCategoryPanel.visible = true
        categoryNameInput.forceActiveFocus()
    }

    function beginEdit(category) {
        if (!category) {
            return
        }

        root.errorText = ""
        root.editingCategoryId = Number(category.id || -1)
        categoryNameInput.text = category.name || ""
        root.newCategoryColor = category.color || "#d4a574"
        colorPicker.selectedColor = root.newCategoryColor
        addCategoryPanel.visible = true
        categoryNameInput.forceActiveFocus()
    }

    function saveCategory() {
        if (root.editingCategory) {
            root.updateCategory()
        } else {
            root.addCategory()
        }
    }

    function addCategory() {
        if (!root.manager || !root.manager.addCategory) {
            root.errorText = "科目服务不可用"
            return
        }

        var name = categoryNameInput.text.trim()
        if (name.length === 0) {
            root.errorText = "科目名称不能为空"
            categoryNameInput.forceActiveFocus()
            return
        }

        var id = root.manager.addCategory(name, root.newCategoryColor)
        if (id > 0) {
            root.resetAddForm()
            root.refresh()
        } else {
            root.errorText = "科目添加失败，名称可能已存在"
        }
    }

    function updateCategory() {
        if (!root.manager || !root.manager.updateCategory) {
            root.errorText = "科目服务不可用"
            return
        }

        var name = categoryNameInput.text.trim()
        if (name.length === 0) {
            root.errorText = "科目名称不能为空"
            categoryNameInput.forceActiveFocus()
            return
        }

        if (root.manager.updateCategory(root.editingCategoryId, name, root.newCategoryColor)) {
            root.resetAddForm()
            root.refresh()
        } else {
            root.errorText = "科目更新失败，名称可能已存在"
        }
    }

    function deleteCategory(categoryId) {
        if (!root.manager || !root.manager.canDeleteCategory || !root.manager.deleteCategory) {
            root.errorText = "科目服务不可用"
            return
        }

        if (!root.manager.canDeleteCategory(categoryId)) {
            root.errorText = "该科目不能删除"
            return
        }

        // 服务层会先解除任务关联，所以自定义科目可以安全删除。
        if (!root.manager.deleteCategory(categoryId)) {
            root.errorText = "科目删除失败"
            return
        }

        root.errorText = ""
        root.refresh()
    }

    background: Rectangle {
        id: panel

        implicitWidth: root.width
        implicitHeight: root.height
        radius: Theme.radiusMd
        color: Theme.glassDialog
        border.color: Theme.border
        border.width: 1
    }

    contentItem: Item {
        width: root.width
        height: root.height

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 52
                radius: Theme.radiusMd
                color: Theme.surface

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space16
                    anchors.rightMargin: Theme.space12
                    spacing: Theme.space12

                    Text {
                        Layout.fillWidth: true
                        text: "科目管理"
                        font.pixelSize: Theme.fontXl
                        font.bold: true
                        color: Theme.ink
                    }

                    Button {
                        id: addButton
                        objectName: "addCategoryButton"

                        text: "添加科目"
                        implicitWidth: 92
                        implicitHeight: 36
                        onClicked: root.beginAdd()

                        background: Rectangle {
                            radius: Theme.radiusSm
                            color: addButton.pressed ? Theme.accentFillStrong : Theme.accentFill
                        }

                        contentItem: Text {
                            text: addButton.text
                            color: Theme.accentFillInk
                            font.pixelSize: Theme.fontMd
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }

            Label {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                Layout.topMargin: Theme.space12
                visible: root.errorText.length > 0
                text: root.errorText
                color: Theme.danger
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
            }

            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.margins: Theme.space16
                clip: true

                ListView {
                    id: categoryListView
                    objectName: "categoryListView"

                    model: root.categories
                    spacing: Theme.space8
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Rectangle {
                        id: categoryRow

                        // delegate 显式声明消费的模型角色（pragma ComponentBehavior: Bound）。
                        required property var modelData

                        width: categoryListView.width
                        height: 60
                        radius: Theme.radiusMd
                        color: Theme.surface
                        border.color: Theme.border
                        border.width: 1

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: Theme.space12
                            spacing: Theme.space12

                            Rectangle {
                                Layout.preferredWidth: 34
                                Layout.preferredHeight: 34
                                radius: 5
                                color: categoryRow.modelData.color || "#d4a574"
                                border.color: Theme.border
                                border.width: 1
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.hairline

                                Text {
                                    Layout.fillWidth: true
                                    text: categoryRow.modelData.name || ""
                                    font.pixelSize: Theme.fontLg
                                    font.bold: true
                                    color: Theme.ink
                                    elide: Text.ElideRight
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: categoryRow.modelData.isPreset ? "预设科目" : "自定义科目"
                                    font.pixelSize: Theme.fontXs
                                    color: Theme.inkSoft
                                    elide: Text.ElideRight
                                }
                            }

                            Button {
                                id: editButton
                                objectName: "editCategoryButton-" + Number(categoryRow.modelData.id)

                                text: "编辑"
                                implicitWidth: 64
                                implicitHeight: 34
                                onClicked: root.beginEdit(categoryRow.modelData)

                                background: Rectangle {
                                    radius: Theme.radiusSm
                                    color: editButton.pressed ? Theme.accentSoft : "transparent"
                                    border.color: Theme.border
                                    border.width: 1
                                }

                                contentItem: Text {
                                    text: editButton.text
                                    color: Theme.ink
                                    font.pixelSize: Theme.fontSm
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }

                            Button {
                                id: deleteButton

                                visible: !categoryRow.modelData.isPreset
                                text: "删除"
                                implicitWidth: 64
                                implicitHeight: 34
                                onClicked: root.deleteCategory(categoryRow.modelData.id)

                                background: Rectangle {
                                    radius: Theme.radiusSm
                                    color: deleteButton.pressed ? Theme.accentSoft : "transparent"
                                    border.color: Theme.border
                                    border.width: 1
                                }

                                contentItem: Text {
                                    text: deleteButton.text
                                    color: Theme.dangerSoft
                                    font.pixelSize: Theme.fontSm
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                Layout.bottomMargin: Theme.space16

                Item {
                    Layout.fillWidth: true
                }

                Button {
                    id: closeButton
                    objectName: "closeCategoryDialogButton"

                    text: "关闭"
                    implicitWidth: 80
                    implicitHeight: 40
                    onClicked: root.close()

                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: Theme.border
                    }

                    contentItem: Text {
                        text: closeButton.text
                        color: Theme.ink
                        font.pixelSize: Theme.fontMd
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        Rectangle {
            id: addCategoryPanel

            anchors.fill: parent
            visible: false
            radius: Theme.radiusMd
            color: Theme.surfaceRaised
            border.color: Theme.border
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.space16
                spacing: Theme.space12

                Text {
                    Layout.fillWidth: true
                    text: root.editingCategory ? "编辑科目" : "添加新科目"
                    font.pixelSize: Theme.fontXl
                    font.bold: true
                    color: Theme.ink
                }

                TextField {
                    id: categoryNameInput
                    objectName: "categoryNameInput"

                    Layout.fillWidth: true
                    implicitHeight: 42
                    placeholderText: "科目名称"
                    selectByMouse: true

                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: Theme.surface
                        border.color: categoryNameInput.activeFocus ? Theme.accent : Theme.border
                        border.width: 1
                    }

                    Keys.onReturnPressed: root.saveCategory()
                    Keys.onEnterPressed: root.saveCategory()
                }

                ColorPicker {
                    id: colorPicker

                    Layout.fillWidth: true
                    selectedColor: root.newCategoryColor
                    onColorSelected: function(color) {
                        root.newCategoryColor = color
                    }
                }

                Item {
                    Layout.fillHeight: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space8

                    Button {
                        id: cancelAddButton

                        Layout.fillWidth: true
                        text: "取消"
                        implicitHeight: 42
                        onClicked: root.resetAddForm()

                        background: Rectangle {
                            radius: Theme.radiusSm
                            color: Theme.border
                        }

                        contentItem: Text {
                            text: cancelAddButton.text
                            color: Theme.ink
                            font.pixelSize: Theme.fontMd
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Button {
                        id: saveCategoryButton

                        objectName: "saveCategoryButton"
                        Layout.fillWidth: true
                        text: root.editingCategory ? "更新" : "保存"
                        enabled: categoryNameInput.text.trim().length > 0
                        implicitHeight: 42
                        onClicked: root.saveCategory()

                        background: Rectangle {
                            radius: Theme.radiusSm
                            color: saveCategoryButton.enabled ? Theme.accentFill : Theme.border
                        }

                        contentItem: Text {
                            text: saveCategoryButton.text
                            color: saveCategoryButton.enabled ? Theme.accentFillInk : Theme.inkSoft
                            font.pixelSize: Theme.fontMd
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }
        }
    }
}
