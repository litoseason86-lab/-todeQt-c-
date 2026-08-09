pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."
import "../LogicalDay.js" as LogicalDay

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
    property var categories: []
    // 第一个选项是特殊占位项，表示"不设置科目"，数据库里的 category_id 保持为空。
    property var categoryOptions: [
        {
            id: -1,
            name: "不设置科目",
            color: ""
        }
    ]

    signal taskAdded(string title, date date, var category, int estimatedMinutes)

    function resetFields() {
        titleField.text = "";
        categoryComboBox.currentIndex = root.categoryOptions.length > 0 ? 0 : -1;
        root.estimatedMinutes = 0;
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
        root.categoryOptions = [
            {
                id: -1,
                name: "不设置科目",
                color: ""
            }
        ].concat(root.categories);
        if (categoryComboBox.currentIndex < 0 && root.categoryOptions.length > 0) {
            categoryComboBox.currentIndex = 0;
        }
    }

    function submit() {
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

        // 这里只传科目 id，由 TaskManager 写入数据库关联字段和兼容旧数据的文本字段。
        var categoryId = categoryComboBox.currentIndex >= 0 && categoryComboBox.currentIndex < root.categoryOptions.length ? Number(root.categoryOptions[categoryComboBox.currentIndex].id || -1) : -1;
        var succeeded = true;
        if (root.taskSubmitter) {
            succeeded = Boolean(root.taskSubmitter(title, root.selectedDate, categoryId, root.estimatedMinutes));
        } else {
            root.taskAdded(title, root.selectedDate, categoryId, root.estimatedMinutes);
        }
        if (!succeeded) {
            errorLabel.text = "保存失败，请检查数据库后重试";
            titleField.forceActiveFocus();
            return;
        }
        root.resetFields();
        root.close();
    }

    Connections {
        target: root.categoryManagerRef
        ignoreUnknownSignals: true

        function onOperationFailed(message) {
            errorLabel.text = String(message || "科目加载失败")
        }
    }

    Component.onCompleted: root.refreshCategories()

    onOpened: {
        if (root.selectedDateProvider) {
            var refreshedDate = root.selectedDateProvider()
            if (refreshedDate instanceof Date && !isNaN(refreshedDate.getTime())) {
                root.selectedDate = refreshedDate
            }
        }
        errorLabel.text = "";
        root.refreshCategories();
        titleField.forceActiveFocus();
    }

    onClosed: root.resetFields()

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
                text: root.heading
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
            implicitHeight: 44
            placeholderText: "输入任务内容..."
            // 与 TaskManager::kMaxTitleLength 保持一致；超长粘贴在输入端截断。
            maximumLength: 100
            selectByMouse: true

            background: Rectangle {
                objectName: "titleFieldBackground"
                color: Theme.surfaceRaised
                border.color: errorLabel.text.length > 0 ? Theme.dangerBorder : (titleField.activeFocus ? Theme.accent : Theme.border)
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
            implicitHeight: 44
            // 统一左右内边距：左边让文字不贴框（无色点时也不顶边），右边给下拉箭头留位。
            leftPadding: Theme.space12
            rightPadding: 32
            model: root.categoryOptions
            textRole: "name"
            currentIndex: root.categoryOptions.length > 0 ? 0 : -1
            displayText: currentIndex >= 0 && currentIndex < root.categoryOptions.length ? root.categoryOptions[currentIndex].name : "选择科目"

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
                implicitHeight: 44

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
                id: submitButton
                objectName: "submitButton"

                text: "添加"
                implicitWidth: 76
                implicitHeight: 44

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
}
