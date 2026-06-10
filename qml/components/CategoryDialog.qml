import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id: root

    property var manager: null
    property var categories: []
    property string errorText: ""
    property string newCategoryColor: "#d4a574"
    property int editingCategoryId: -1
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
                duration: 180
                easing.type: Easing.OutQuad
            }
            OpacityAnimator {
                from: 0
                to: 1
                duration: 180
                easing.type: Easing.OutQuad
            }
        }
    }

    exit: Transition {
        OpacityAnimator {
            from: 1
            to: 0
            duration: 160
            easing.type: Easing.InQuad
        }
    }

    Overlay.modal: Rectangle {
        color: "#66000000"
        opacity: root.opened ? 1 : 0

        Behavior on opacity {
            OpacityAnimator {
                duration: 180
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
        if (!category || category.isPreset) {
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
        radius: 6
        color: "#faf6ee"
        border.color: "#e8dfc8"
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
                radius: 6
                color: "#fffef9"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 12
                    spacing: 12

                    Text {
                        Layout.fillWidth: true
                        text: "科目管理"
                        font.pixelSize: 16
                        font.bold: true
                        color: "#5d4e37"
                    }

                    Button {
                        id: addButton
                        objectName: "addCategoryButton"

                        text: "添加科目"
                        implicitWidth: 92
                        implicitHeight: 36
                        onClicked: root.beginAdd()

                        background: Rectangle {
                            radius: 4
                            color: addButton.pressed ? "#c9956e" : "#d4a574"
                        }

                        contentItem: Text {
                            text: addButton.text
                            color: "#fffef9"
                            font.pixelSize: 13
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }

            Label {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.topMargin: 10
                visible: root.errorText.length > 0
                text: root.errorText
                color: "#b24f3d"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.margins: 16
                clip: true

                ListView {
                    id: categoryListView
                    objectName: "categoryListView"

                    model: root.categories
                    spacing: 8
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Rectangle {
                        width: categoryListView.width
                        height: 60
                        radius: 6
                        color: "#fffef9"
                        border.color: "#e8dfc8"
                        border.width: 1

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 12

                            Rectangle {
                                Layout.preferredWidth: 34
                                Layout.preferredHeight: 34
                                radius: 5
                                color: modelData.color || "#d4a574"
                                border.color: "#e8dfc8"
                                border.width: 1
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.name || ""
                                    font.pixelSize: 14
                                    font.bold: true
                                    color: "#5d4e37"
                                    elide: Text.ElideRight
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.isPreset ? "预设科目" : "自定义科目"
                                    font.pixelSize: 11
                                    color: "#8b7355"
                                    elide: Text.ElideRight
                                }
                            }

                            Button {
                                id: editButton

                                visible: !modelData.isPreset
                                text: "编辑"
                                implicitWidth: 64
                                implicitHeight: 34
                                onClicked: root.beginEdit(modelData)

                                background: Rectangle {
                                    radius: 4
                                    color: editButton.pressed ? "#f0e6d2" : "transparent"
                                    border.color: "#e8dfc8"
                                    border.width: 1
                                }

                                contentItem: Text {
                                    text: editButton.text
                                    color: "#5d4e37"
                                    font.pixelSize: 12
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }

                            Button {
                                id: deleteButton

                                visible: !modelData.isPreset
                                text: "删除"
                                implicitWidth: 64
                                implicitHeight: 34
                                onClicked: root.deleteCategory(modelData.id)

                                background: Rectangle {
                                    radius: 4
                                    color: deleteButton.pressed ? "#f0e6d2" : "transparent"
                                    border.color: "#e8dfc8"
                                    border.width: 1
                                }

                                contentItem: Text {
                                    text: deleteButton.text
                                    color: "#b37562"
                                    font.pixelSize: 12
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
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.bottomMargin: 16

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
                        radius: 4
                        color: "#e8dfc8"
                    }

                    contentItem: Text {
                        text: closeButton.text
                        color: "#5d4e37"
                        font.pixelSize: 13
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
            radius: 6
            color: "#faf6ee"
            border.color: "#e8dfc8"
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 18
                spacing: 14

                Text {
                    Layout.fillWidth: true
                    text: root.editingCategory ? "编辑科目" : "添加新科目"
                    font.pixelSize: 16
                    font.bold: true
                    color: "#5d4e37"
                }

                TextField {
                    id: categoryNameInput
                    objectName: "categoryNameInput"

                    Layout.fillWidth: true
                    implicitHeight: 42
                    placeholderText: "科目名称"
                    selectByMouse: true

                    background: Rectangle {
                        radius: 4
                        color: "#fffef9"
                        border.color: categoryNameInput.activeFocus ? "#d4a574" : "#e8dfc8"
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
                    spacing: 8

                    Button {
                        id: cancelAddButton

                        Layout.fillWidth: true
                        text: "取消"
                        implicitHeight: 42
                        onClicked: root.resetAddForm()

                        background: Rectangle {
                            radius: 4
                            color: "#e8dfc8"
                        }

                        contentItem: Text {
                            text: cancelAddButton.text
                            color: "#5d4e37"
                            font.pixelSize: 13
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
                            radius: 4
                            color: saveCategoryButton.enabled ? "#d4a574" : "#e8dfc8"
                        }

                        contentItem: Text {
                            text: saveCategoryButton.text
                            color: saveCategoryButton.enabled ? "#fffef9" : "#8b7355"
                            font.pixelSize: 13
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }
        }
    }
}
