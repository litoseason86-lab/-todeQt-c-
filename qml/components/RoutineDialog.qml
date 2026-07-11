import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."

Popup {
    id: root
    objectName: "routineDialog"

    property var routineManagerRef: null
    property var categoryManagerRef: null
    property var routines: []
    // -1 是“不设置科目”的约定值，传给服务层后由服务层决定是否写入空科目。
    property var categoryOptions: [
        {
            id: -1,
            name: "不设置科目",
            color: ""
        }
    ]
    property string errorText: ""

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(620, parent ? Math.max(360, parent.width - 64) : 620)
    height: Math.min(640, parent ? Math.max(420, parent.height - 64) : 640)
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

    Component.onCompleted: root.refresh()

    onOpened: {
        root.refresh()
        root.errorText = ""
        routineTitleField.forceActiveFocus()
    }

    Connections {
        target: root.routineManagerRef
        ignoreUnknownSignals: true

        function onRoutinesChanged() {
            root.refresh()
        }
    }

    function refresh() {
        var previousCategoryId = root.selectedCategoryId()
        if (root.routineManagerRef && root.routineManagerRef.getRoutines) {
            root.routines = root.routineManagerRef.getRoutines()
        } else {
            root.routines = []
        }

        var categories = []
        if (root.categoryManagerRef && root.categoryManagerRef.getAllCategories) {
            categories = root.categoryManagerRef.getAllCategories()
        }
        root.categoryOptions = [{
            id: -1,
            name: "不设置科目",
            color: ""
        }].concat(categories)

        routineCategoryCombo.currentIndex = 0
        for (var i = 0; i < root.categoryOptions.length; ++i) {
            if (Number(root.categoryOptions[i].id || -1) === previousCategoryId) {
                routineCategoryCombo.currentIndex = i
                break
            }
        }
    }

    function selectedCategoryId() {
        var index = routineCategoryCombo.currentIndex
        if (index < 0 || index >= root.categoryOptions.length) {
            return -1
        }

        var option = root.categoryOptions[index]
        return option && option.id !== undefined && option.id !== null ? Number(option.id) : -1
    }

    function submit() {
        if (!root.routineManagerRef || !root.routineManagerRef.addRoutine) {
            root.errorText = "每日例行服务不可用"
            routineTitleField.forceActiveFocus()
            return
        }

        var title = routineTitleField.text.trim()
        if (title.length === 0) {
            root.errorText = "例行任务标题不能为空"
            routineTitleField.forceActiveFocus()
            return
        }

        if (root.routineManagerRef.addRoutine(title, root.selectedCategoryId())) {
            routineTitleField.text = ""
            root.errorText = ""
            root.refresh()
            routineTitleField.forceActiveFocus()
        } else {
            root.errorText = "例行任务添加失败，名称可能已存在"
            routineTitleField.forceActiveFocus()
        }
    }

    function setRoutineActive(routineId, active) {
        if (!root.routineManagerRef || !root.routineManagerRef.setRoutineActive) {
            root.errorText = "每日例行服务不可用"
            return
        }

        if (!root.routineManagerRef.setRoutineActive(routineId, active)) {
            root.errorText = "例行任务状态更新失败"
            root.refresh()
        }
    }

    function deleteRoutine(routineId) {
        if (!root.routineManagerRef || !root.routineManagerRef.deleteRoutine) {
            root.errorText = "每日例行服务不可用"
            return
        }

        if (root.routineManagerRef.deleteRoutine(routineId)) {
            root.errorText = ""
            root.refresh()
        } else {
            root.errorText = "例行任务删除失败"
        }
    }

    background: Rectangle {
        id: panel

        implicitWidth: root.width
        implicitHeight: root.height
        radius: Theme.radiusMd
        color: Theme.glassDialog
        border.color: Theme.border
        border.width: 1
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
        width: root.width
        height: root.height
        spacing: 0

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            radius: Theme.radiusMd
            color: Theme.surface

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.space16
                anchors.rightMargin: Theme.space12
                spacing: Theme.space12

                Text {
                    Layout.fillWidth: true
                    text: "每日例行"
                    font.pixelSize: Theme.fontXl
                    font.bold: true
                    color: Theme.ink
                }

                Button {
                    id: closeButton

                    text: "关闭"
                    implicitWidth: 72
                    implicitHeight: 36
                    onClicked: root.close()

                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: closeButton.pressed ? Theme.glassHover : (closeButton.hovered ? Theme.glassHover : Theme.glassCard)
                        border.color: closeButton.hovered || closeButton.pressed ? Theme.accent : Theme.border
                        border.width: 1
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

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space12
            text: "把每天都要做的任务加进来，以后自动出现在今日清单。"
            color: Theme.inkSoft
            font.pixelSize: Theme.fontMd
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space16
            spacing: Theme.space8

            TextField {
                id: routineTitleField
                objectName: "routineTitleField"

                Layout.fillWidth: true
                implicitHeight: 42
                placeholderText: "输入每天要做的事..."
                selectByMouse: true

                background: Rectangle {
                    color: Theme.surface
                    border.color: root.errorText.length > 0 ? Theme.dangerBorder : (routineTitleField.activeFocus ? Theme.accent : Theme.border)
                    border.width: root.errorText.length > 0 || routineTitleField.activeFocus ? 2 : 1
                    radius: Theme.radiusMd
                }

                onTextEdited: {
                    if (text.trim().length > 0) {
                        root.errorText = ""
                    }
                }

                Keys.onReturnPressed: root.submit()
                Keys.onEnterPressed: root.submit()
            }

            ComboBox {
                id: routineCategoryCombo
                objectName: "routineCategoryCombo"

                Layout.preferredWidth: 180
                implicitHeight: 42
                // 统一左右内边距：左边让文字不贴框（无色点时也不顶边），右边给下拉箭头留位。
                leftPadding: Theme.space12
                rightPadding: 30
                model: root.categoryOptions
                textRole: "name"
                currentIndex: 0
                displayText: currentIndex >= 0 && currentIndex < root.categoryOptions.length ? root.categoryOptions[currentIndex].name : "选择科目"

                background: Rectangle {
                    color: routineCategoryCombo.down || routineCategoryCombo.pressed ? Theme.accentSoft : (routineCategoryCombo.hovered ? Theme.surfaceSunken : Theme.surface)
                    border.color: routineCategoryCombo.down || routineCategoryCombo.pressed ? Theme.accent : Theme.border
                    border.width: routineCategoryCombo.down || routineCategoryCombo.pressed ? 2 : 1
                    radius: Theme.radiusMd
                }

                indicator: Text {
                    x: routineCategoryCombo.width - width - 12
                    y: Math.round((routineCategoryCombo.height - height) / 2)
                    text: "▾"
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                    rotation: routineCategoryCombo.down ? 180 : 0
                    transformOrigin: Item.Center
                }

                contentItem: RowLayout {
                    spacing: Theme.space8

                    Rectangle {
                        Layout.preferredWidth: 14
                        Layout.preferredHeight: 14
                        radius: 7
                        visible: routineCategoryCombo.currentIndex >= 0
                                 && routineCategoryCombo.currentIndex < root.categoryOptions.length
                                 && String(root.categoryOptions[routineCategoryCombo.currentIndex].color || "").length > 0
                        color: visible ? root.categoryOptions[routineCategoryCombo.currentIndex].color : "transparent"
                    }

                    Text {
                        Layout.fillWidth: true
                        text: routineCategoryCombo.displayText
                        color: Theme.ink
                        font.pixelSize: Theme.fontMd
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }
                }

                delegate: ItemDelegate {
                    id: categoryDelegate
                    width: routineCategoryCombo.width

                    contentItem: RowLayout {
                        spacing: Theme.space8

                        Rectangle {
                            Layout.preferredWidth: 14
                            Layout.preferredHeight: 14
                            radius: 7
                            visible: String(modelData.color || "").length > 0
                            color: visible ? modelData.color : "transparent"
                        }

                        Text {
                            Layout.fillWidth: true
                            text: modelData.name || ""
                            color: Theme.ink
                            font.pixelSize: Theme.fontMd
                            elide: Text.ElideRight
                        }
                    }

                    background: Rectangle {
                        color: categoryDelegate.highlighted || categoryDelegate.hovered ? Theme.accentSoft : "transparent"
                    }
                }
            }

            Button {
                id: routineAddButton
                objectName: "routineAddButton"

                text: "添加"
                implicitWidth: 76
                implicitHeight: 42
                onClicked: root.submit()

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: routineAddButton.pressed ? Theme.accentStrong : (routineAddButton.hovered ? Theme.accentStrong : Theme.accent)
                    border.color: Theme.accent
                    border.width: 1
                }

                contentItem: Text {
                    text: routineAddButton.text
                    color: Theme.surface
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space8
            visible: root.errorText.length > 0
            text: root.errorText
            color: Theme.danger
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space16
            Layout.preferredHeight: 1
            color: Theme.border
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space12
            Layout.bottomMargin: Theme.space16

            ListView {
                id: routineListView
                objectName: "routineListView"

                anchors.fill: parent
                clip: true
                spacing: Theme.space8
                model: root.routines

                delegate: Rectangle {
                    id: routineRow

                    required property var modelData

                    width: routineListView.width
                    height: 56
                    radius: Theme.radiusMd
                    color: Theme.surface
                    border.color: Theme.border
                    border.width: 1

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.space12
                        anchors.rightMargin: Theme.space8
                        spacing: Theme.space8

                        Rectangle {
                            Layout.preferredWidth: 12
                            Layout.preferredHeight: 12
                            radius: 6
                            color: String(routineRow.modelData.categoryColor || "").length > 0 ? routineRow.modelData.categoryColor : Theme.border
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space4

                            Text {
                                Layout.fillWidth: true
                                text: routineRow.modelData.title || ""
                                color: routineRow.modelData.active === false ? Theme.inkMuted : Theme.ink
                                font.pixelSize: Theme.fontLg
                                elide: Text.ElideRight
                            }

                            Text {
                                Layout.fillWidth: true
                                text: routineRow.modelData.categoryName && routineRow.modelData.categoryName.length > 0 ? routineRow.modelData.categoryName : "不设置科目"
                                color: Theme.inkSoft
                                font.pixelSize: Theme.fontSm
                                elide: Text.ElideRight
                            }
                        }

                        Switch {
                            id: activeSwitch

                            checked: routineRow.modelData.active !== false
                            text: checked ? "启用" : "停用"
                            spacing: Theme.space8
                            onToggled: {
                                // 列表项只负责把用户意图转交给服务层；刷新由服务信号或失败回滚触发。
                                root.setRoutineActive(Number(routineRow.modelData.id), checked)
                            }

                            // 自定义暖纸拨钮：开=accent、关=灰，白色滑块滑动；取代 Basic 默认难看的深色样式。
                            indicator: Rectangle {
                                implicitWidth: 40
                                implicitHeight: 22
                                radius: height / 2
                                x: activeSwitch.leftPadding
                                y: activeSwitch.height / 2 - height / 2
                                color: activeSwitch.checked ? Theme.accent : Theme.borderSubtle
                                border.color: activeSwitch.checked ? Theme.accentStrong : Theme.border
                                border.width: 1

                                Behavior on color {
                                    ColorAnimation { duration: 120; easing.type: Easing.OutQuad }
                                }

                                Rectangle {
                                    width: 18
                                    height: 18
                                    radius: height / 2
                                    y: 2
                                    x: activeSwitch.checked ? parent.width - width - 2 : 2
                                    color: Theme.surface
                                    border.color: Theme.border
                                    border.width: 1

                                    Behavior on x {
                                        NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
                                    }
                                }
                            }

                            contentItem: Text {
                                text: activeSwitch.text
                                color: activeSwitch.checked ? Theme.ink : Theme.inkSoft
                                font.pixelSize: Theme.fontSm
                                verticalAlignment: Text.AlignVCenter
                                // 文字让开左侧拨钮，避免重叠。
                                leftPadding: activeSwitch.indicator.width + activeSwitch.spacing
                            }
                        }

                        Button {
                            id: deleteButton

                            text: "删除"
                            implicitWidth: 64
                            implicitHeight: 34
                            onClicked: root.deleteRoutine(Number(routineRow.modelData.id))

                            background: Rectangle {
                                radius: Theme.radiusSm
                                color: deleteButton.pressed ? Theme.glassHover : (deleteButton.hovered ? Theme.glassHover : Theme.glassCard)
                                border.color: deleteButton.hovered || deleteButton.pressed ? Theme.dangerSoft : Theme.border
                                border.width: 1
                            }

                            contentItem: Text {
                                text: deleteButton.text
                                color: Theme.dangerSoft
                                font.pixelSize: Theme.fontMd
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                }
            }

            Label {
                anchors.centerIn: parent
                width: Math.min(parent.width - Theme.space32, 420)
                visible: routineListView.count === 0
                text: "把每天都要做的任务加进来，以后自动出现在今日清单。"
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
        }
    }
}
