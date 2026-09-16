pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import ".."
import "../LogicalDay.js" as LogicalDay

Popup {
    id: root

    // 退出动画期间 Popup 仍可见，已结束的表单不能再次写库；重新打开才允许新提交。
    property bool submissionClosed: false
    onAboutToShow: root.submissionClosed = false
    onAboutToHide: root.submissionClosed = true

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

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(460, parent ? Math.max(280, parent.width - 64) : 460)
    height: panel.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

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

    property date selectedDate: {
        // 凌晨日界点前创建的任务仍属于前一逻辑日。
        // qmllint disable unqualified
        var hour = (typeof appSettings !== "undefined" && appSettings)
                ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayDate(hour, new Date())
    }
    // “今日”入口每次打开都要重算逻辑日；周计划入口不注入此函数，保留用户点选的日期。
    property var selectedDateProvider: null
    property string heading: "添加新任务"
    // 预计用时（分钟），0 表示未设置。上限读 TaskManager 常量，与服务端校验同源。
    property int estimatedMinutes: 0
    property var categoryManagerRef: null
    // 生产页面注入返回 bool 的提交函数；信号保留给独立组件和旧测试使用。
    property var taskSubmitter: null
    // 备注长度上限，与 TaskManager::kMaxNotesLength 同一口径；宿主从 taskManager.maxNotesLength 注入。
    // TextArea 没有 maximumLength，只能在提交时拦下——服务端超长会直接拒绝，不再截断。
    property int maxNotesLength: 2000
    property var categories: []
    // 下拉末尾「+ 新建科目…」那一项的编号。负数且不与 -1（不设置科目）相同，
    // 因此永远不会被误当成真实的 category_id 提交。
    readonly property int newCategorySentinelId: -2
    // 上一次选中的真实项的**科目编号**（-1 = 不设置科目）。哨兵被选中时用它把下拉退回去。
    // 记编号不记下标：下标会随科目增删、重排而指向别的科目，甚至正好指着哨兵本身；
    // 弹窗关掉再开时，上一次的位置也不属于这一次。
    property int lastRealCategoryId: -1
    // 第一个选项是特殊占位项，表示"不设置科目"，数据库里的 category_id 保持为空。
    property var categoryOptions: [
        {
            id: -1,
            name: "不设置科目",
            color: ""
        }
    ]

    signal taskAdded(string title, date date, var category, int estimatedMinutes, string notes)

    function resetFields() {
        titleField.text = "";
        categoryComboBox.currentIndex = root.categoryOptions.length > 0 ? 0 : -1;
        root.lastRealCategoryId = -1;
        root.estimatedMinutes = 0;
        notesField.text = "";
        estimateFields.reload();
        errorLabel.text = "";
    }

    function refreshCategories() {
        // 打开时刷新，保证科目管理里的改动不用重启就能显示。
        if (root.categoryManagerRef && root.categoryManagerRef.getAllCategories) {
            root.categories = root.categoryManagerRef.getAllCategories();
        } else {
            root.categories = [];
        }
        // 末尾那条是哨兵，不是科目：选中它表示「我要现在建一个」。
        // 建任务建到一半想起要分个新科目，此前得放下手里的事去开「设置 → 数据 → 科目管理」。
        root.categoryOptions = [
            {
                id: -1,
                name: "不设置科目",
                color: ""
            }
        ].concat(root.categories).concat([
            {
                id: root.newCategorySentinelId,
                name: "+ 新建科目…",
                color: ""
            }
        ]);
        if (categoryComboBox.currentIndex < 0 && root.categoryOptions.length > 0) {
            categoryComboBox.currentIndex = 0;
        }
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
        // 恢复点那个科目可能已经不在了：退回「不设置科目」，绝不停在哨兵上。
        if (!root.selectCategoryById(root.lastRealCategoryId)) {
            root.selectCategoryById(-1);
        }
        newCategoryPrompt.openPrompt();
    }

    function selectCategoryById(categoryId) {
        for (var i = 0; i < root.categoryOptions.length; ++i) {
            if (Number(root.categoryOptions[i].id) === Number(categoryId)
                    && Number(categoryId) !== root.newCategorySentinelId) {
                categoryComboBox.currentIndex = i;
                root.lastRealCategoryId = Number(categoryId);
                return true;
            }
        }
        return false;
    }

    // 每次打开把恢复点同步成这一次的初始选中，不继承上一次打开时记下的科目。
    function syncCategoryRestorePoint() {
        var index = categoryComboBox.currentIndex;
        var valid = index >= 0 && index < root.categoryOptions.length
                && Number(root.categoryOptions[index].id) !== root.newCategorySentinelId;
        if (!valid) {
            root.selectCategoryById(-1);
            return;
        }
        root.lastRealCategoryId = Number(root.categoryOptions[index].id);
    }

    property int continuousSavedCount: 0

    function submit(keepOpen) {
        if (root.submissionClosed)
            return false
        var title = titleField.text.trim();
        if (title.length === 0) {
            errorLabel.text = "任务标题不能为空";
            titleField.forceActiveFocus();
            return;
        }

        // 预计用时留空/越界时直接挡住，避免把 0 当成「没填」写进库。
        if (estimateFields.validationError.length > 0) {
            errorLabel.text = estimateFields.validationError;
            estimateFields.focusFirstField();
            return;
        }
        root.estimatedMinutes = estimateFields.enteredMinutes;

        // 超长备注当场拦下并指明是备注。服务端同样会拒绝，但那边只能换来一句笼统的「保存失败」。
        if (notesField.text.trim().length > root.maxNotesLength) {
            errorLabel.text = "备注太长了，请控制在 " + root.maxNotesLength + " 字以内（当前 "
                    + notesField.text.trim().length + " 字）";
            notesField.forceActiveFocus();
            return;
        }

        // 这里只传科目 id，由 TaskManager 写入数据库关联字段和兼容旧数据的文本字段。
        var categoryId = categoryComboBox.currentIndex >= 0 && categoryComboBox.currentIndex < root.categoryOptions.length ? Number(root.categoryOptions[categoryComboBox.currentIndex].id || -1) : -1;
        // 哨兵不是科目。正常路径下它选中后立刻被退回，这里是最后一道闸——
        // 万一哪条路径漏了退回，也不能把 -2 当成 category_id 写进库。
        if (categoryId === root.newCategorySentinelId) {
            categoryId = -1;
        }
        var succeeded = true;
        if (root.taskSubmitter) {
            // taskSubmitter 由宿主在运行时注入为函数，静态工具只能看到 var 属性。
            // qmllint disable use-proper-function
            succeeded = Boolean(root.taskSubmitter(title, root.selectedDate, categoryId, root.estimatedMinutes, notesField.text.trim()));
            // qmllint enable use-proper-function
        } else {
            root.taskAdded(title, root.selectedDate, categoryId, root.estimatedMinutes, notesField.text.trim());
        }
        if (!succeeded) {
            errorLabel.text = "保存失败，请检查数据库后重试";
            titleField.forceActiveFocus();
            return;
        }
        if (keepOpen === true) {
            // 连续录入只清空本条内容，保留日期、科目和预计用时，失败时不清草稿。
            titleField.text = ""
            notesField.text = ""
            root.continuousSavedCount += 1
            errorLabel.text = ""
            titleField.forceActiveFocus()
        } else {
            root.resetFields()
            root.close()
        }
    }

    // 弹窗开着时科目在别处变了：刷新下拉，按科目编号保住原选中；原科目被删了就回到「不设置科目」。
    // 下标会随增删、重排指向别的科目，所以先记编号再重建。
    function syncCategoriesWhileOpen() {
        var index = categoryComboBox.currentIndex;
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
            errorLabel.text = String(message || "科目加载失败")
        }
        // 门禁写在处理函数里，不用 enabled 绑定：信号是同步发出的，
        // enabled 的重算可能晚于它，会漏掉刚打开那一刻的变化。关着时不必刷，打开时本来就会刷。
        function onCategoriesChanged() {
            if (root.visible) {
                root.syncCategoriesWhileOpen()
            }
        }
    }

    Component.onCompleted: root.refreshCategories()

    onOpened: {
        if (root.selectedDateProvider) {
            // selectedDateProvider 由宿主在运行时注入为函数，静态工具只能看到 var 属性。
            // qmllint disable use-proper-function
            var refreshedDate = root.selectedDateProvider()
            // qmllint enable use-proper-function
            if (refreshedDate instanceof Date && !isNaN(refreshedDate.getTime())) {
                root.selectedDate = refreshedDate
            }
        }
        errorLabel.text = "";
        root.refreshCategories();
        root.syncCategoryRestorePoint();
        titleField.forceActiveFocus();
    }

    onClosed: { root.resetFields(); root.continuousSavedCount = 0 }

    background: Rectangle {
        id: panel
        objectName: "dialogPanel"

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
                text: root.heading + (root.continuousSavedCount > 0 ? qsTr(" · 已添加 %1 项").arg(root.continuousSavedCount) : "")
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
            }
        }

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space4
            text: "任务标题"
            color: Theme.ink
            font.pixelSize: Theme.fontLg
        }

        TextField {
            id: titleField
            objectName: "titleField"

            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            implicitHeight: Theme.controlHeightLg
            placeholderText: "输入任务内容..."
            // 与 TaskManager::kMaxTitleLength 保持一致；超长粘贴在输入端截断。
            maximumLength: 100
            selectByMouse: true

            background: Rectangle {
                objectName: "titleFieldBackground"
                color: Theme.surfaceRaised
                border.color: errorLabel.text.length > 0 ? Theme.dangerBorder : (titleField.activeFocus ? Theme.focusRing : Theme.border)
                border.width: errorLabel.text.length > 0 || titleField.activeFocus ? 2 : 1
                radius: Theme.radiusMd
                layer.enabled: titleField.activeFocus && errorLabel.text.length === 0
                layer.effect: MultiEffect {
                    autoPaddingEnabled: true
                    shadowEnabled: true
                    shadowColor: Theme.accent
                    shadowOpacity: 0.18
                    shadowBlur: 0.18
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: 0
                }

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.reduceMotion ? 0 : 180
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.color {
                    ColorAnimation {
                        duration: Theme.reduceMotion ? 0 : 180
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.width {
                    NumberAnimation {
                        duration: Theme.reduceMotion ? 0 : 180
                        easing.type: Easing.OutQuad
                    }
                }
            }

            onTextEdited: {
                if (text.trim().length > 0) {
                    errorLabel.text = "";
                }
            }

            Keys.onReturnPressed: root.submit()
            Keys.onEnterPressed: root.submit()
        }

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space4
            text: "科目分类（可选）"
            color: Theme.ink
            font.pixelSize: Theme.fontLg
        }

        ComboBox {
            id: categoryComboBox
            objectName: "categoryComboBox"

            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            implicitHeight: Theme.controlHeightLg
            // 统一左右内边距：左边让文字不贴框（无色点时也不顶边），右边给下拉箭头留位。
            leftPadding: Theme.space12
            rightPadding: 32
            model: root.categoryOptions
            textRole: "name"
            currentIndex: root.categoryOptions.length > 0 ? 0 : -1
            displayText: currentIndex >= 0 && currentIndex < root.categoryOptions.length ? root.categoryOptions[currentIndex].name : "选择科目"

            onActivated: function (index) { root.handleCategoryActivated(index) }

            background: Rectangle {
                objectName: "categoryComboBackground"
                color: categoryComboBox.down || categoryComboBox.pressed ? Theme.accentSoft : (categoryComboBox.hovered ? Theme.surfaceSunken : Theme.surfaceRaised)
                border.color: categoryComboBox.down || categoryComboBox.pressed ? Theme.accent : Theme.border
                border.width: categoryComboBox.down || categoryComboBox.pressed ? 2 : 1
                radius: Theme.radiusMd

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.reduceMotion ? 0 : 180
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.color {
                    ColorAnimation {
                        duration: Theme.reduceMotion ? 0 : 180
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.width {
                    NumberAnimation {
                        duration: Theme.reduceMotion ? 0 : 180
                        easing.type: Easing.OutQuad
                    }
                }
            }

            indicator: Text {
                x: categoryComboBox.width - width - 14
                y: Math.round((categoryComboBox.height - height) / 2)
                text: "▾"
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
                rotation: categoryComboBox.down ? 180 : 0
                transformOrigin: Item.Center

                Behavior on rotation {
                    NumberAnimation {
                        duration: Theme.reduceMotion ? 0 : 180
                        easing.type: Easing.OutQuad
                    }
                }
            }

            contentItem: RowLayout {
                spacing: Theme.space8

                Rectangle {
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    radius: 3
                    visible: categoryComboBox.currentIndex >= 0 && categoryComboBox.currentIndex < root.categoryOptions.length && String(root.categoryOptions[categoryComboBox.currentIndex].color || "").length > 0
                    color: visible ? root.categoryOptions[categoryComboBox.currentIndex].color : "transparent"
                }

                Text {
                    Layout.fillWidth: true
                    text: categoryComboBox.displayText
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontLg
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                }
            }

            delegate: ItemDelegate {
        // delegate 显式声明消费的模型角色（pragma ComponentBehavior: Bound）。
        required property var modelData

                id: categoryDelegate
                width: categoryComboBox.width

                contentItem: RowLayout {
                    spacing: Theme.space8

                    Rectangle {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        radius: 3
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

        Label {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space4
            text: "预计用时（可选）"
            color: Theme.ink
            font.pixelSize: Theme.fontLg
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space8

            DurationFieldPair {
                id: estimateFields

                objectName: "addEstimateFields"
                namePrefix: "addEstimate"
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
                text: estimateFields.enteredMinutes > 0 ? "" : "未设置"
                textFormat: Text.PlainText
                color: Theme.inkMuted
                font.pixelSize: Theme.fontSm
                verticalAlignment: Text.AlignVCenter
            }
        }


        Label {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space4
            text: "备注（可选）"
            color: Theme.ink
            font.pixelSize: Theme.fontLg
        }

        // 接近上限才出现的字数提示：平时不占视线，快写满时提前知道还剩多少。
        Label {
            objectName: "addNotesCounter"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            visible: notesField.text.length > root.maxNotesLength * 0.9
            text: notesField.text.length + " / " + root.maxNotesLength
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignRight
            color: notesField.text.length > root.maxNotesLength ? Theme.danger : Theme.inkSoft
            font.pixelSize: Theme.fontSm
        }

        // 「第九讲复习」过两天就想不起指的是哪几页。备注就是给这种上下文留的位置。
        ScrollView {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.preferredHeight: 64

            TextArea {
                id: notesField
                objectName: "addNotesField"

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
                    border.color: notesField.activeFocus ? Theme.focusRing : Theme.borderSubtle
                }
            }
        }

        Label {
            id: errorLabel
            objectName: "addTaskErrorLabel"

            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            color: Theme.danger
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space8
            Layout.bottomMargin: Theme.space16
            spacing: Theme.space8

            Item {
                Layout.fillWidth: true
            }

            Button {
                id: cancelButton
                objectName: "cancelButton"

                text: "取消"
                implicitWidth: 76
                implicitHeight: Theme.controlHeightLg

                background: Rectangle {
                    objectName: "cancelButtonBackground"
                    color: cancelButton.pressed ? Theme.glassHover : (cancelButton.hovered ? Theme.glassHover : Theme.glassCard)
                    border.color: cancelButton.hovered || cancelButton.pressed ? Theme.accent : Theme.border
                    border.width: 1
                    radius: Theme.radiusMd

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.reduceMotion ? 0 : 160
                            easing.type: Easing.OutQuad
                        }
                    }

                    Behavior on border.color {
                        ColorAnimation {
                            duration: Theme.reduceMotion ? 0 : 160
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                contentItem: Text {
                    objectName: "cancelButtonLabel"
                    text: cancelButton.text
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    scale: cancelButton.pressed ? 0.96 : 1.0
                    transformOrigin: Item.Center

                    Behavior on scale {
                        NumberAnimation {
                            duration: Theme.reduceMotion ? 0 : 90
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                onClicked: root.close()
            }

            Button {
                id: saveAndContinueButton
                objectName: "saveAndContinueButton"

                text: qsTr("保存并继续")
                implicitWidth: 108
                implicitHeight: Theme.controlHeightLg

                background: Rectangle {
                    objectName: "saveAndContinueButtonBackground"
                    color: saveAndContinueButton.pressed || saveAndContinueButton.hovered ? Theme.glassHover : Theme.glassCard
                    border.color: saveAndContinueButton.hovered || saveAndContinueButton.pressed ? Theme.accent : Theme.border
                    border.width: 1
                    radius: Theme.radiusMd

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.reduceMotion ? 0 : 160
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                contentItem: Text {
                    objectName: "saveAndContinueButtonLabel"
                    text: saveAndContinueButton.text
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                onClicked: root.submit(true)
            }

            Button {
                id: submitButton
                objectName: "submitButton"

                text: "添加"
                implicitWidth: 76
                implicitHeight: Theme.controlHeightLg

                background: Rectangle {
                    objectName: "submitButtonBackground"
                    color: submitButton.pressed ? Theme.accentFillStrong : (submitButton.hovered ? Theme.accentFillStrong : Theme.accentFill)
                    border.color: submitButton.hovered || submitButton.pressed ? Theme.accentStrong : Theme.accent
                    border.width: 1
                    radius: Theme.radiusMd

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.reduceMotion ? 0 : 160
                            easing.type: Easing.OutQuad
                        }
                    }

                    Behavior on border.color {
                        ColorAnimation {
                            duration: Theme.reduceMotion ? 0 : 160
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                contentItem: Text {
                    objectName: "submitButtonLabel"
                    text: submitButton.text
                    textFormat: Text.PlainText
                    color: Theme.accentFillInk
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    scale: submitButton.pressed ? 0.96 : 1.0
                    transformOrigin: Item.Center

                    Behavior on scale {
                        NumberAnimation {
                            duration: Theme.reduceMotion ? 0 : 90
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                onClicked: root.submit()
            }
        }
    }

    NewCategoryPrompt {
        id: newCategoryPrompt
        objectName: "addTaskNewCategoryPrompt"

        // 挂在对话框自身上并居中：它是这个对话框内部的一步，不是另一个页面级弹窗。
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
