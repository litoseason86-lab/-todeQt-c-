pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."
import "../RoutineWeekdays.js" as Weekdays

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
    // 列表行高。面板高度要按「条数 × 行高」算，所以它必须是一个两边共用的常量。
    readonly property int routineRowHeight: 52
    // 重复弹窗的对外句柄：它是 Popup，不在可视子项树里，findChild 拿不到。
    readonly property alias weekdayDialogRef: weekdayDialog
    // 编辑复用顶部表单：0 表示新增模式，避免复制一套标题和科目输入控件后状态漂移。
    property int editingRoutineId: -1
    readonly property bool editingRoutine: editingRoutineId > 0
    // 开始编辑那一刻的标题和科目。保存时和它比，只交出改过的字段：编辑开着时另一台改了另一项，
    // 同步写进来的新值不会被这里的旧值盖掉。
    property var editingOpenedValues: ({})

    // 重复日不在这个表单里编辑：新增一律按「每天」落地，之后在列表行的重复药丸里改。
    // 星期的位掩码与文案口径统一在 RoutineWeekdays.js（对应 C++ 的 RoutineRules.h）。

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
        color: Theme.dialogScrim
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

    // 打开某条例行的「重复」弹窗。草稿状态都在那个弹窗里，这里只负责把当前值交过去。
    function editWeekdays(routine) {
        weekdayDialog.openFor(routine)
    }

    function beginEditing(routine) {
        var routineId = Number(routine && routine.id)
        if (routineId <= 0) {
            return
        }

        root.editingRoutineId = routineId
        routineTitleField.text = String(routine.title || "")
        root.selectCategory(routine.categoryId)
        root.editingOpenedValues = {
            title: routineTitleField.text,
            categoryId: root.selectedCategoryId()
        }
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
                && (isEditing ? root.routineManagerRef.updateRoutineChanges : root.routineManagerRef.addRoutine)
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

        // 新增不带重复日：服务层默认按「每天」落地，之后在列表行的重复药丸里改。
        // 改标题/科目也不碰重复日——两者在服务层就是两条独立的写入。
        var succeeded
        if (isEditing) {
            var changes = {}
            if (routineTitleField.text !== root.editingOpenedValues.title)
                changes.title = title
            if (root.selectedCategoryId() !== root.editingOpenedValues.categoryId)
                changes.categoryId = root.selectedCategoryId()
            // 什么都没改：不写库，照常退出编辑。
            succeeded = Object.keys(changes).length === 0
                    || root.routineManagerRef.updateRoutineChanges(root.editingRoutineId, changes)
        } else {
            succeeded = root.routineManagerRef.addRoutine(title, root.selectedCategoryId())
        }
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

    // 重复日的独立弹窗。parent 指到本弹窗的内容区，它才会居中盖在这个弹窗上，
    // 而不是飘到窗口左上角。
    RoutineWeekdayDialog {
        id: weekdayDialog
        objectName: "routineWeekdayDialogInstance"

        parent: root.contentItem
        routineManagerRef: root.routineManagerRef
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
                    implicitHeight: Theme.controlHeightMd
                    onClicked: root.close()

                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: closeButton.pressed ? Theme.glassHover : (closeButton.hovered ? Theme.glassHover : Theme.glassCard)
                        border.color: closeButton.hovered || closeButton.pressed ? Theme.accent : Theme.border
                        border.width: 1
                    }

                    contentItem: Text {
                        text: closeButton.text
                        textFormat: Text.PlainText
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
            // 只在编辑态占这一行，用来说明「现在改的是一条已存在的规则」。
            // 非编辑态原本显示的那句介绍，和空列表中间那句一字不差——两处同时出现纯属噪音，
            // 介绍交给空状态那一处即可。布局会整体忽略不可见的子项（连同外边距），表单会自然上移。
            visible: root.editingRoutine
            text: "正在编辑例行任务；保存后会影响之后自动生成的任务。"
            textFormat: Text.PlainText
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
                implicitHeight: Theme.controlHeightLg
                placeholderText: "输入要重复做的事..."
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
                implicitHeight: Theme.controlHeightLg
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
                        textFormat: Text.PlainText
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
                            textFormat: Text.PlainText
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
                id: routineCancelEditButton
                objectName: "routineCancelEditButton"

                // 只在编辑态出现，并且就挨着「保存」：它原本独占一整行，
                // 一行里只有右下角一个按钮，其余全是空白。
                visible: root.editingRoutine
                text: qsTr("取消")
                implicitWidth: 64
                implicitHeight: Theme.controlHeightLg
                Accessible.name: qsTr("取消编辑例行任务")
                onClicked: root.cancelEditing()

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: routineCancelEditButton.hovered || routineCancelEditButton.pressed
                        ? Theme.glassHover
                        : Theme.glassCard
                    border.color: Theme.border
                    border.width: 1
                }

                contentItem: Text {
                    text: routineCancelEditButton.text
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Button {
                id: routineAddButton
                objectName: "routineAddButton"

                text: root.editingRoutine ? qsTr("保存") : qsTr("添加")
                implicitWidth: 76
                implicitHeight: Theme.controlHeightLg
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
                    textFormat: Text.PlainText
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
            visible: root.errorText.length > 0
            spacing: Theme.space8

            Label {
                Layout.fillWidth: true
                // 这一行只负责报错。原本没错时会显示「保存后仅影响后续自动生成的任务」，
                // 与上方编辑提示说的是同一件事，两句一起出现只是把弹窗撑高。
                text: root.errorText
                textFormat: Text.PlainText
                color: Theme.danger
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
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

            // 整块面板 + 行间发丝线，取代六张浮起的圆角卡。
            // 等大圆角卡堆叠会让列表读成「六个物件」而不是「一个列表」，
            // 而且每张卡自带边框和间距，同样高度能放的行数更少。
            Rectangle {
                id: listPanel

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                // 面板贴着内容收，不要一路拉到弹窗底：带边框的空框子比「什么都没有」更显眼，
                // 只有几条例行时下面会是一大块被框起来的空白。行数多了就封顶，由列表自己滚。
                //
                // 高度按「条数 × 行高」算，不能用 routineListView.contentHeight：
                // contentHeight 是从**已创建的**委托推算出来的，而 ListView 又只按自己的高度
                // 决定创建几个委托——高度取自 contentHeight 就成了一个反馈环。它最终会收敛，
                // 但要跨好几帧，并行跑测试时来不及收敛就会偶发失败（实测约四次一红）。
                height: Math.min(parent.height, root.routines.length * root.routineRowHeight + 2)
                visible: routineListView.count > 0
                radius: Theme.radiusMd
                color: Theme.surface
                border.color: Theme.border
                border.width: 1
                // 行底色是整行铺满的，不裁切会在面板的圆角处露出方角。
                clip: true
            }

            ListView {
                id: routineListView
                objectName: "routineListView"

                anchors.fill: listPanel
                anchors.margins: 1
                clip: true
                spacing: 0
                model: root.routines

                delegate: Rectangle {
                    id: routineRow

                    required property var modelData
                    required property int index

                    readonly property bool routineActive: routineRow.modelData.active !== false
                    readonly property bool beingEdited: root.editingRoutineId === Number(routineRow.modelData.id)

                    width: routineListView.width
                    height: root.routineRowHeight
                    // 停用的例行整行退到底色后面：原来只把标题改成浅灰，
                    // 一列扫下来分不清哪条是停用的，开关又在最右边，要来回对照。
                    //
                    // 这里必须用 surfaceSunken 而不是 surfaceRaised：raised 在浅色下比 surface 深
                    // （看起来是往后退），在夜间主题下却比 surface 亮——停用行反而成了整列里最扎眼的一条。
                    // sunken 在两套主题下都比 surface 暗，语义才是一致的「沉下去」。
                    color: routineRow.routineActive ? Theme.surface : Theme.surfaceSunken

                    // 行之间只有一条发丝线，首行不画——列表边界由外面那块面板负责。
                    Rectangle {
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: Theme.space12
                        anchors.rightMargin: Theme.space12
                        height: 1
                        color: Theme.borderSubtle
                        visible: routineRow.index > 0
                    }

                    // 正在编辑的那条：贴左边一条强调色竖条。表单在弹窗顶部，
                    // 列表往下一滚就看不出自己改的是哪一条了。没有卡片边框之后，
                    // 用这根竖条代替原来的描边——它不会把这一行重新框成一个盒子。
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 3
                        color: Theme.accent
                        visible: routineRow.beingEdited
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.space12
                        anchors.rightMargin: Theme.space12
                        spacing: Theme.space8

                        Rectangle {
                            Layout.preferredWidth: 8
                            Layout.preferredHeight: 8
                            radius: 4
                            color: String(routineRow.modelData.categoryColor || "").length > 0 ? routineRow.modelData.categoryColor : Theme.border
                            opacity: routineRow.routineActive ? 1.0 : 0.45
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1

                            Text {
                                Layout.fillWidth: true
                                text: routineRow.modelData.title || ""
                                textFormat: Text.PlainText
                                color: routineRow.routineActive ? Theme.ink : Theme.inkMuted
                                font.pixelSize: Theme.fontMd
                                elide: Text.ElideRight
                            }

                            Text {
                                Layout.fillWidth: true
                                // 重复日不放在这里：它在右侧有自己的药丸按钮，写两遍只是占地方。
                                text: routineRow.modelData.categoryName && routineRow.modelData.categoryName.length > 0
                                      ? routineRow.modelData.categoryName
                                      : "不设置科目"
                                textFormat: Text.PlainText
                                color: routineRow.routineActive ? Theme.inkSoft : Theme.inkMuted
                                font.pixelSize: Theme.fontXs
                                elide: Text.ElideRight
                            }
                        }

                        // 重复日入口：七个点就是一周，点亮的就是会生成任务的那几天。
                        // 整条是**一个**按钮，不是七个开关——逐日直接切会绕过「至少留一天」的校验，
                        // 而且列表行里没有空间给七个可点目标。点开后在专门的弹窗里改。
                        //
                        // 点阵没有文字，所以「哪个点是周一」靠三条兜底：位置固定（左起周一）、
                        // 悬停出文字提示、读屏名称里带完整说法；编辑弹窗里则是带一二三四五六日标签的圆点。
                        Button {
                            id: weekdayStrip
                            objectName: "routineWeekdayStrip"

                            readonly property int weekdaysMask: Weekdays.normalize(routineRow.modelData.weekdays)

                            implicitWidth: 96
                            implicitHeight: Theme.controlHeightSm
                            Accessible.name: qsTr("重复：%1，点击修改").arg(Weekdays.text(weekdayStrip.weekdaysMask))
                            ToolTip.visible: weekdayStrip.hovered || weekdayStrip.visualFocus
                            ToolTip.text: weekdayStrip.Accessible.name
                            ToolTip.delay: 500
                            onClicked: root.editWeekdays(routineRow.modelData)

                            background: Rectangle {
                                radius: height / 2
                                color: weekdayStrip.hovered || weekdayStrip.pressed
                                    ? Theme.glassHover
                                    : Theme.glassHoverIdle

                                // 常态用同色零透明而不是 transparent：transparent 是黑基色，
                                // 过渡中间帧会闪一道灰（悬停过渡门禁会拦）。
                                Behavior on color {
                                    ColorAnimation {
                                        duration: Theme.reduceMotion ? 0 : 120
                                        easing.type: Easing.OutQuad
                                    }
                                }
                            }

                            contentItem: Item {
                                Row {
                                    anchors.centerIn: parent
                                    spacing: 3

                                    Repeater {
                                        model: 7

                                        delegate: Rectangle {
                                            id: dayMark

                                            // delegate 显式声明消费的模型角色（pragma ComponentBehavior: Bound）。
                                            required property int index

                                            readonly property bool lit: (weekdayStrip.weekdaysMask & (1 << dayMark.index)) !== 0

                                            objectName: "routineWeekdayMark" + dayMark.index
                                            width: 11
                                            height: 11
                                            radius: width / 2
                                            // 点亮用实心强调色，没选中的留一颗浅色底点——不能直接不画，
                                            // 否则七个位置塌成几颗孤点，就看不出「第几天」了。
                                            //
                                            // 这里用深一档的 accentStrong 而不是开关那档 accent：
                                            // 11px 的小圆点配 borderSubtle 的底点，accent 在暖纸底上两者差得太少，
                                            // 1:1 尺寸下要凑近才数得清（放大看没问题，正是这种尺寸差骗过眼睛）。
                                            color: dayMark.lit ? Theme.accentStrong : Theme.borderSubtle
                                            opacity: routineRow.routineActive ? 1.0 : 0.45
                                        }
                                    }
                                }
                            }
                        }

                        Switch {
                            id: activeSwitch

                            checked: routineRow.routineActive
                            // 不再在开关旁边写「启用/停用」：拨钮本身就是状态，
                            // 那两个字只是把每一行又撑宽一截。读屏仍能拿到 Accessible 名称和勾选态。
                            padding: 0
                            implicitWidth: 40
                            implicitHeight: 24
                            Accessible.name: qsTr("启用例行任务 %1").arg(String(routineRow.modelData.title || ""))
                            onToggled: {
                                // 列表项只负责把用户意图转交给服务层；刷新由服务信号或失败回滚触发。
                                root.setRoutineActive(Number(routineRow.modelData.id), checked)
                            }

                            // 自定义暖纸拨钮：开=accent、关=灰，白色滑块滑动；取代 Basic 默认难看的深色样式。
                            indicator: Rectangle {
                                implicitWidth: 40
                                implicitHeight: 22
                                radius: height / 2
                                x: 0
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

                            // 内容区留空：拨钮画在 indicator 里，这里再放文字只会和它抢位置。
                            contentItem: Item {}
                        }

                        // 编辑/删除去掉常驻外框：一行里本来就有色点、开关两处描边，
                        // 再加两个带框按钮，六行叠起来右侧就是一堵格子墙。悬停才出底。
                        Button {
                            id: editButton
                            objectName: "routineEditButton"

                            text: qsTr("编辑")
                            implicitWidth: 52
                            implicitHeight: Theme.controlHeightSm
                            Accessible.name: qsTr("编辑例行任务")
                            onClicked: root.beginEditing(routineRow.modelData)

                            background: Rectangle {
                                radius: Theme.radiusSm
                                // 常态用同色零透明而不是 transparent：transparent 是黑基色，
                                // 过渡中间帧会闪一道灰（悬停过渡门禁会拦）。
                                color: editButton.hovered || editButton.pressed
                                    ? Theme.glassHover
                                    : Theme.glassHoverIdle

                                Behavior on color {
                                    ColorAnimation {
                                        duration: Theme.reduceMotion ? 0 : 120
                                        easing.type: Easing.OutQuad
                                    }
                                }
                            }

                            contentItem: Text {
                                text: editButton.text
                                textFormat: Text.PlainText
                                color: editButton.hovered || editButton.pressed ? Theme.accentFillInk : Theme.inkSoft
                                font.pixelSize: Theme.fontSm
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }

                        Button {
                            id: deleteButton
                            objectName: "routineDeleteButton"

                            text: "删除"
                            implicitWidth: 52
                            implicitHeight: Theme.controlHeightSm
                            Accessible.name: qsTr("删除例行任务")
                            onClicked: root.deleteRoutine(Number(routineRow.modelData.id))

                            background: Rectangle {
                                radius: Theme.radiusSm
                                color: deleteButton.hovered || deleteButton.pressed
                                    ? Theme.glassHover
                                    : Theme.glassHoverIdle

                                Behavior on color {
                                    ColorAnimation {
                                        duration: Theme.reduceMotion ? 0 : 120
                                        easing.type: Easing.OutQuad
                                    }
                                }
                            }

                            // 删除是破坏性操作：常态收成中性字，悬停才变红并出淡红底，
                            // 既不在静止画面里抢眼，真要点的时候又能确认点的是它。
                            contentItem: Text {
                                text: deleteButton.text
                                textFormat: Text.PlainText
                                color: deleteButton.hovered || deleteButton.pressed ? Theme.dangerSoft : Theme.inkSoft
                                font.pixelSize: Theme.fontSm
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
                text: "把要重复做的任务加进来，选好星期后自动出现在今日清单。"
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
        }
    }
}
