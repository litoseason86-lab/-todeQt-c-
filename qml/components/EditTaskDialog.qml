// 内联组件（DateChip）和 Overlay 里要引用外层 root，按 qmllint 建议显式绑定组件作用域。
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import ".."

// 任务编辑弹窗：标题、科目、日期快捷项。旧日期不在快捷项内时必须保留原值。
Popup {
    id: root

    property var categoryManagerRef: null
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

    signal taskEdited(int taskId, string title, int categoryId, var isoDate)

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(460, parent ? Math.max(300, parent.width - 64) : 460)
    height: panel.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    function isoWithOffset(offset) {
        var d = new Date();
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
        root.categoryOptions = options;
    }

    function openForTask(task) {
        root.errorText = "";
        root.editingTaskId = Number(task.id);
        titleField.text = String(task.title || "");
        root.originalIsoDate = root.normalizedIso(task.date);

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
        return root.dateOffsetSelection < 0 ? root.originalIsoDate : root.isoWithOffset(root.dateOffsetSelection);
    }

    function submit() {
        var title = titleField.text.trim();
        if (title.length === 0) {
            root.errorText = "任务内容不能为空";
            titleField.forceActiveFocus();
            return;
        }

        var categoryId = categoryCombo.currentIndex >= 0 && categoryCombo.currentIndex < root.categoryOptions.length ? Number(root.categoryOptions[categoryCombo.currentIndex].id || -1) : -1;
        root.taskEdited(root.editingTaskId, title, categoryId, root.resultIsoDate());
        root.close();
    }

    component DateChip: Button {
        id: chip

        property int offset: 0

        checkable: false
        checked: root.dateOffsetSelection === chip.offset
        implicitWidth: 72
        implicitHeight: 34

        onClicked: root.dateOffsetSelection = chip.offset

        background: Rectangle {
            color: chip.checked ? Theme.accent : (chip.hovered ? Theme.surface : Theme.surfaceRaised)
            border.color: chip.checked ? Theme.accentStrong : Theme.border
            border.width: 1
            radius: Theme.radiusMd
        }

        contentItem: Text {
            text: chip.text
            textFormat: Text.PlainText
            color: chip.checked ? Theme.surface : Theme.ink
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
                duration: 220
                easing.type: Easing.OutCubic
            }

            OpacityAnimator {
                from: 0
                to: 1
                duration: 220
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
                duration: 220
                easing.type: Easing.InQuad
            }

            OpacityAnimator {
                from: 1
                to: 0
                duration: 220
                easing.type: Easing.InQuad
            }
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
            implicitHeight: 44
            placeholderText: "任务内容"
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
            implicitHeight: 40
            model: root.categoryOptions
            textRole: "name"
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

            Text {
                objectName: "editOriginalDateText"
                visible: root.dateOffsetSelection < 0
                text: "保留 " + root.originalIsoDate
                textFormat: Text.PlainText
                color: Theme.inkMuted
                font.pixelSize: Theme.fontSm
            }

            Item {
                Layout.fillWidth: true
            }
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
                implicitHeight: 36

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
                implicitHeight: 36

                onClicked: root.submit()

                background: Rectangle {
                    color: confirmButton.hovered ? Theme.accentStrong : Theme.accent
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: confirmButton.text
                    textFormat: Text.PlainText
                    color: Theme.surface
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
