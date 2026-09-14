// 内联组件（DateChip）和 Overlay 里要引用外层 root，按 qmllint 建议显式绑定组件作用域。
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import ".."
import "../LogicalDay.js" as LogicalDay

// 任务编辑弹窗：标题、科目、日期快捷项。旧日期不在快捷项内时必须保留原值。
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

    property var categoryManagerRef: null
    // 下拉末尾「+ 新建科目…」那一项的编号。负数且不与 -1（不设置科目）相同，
    // 因此永远不会被误当成真实的 category_id 提交。
    readonly property int newCategorySentinelId: -2
    // 上一次选中的真实项。哨兵被选中时用它把下拉退回去。
    // 恢复点记科目编号（-1 = 不设置科目），不记下标——下标会随科目增删、重排而指向别的科目。
    property int lastRealCategoryId: -1
    property var categoryOptions: [
        {
            id: -1,
            name: "不设置科目",
            color: ""
        }
    ]
    property int editingTaskId: -1
    property string originalIsoDate: ""
    property int dateOffsetSelection: -1
    property string errorText: ""
    // 预计用时（分钟），0 表示未设置；openForTask 从任务数据回填。
    property int estimatedMinutes: 0
    // 生产页面注入返回 bool 的写入函数；保留信号用于独立组件和兼容测试。
    property var taskSubmitter: null

    signal taskEdited(int taskId, string title, int categoryId, var isoDate, int estimatedMinutes, string notes)

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(460, parent ? Math.max(300, parent.width - 64) : 460)
    height: panel.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    function isoWithOffset(offset) {
        // 快捷日期以逻辑今天为锚，避免凌晨编辑时“今天”跳到物理次日。
        // qmllint disable unqualified
        var hour = (typeof appSettings !== "undefined" && appSettings)
                ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        var d = LogicalDay.todayDate(hour, new Date());
        d.setDate(d.getDate() + offset);
        return Qt.formatDate(d, "yyyy-MM-dd");
    }

    function normalizedIso(value) {
        if (value instanceof Date) {
            return Qt.formatDate(value, "yyyy-MM-dd");
        }
        // QML modelData.date 可能是 Date、yyyy-MM-dd 或带时间字符串；编辑接口只需要日期段。
        return String(value || "").substring(0, 10);
    }

    function refreshCategories() {
        var options = [
            {
                id: -1,
                name: "不设置科目",
                color: ""
            }
        ];
        // 与 AddTaskDialog 一致走 getAllCategories——这是 CategoryManager 的真实接口名，
        // 写错方法名会被守卫静默吞掉，下拉只剩"不设置科目"。
        if (root.categoryManagerRef && root.categoryManagerRef.getAllCategories) {
            var actives = root.categoryManagerRef.getAllCategories();
            for (var i = 0; i < actives.length; i++) {
                options.push(actives[i]);
            }
        }
        // 末尾那条是哨兵，不是科目：选中它表示「我要现在建一个」。
        options.push({
            id: root.newCategorySentinelId,
            name: "+ 新建科目…",
            color: ""
        });
        root.categoryOptions = options;
    }

    // 选中哨兵后开新建框，并把下拉退回选之前那一项——
    // 弹框被取消时下拉不能停在「+ 新建科目…」上，那不是一个合法的科目归属。
    function handleCategoryActivated(index) {
        if (index < 0 || index >= root.categoryOptions.length) {
            return;
        }
        if (Number(root.categoryOptions[index].id) !== root.newCategorySentinelId) {
            root.lastRealCategoryId = Number(root.categoryOptions[index].id);
            return;
        }
        if (!root.selectCategoryById(root.lastRealCategoryId)) {
            root.selectCategoryById(-1);
        }
        newCategoryPrompt.openPrompt();
    }

    function selectCategoryById(categoryId) {
        for (var i = 0; i < root.categoryOptions.length; ++i) {
            if (Number(root.categoryOptions[i].id) === Number(categoryId)
                    && Number(categoryId) !== root.newCategorySentinelId) {
                categoryCombo.currentIndex = i;
                root.lastRealCategoryId = Number(categoryId);
                return true;
            }
        }
        return false;
    }

    // 弹窗开着时科目在别处变了：刷新下拉，按科目编号保住原选中；原科目被删了就回到「不设置科目」。
    // 下标会随增删、重排指向别的科目，所以先记编号再重建。
    function syncCategoriesWhileOpen() {
        var index = categoryCombo.currentIndex;
        var selectedId = index >= 0 && index < root.categoryOptions.length
                ? Number(root.categoryOptions[index].id) : -1;
        root.refreshCategories();
        if (!root.selectCategoryById(selectedId)) {
            root.selectCategoryById(-1);
        }
    }

    Connections {
        target: root.categoryManagerRef
        ignoreUnknownSignals: true

        function onOperationFailed(message) {
            root.errorText = String(message || "科目加载失败")
        }
        // 门禁写在处理函数里，不用 enabled 绑定：信号是同步发出的，
        // enabled 的重算可能晚于它。关着时不必刷，openForTask 本来就会刷。
        function onCategoriesChanged() {
            if (root.visible) {
                root.syncCategoriesWhileOpen()
            }
        }
    }

    function openForTask(task) {
        root.errorText = "";
        root.editingTaskId = Number(task.id);
        titleField.text = String(task.title || "");
        root.estimatedMinutes = Number(task.estimatedMinutes || 0);
        estimateFields.reload();
        notesField.text = String(task.notes || "");
        root.originalIsoDate = root.normalizedIso(task.date);
        customDate.text = root.originalIsoDate;

        root.refreshCategories();
        var targetId = Number(task.categoryId || -1);
        var index = 0;
        for (var i = 0; i < root.categoryOptions.length; i++) {
            if (Number(root.categoryOptions[i].id || -1) === targetId) {
                index = i;
                break;
            }
        }
        categoryCombo.currentIndex = index;
        root.lastRealCategoryId = Number(root.categoryOptions[index].id || -1);

        root.dateOffsetSelection = -1;
        for (var offset = 0; offset <= 2; offset++) {
            if (root.isoWithOffset(offset) === root.originalIsoDate) {
                root.dateOffsetSelection = offset;
                break;
            }
        }

        root.open();
        titleField.forceActiveFocus();
        titleField.selectAll();
    }

    function resultIsoDate() {
        return root.dateOffsetSelection < 0 ? customDate.text : root.isoWithOffset(root.dateOffsetSelection);
    }

    function submit() {
        var title = titleField.text.trim();
        if (title.length === 0) {
            root.errorText = "任务内容不能为空";
            titleField.forceActiveFocus();
            return;
        }

        // 预计用时留空/越界时挡住提交，否则会静默存成 0（=未设置）。
        if (estimateFields.validationError.length > 0) {
            root.errorText = estimateFields.validationError;
            estimateFields.focusFirstField();
            return;
        }
        root.estimatedMinutes = estimateFields.enteredMinutes;

        if (!LogicalDay.parseIsoDate(root.resultIsoDate())) {
            root.errorText = "日期无效，请输入 YYYY-MM-DD"
            return
        }

        var categoryId = categoryCombo.currentIndex >= 0 && categoryCombo.currentIndex < root.categoryOptions.length ? Number(root.categoryOptions[categoryCombo.currentIndex].id || -1) : -1;
        // 哨兵不是科目。正常路径下它选中后立刻被退回，这里是最后一道闸。
        if (categoryId === root.newCategorySentinelId) {
            categoryId = -1;
        }
        var succeeded = true
        if (root.taskSubmitter) {
            // taskSubmitter 由宿主在运行时注入为函数，静态工具只能看到 var 属性。
            // qmllint disable use-proper-function
            succeeded = Boolean(root.taskSubmitter(
                root.editingTaskId, title, categoryId,
                root.resultIsoDate(), root.estimatedMinutes, notesField.text.trim()))
            // qmllint enable use-proper-function
        } else {
            root.taskEdited(root.editingTaskId, title, categoryId,
                            root.resultIsoDate(), root.estimatedMinutes, notesField.text.trim())
        }
        if (!succeeded) {
            root.errorText = "保存失败，请检查数据库后重试"
            titleField.forceActiveFocus()
            titleField.selectAll()
            return
        }
        root.close();
    }

    component DateChip: Button {
        id: chip

        property int offset: 0

        checkable: false
        checked: root.dateOffsetSelection === chip.offset
        implicitWidth: 72
        implicitHeight: Theme.controlHeightMd

        onClicked: {
            root.dateOffsetSelection = chip.offset
            customDate.text = root.isoWithOffset(chip.offset)
        }

        background: Rectangle {
            color: chip.checked ? Theme.accentFill : (chip.hovered ? Theme.surface : Theme.surfaceRaised)
            border.color: chip.checked ? Theme.accentStrong : Theme.border
            border.width: 1
            radius: Theme.radiusMd
        }

        contentItem: Text {
            text: chip.text
            textFormat: Text.PlainText
            color: chip.checked ? Theme.accentFillInk : Theme.ink
            font.pixelSize: Theme.fontMd
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
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
        objectName: "editDialogPanel"

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
                text: "编辑任务"
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
            }
        }

        TextField {
            id: titleField

            objectName: "editTitleField"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            implicitHeight: Theme.controlHeightLg
            placeholderText: "任务内容"
            // 与 TaskManager::kMaxTitleLength 保持一致；超长粘贴在输入端截断。
            maximumLength: 100
            selectByMouse: true
            font.pixelSize: Theme.fontMd
            color: Theme.inkStrong

            background: Rectangle {
                color: Theme.surfaceRaised
                border.color: root.errorText.length > 0 ? Theme.dangerBorder : (titleField.activeFocus ? Theme.accent : Theme.border)
                border.width: root.errorText.length > 0 || titleField.activeFocus ? 2 : 1
                radius: Theme.radiusMd
            }

            onTextEdited: {
                if (text.trim().length > 0) {
                    root.errorText = "";
                }
            }

            Keys.onReturnPressed: root.submit()
            Keys.onEnterPressed: root.submit()
        }

        ComboBox {
            id: categoryCombo

            objectName: "editCategoryCombo"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            implicitHeight: Theme.controlHeightMd
            model: root.categoryOptions
            textRole: "name"

            onActivated: function (index) { root.handleCategoryActivated(index) }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space8

            Text {
                text: "预计用时"
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
            }

            DurationFieldPair {
                id: estimateFields

                objectName: "editEstimateFields"
                namePrefix: "editEstimate"
                accessiblePrefix: "预计用时"
                compact: true
                totalMinutes: root.estimatedMinutes
                // qmllint disable unqualified
                maximumMinutes: (typeof taskManager !== "undefined" && taskManager && taskManager.maxEstimatedMinutes)
                    ? taskManager.maxEstimatedMinutes : 24 * 60
                // qmllint enable unqualified
                onAccepted: root.submit()
            }

            Text {
                Layout.fillWidth: true
                visible: estimateFields.enteredMinutes === 0
                text: "未设置"
                textFormat: Text.PlainText
                color: Theme.inkMuted
                font.pixelSize: Theme.fontSm
                verticalAlignment: Text.AlignVCenter
            }
        }


        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            text: "备注"
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontMd
        }

        // 「第九讲复习」过两天就想不起指的是哪几页。备注就是给这种上下文留的位置。
        ScrollView {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.preferredHeight: 60

            TextArea {
                id: notesField
                objectName: "editNotesField"

                placeholderText: "页码、题号、要点……"
                placeholderTextColor: Theme.inkMuted
                color: Theme.inkStrong
                font.pixelSize: Theme.fontMd
                wrapMode: TextArea.Wrap
                selectByMouse: true

                background: Rectangle {
                    radius: Theme.radiusMd
                    color: Theme.surfaceSunken
                    border.width: notesField.activeFocus ? 2 : 1
                    border.color: notesField.activeFocus ? Theme.accent : Theme.borderSubtle
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space8

            Text {
                text: "日期"
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
            }

            DateChip {
                objectName: "editDateToday"
                text: "今天"
                offset: 0
            }

            DateChip {
                objectName: "editDateTomorrow"
                text: "明天"
                offset: 1
            }

            DateChip {
                objectName: "editDateDayAfter"
                text: "后天"
                offset: 2
            }

            Item {
                Layout.fillWidth: true
            }
        }

        // 任意日期输入排在快捷项下方：它是同一组「日期」控件，不能插在备注和标签之间。
        DateInput {
            id: customDate
            objectName: "editCustomDate"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            onEdited: root.dateOffsetSelection = -1
        }

        Text {
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

                text: "取消"
                implicitWidth: 80
                implicitHeight: Theme.controlHeightMd

                onClicked: root.close()

                background: Rectangle {
                    color: cancelButton.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
                    border.color: Theme.border
                    border.width: 1
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

                objectName: "editConfirmButton"
                text: "保存"
                implicitWidth: 80
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

    NewCategoryPrompt {
        id: newCategoryPrompt
        objectName: "editTaskNewCategoryPrompt"

        // Popup 渲染在窗口 overlay 层，不能把另一个 Popup 当父项；
        // 直接挂同一层并居中，才能盖在宿主对话框之上。
        parent: root.Overlay.overlay
        anchors.centerIn: parent
        categoryManagerRef: root.categoryManagerRef

        onCreated: function (categoryId, name) {
            // 先重建选项再选中：新科目此刻还不在 categoryOptions 里。
            root.refreshCategories();
            root.selectCategoryById(categoryId);
        }
    }
}
