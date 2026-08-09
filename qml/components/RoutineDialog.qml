pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
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
    // 编辑复用顶部表单：0 表示新增模式，避免复制一套标题和科目输入控件后状态漂移。
    property int editingRoutineId: -1
    readonly property bool editingRoutine: editingRoutineId > 0

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
        color: "#66000000"
        opacity: root.opened ? 1 : 0

        Behavior on opacity {
            OpacityAnimator {
                duration: Theme.reduceMotion ? 0 : 180
                easing.type: Easing.InOutQuad
            }
        }
    }

    Component.onCompleted: root.refresh()

    onOpened: {
        root.errorText = ""
        root.refresh()
        routineTitleField.forceActiveFocus()
    }

    onClosed: {
        if (root.editingRoutine) {
            // 关闭弹窗等同放弃当前编辑，不能让旧标题遗留在新增模式里被误添加。
            root.editingRoutineId = -1
            routineTitleField.text = ""
            root.errorText = ""
        }
    }

    Connections {
        target: root.routineManagerRef
        ignoreUnknownSignals: true

        function onRoutinesChanged() {
            root.refresh()
        }

        function onOperationFailed(message) {
            root.errorText = String(message || "每日例行加载失败")
        }
    }

    Connections {
        target: root.categoryManagerRef
        ignoreUnknownSignals: true

        function onOperationFailed(message) {
            root.errorText = String(message || "科目加载失败")
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

        root.selectCategory(previousCategoryId)
    }

    function selectCategory(categoryId) {
        var wantedCategoryId = Number(categoryId)
        routineCategoryCombo.currentIndex = 0
        for (var i = 0; i < root.categoryOptions.length; ++i) {
            if (Number(root.categoryOptions[i].id || -1) === wantedCategoryId) {
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

    function beginEditing(routine) {
        var routineId = Number(routine && routine.id)
        if (routineId <= 0) {
            return
        }

        root.editingRoutineId = routineId
        routineTitleField.text = String(routine.title || "")
        root.selectCategory(routine.categoryId)
        root.errorText = ""
        routineTitleField.forceActiveFocus()
    }

    function cancelEditing() {
        root.editingRoutineId = -1
        routineTitleField.text = ""
        root.errorText = ""
        routineTitleField.forceActiveFocus()
    }

    function submit() {
        var isEditing = root.editingRoutine
        var operationAvailable = root.routineManagerRef
                && (isEditing ? root.routineManagerRef.updateRoutine : root.routineManagerRef.addRoutine)
        if (!operationAvailable) {
            root.errorText = isEditing ? "每日例行编辑服务不可用" : "每日例行服务不可用"
            routineTitleField.forceActiveFocus()
            return
        }

        var title = routineTitleField.text.trim()
        if (title.length === 0) {
            root.errorText = "例行任务标题不能为空"
            routineTitleField.forceActiveFocus()
            return
        }

        var succeeded = isEditing
                ? root.routineManagerRef.updateRoutine(root.editingRoutineId, title, root.selectedCategoryId())
                : root.routineManagerRef.addRoutine(title, root.selectedCategoryId())
        if (succeeded) {
            routineTitleField.text = ""
            root.editingRoutineId = -1
            root.errorText = ""
            root.refresh()
            routineTitleField.forceActiveFocus()
        } else {
            root.errorText = isEditing ? "例行任务保存失败，请检查名称后重试" : "例行任务添加失败，名称可能已存在"
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
            if (root.editingRoutineId === Number(routineId)) {
                // 正在编辑的规则被删掉后必须退出编辑态，否则后续“保存”会指向已不存在的 id。
                root.cancelEditing()
            } else {
                root.errorText = ""
            }
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
            text: root.editingRoutine
                ? "正在编辑例行任务；保存后会影响之后自动生成的任务。"
                : "把每天都要做的任务加进来，以后自动出现在今日清单。"
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
                color: Theme.ink
                placeholderTextColor: Theme.inkMuted
                selectionColor: Theme.accent
                selectedTextColor: Theme.accentForeground
                Accessible.name: root.editingRoutine ? qsTr("编辑后的例行任务名称") : qsTr("例行任务名称")
                // 与 TaskManager::kMaxTitleLength 保持一致；超长粘贴在输入端截断。
                maximumLength: 100
                selectByMouse: true

                background: Rectangle {
                    // accentForeground 是焦糖选中态的深色文字，误作底色才形成截图中的黑条。
                    color: Theme.surfaceSunken
                    border.color: root.errorText.length > 0 ? Theme.dangerBorder : (routineTitleField.activeFocus ? Theme.focusRing : Theme.border)
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
        // delegate 显式声明消费的模型角色（pragma ComponentBehavior: Bound）。
        required property var modelData

                    id: categoryDelegate
                    width: routineCategoryCombo.width

                    contentItem: RowLayout {
                        spacing: Theme.space8

                        Rectangle {
                            Layout.preferredWidth: 14
                            Layout.preferredHeight: 14
                            radius: 7
                            visible: String(categoryDelegate.modelData.color || "").length > 0
                            color: visible ? categoryDelegate.modelData.color : "transparent"
                        }

                        Text {
                            Layout.fillWidth: true
                            text: categoryDelegate.modelData.name || ""
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

                text: root.editingRoutine ? qsTr("保存") : qsTr("添加")
                implicitWidth: 76
                implicitHeight: 42
                Accessible.name: root.editingRoutine ? qsTr("保存例行任务") : qsTr("添加例行任务")
                onClicked: root.submit()

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: routineAddButton.pressed ? Theme.accentFillStrong : (routineAddButton.hovered ? Theme.accentFillStrong : Theme.accentFill)
                    border.color: Theme.accent
                    border.width: 1
                }

                contentItem: Text {
                    text: routineAddButton.text
                    // 淡罩底上不能用近白的 surface 当字色，会直接消失。
                    color: Theme.accentFillInk
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space8
            Layout.preferredHeight: visible ? 36 : 0
            visible: root.errorText.length > 0 || root.editingRoutine
            spacing: Theme.space8

            Label {
                Layout.fillWidth: true
                text: root.errorText.length > 0
                    ? root.errorText
                    : qsTr("保存后仅影响后续自动生成的任务。")
                color: root.errorText.length > 0 ? Theme.danger : Theme.inkSoft
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
            }

            Button {
                id: routineCancelEditButton
                objectName: "routineCancelEditButton"

                visible: root.editingRoutine
                text: qsTr("取消编辑")
                implicitWidth: 76
                implicitHeight: 34
                Accessible.name: qsTr("取消编辑例行任务")
                onClicked: root.cancelEditing()

                background: Rectangle {
                    radius: Theme.radiusSm
                    color: routineCancelEditButton.pressed
                        ? Theme.glassHover
                        : (routineCancelEditButton.hovered ? Theme.glassHover : Theme.glassCard)
                    border.color: routineCancelEditButton.hovered || routineCancelEditButton.pressed
                        ? Theme.accent
                        : Theme.border
                    border.width: 1
                }

                contentItem: Text {
                    text: routineCancelEditButton.text
                    color: Theme.ink
                    font.pixelSize: Theme.fontSm
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
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
                                    ColorAnimation { duration: Theme.reduceMotion ? 0 : 120; easing.type: Easing.OutQuad }
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
                                        NumberAnimation { duration: Theme.reduceMotion ? 0 : 120; easing.type: Easing.OutQuad }
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
                            id: editButton
                            objectName: "routineEditButton"

                            text: qsTr("编辑")
                            implicitWidth: 64
                            implicitHeight: 34
                            Accessible.name: qsTr("编辑例行任务")
                            onClicked: root.beginEditing(routineRow.modelData)

                            background: Rectangle {
                                radius: Theme.radiusSm
                                color: editButton.pressed ? Theme.glassHover : (editButton.hovered ? Theme.glassHover : Theme.glassCard)
                                border.color: editButton.hovered || editButton.pressed ? Theme.accent : Theme.border
                                border.width: 1
                            }

                            contentItem: Text {
                                text: editButton.text
                                color: Theme.accentFillInk
                                font.pixelSize: Theme.fontMd
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
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
