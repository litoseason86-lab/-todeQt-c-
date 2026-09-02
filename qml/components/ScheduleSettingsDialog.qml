pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import ".."
import "../ScheduleWeeks.js" as ScheduleWeeks

// 课表设置：学期锚点、总周数、周末列显隐，以及节次预设的整表编辑。
// 节次改动在本地草稿里进行，点保存才整表写库——逐行即时写库会在中途失败时
// 留下半张节次表，而节次表是「按节次」版式的行定义，半张就等于版式坏掉。
Popup {
    id: root

    palette.text: Theme.inputInk
    palette.placeholderText: Theme.inputPlaceholderInk
    palette.highlight: Theme.inputSelection
    palette.highlightedText: Theme.inputSelectedInk
    palette.window: Theme.inputPopupSurface
    palette.base: Theme.controlSurface
    palette.button: Theme.controlSurface
    palette.buttonText: Theme.controlInk
    palette.windowText: Theme.controlInk

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(480, parent ? Math.max(300, parent.width - 64) : 480)
    height: Math.min(560, parent ? parent.height - 48 : 560)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    property var scheduleServiceRef: null
    property var settingsRef: null
    property string errorText: ""

    signal saved()

    function reload() {
        root.errorText = ""
        if (root.settingsRef) {
            semesterStartField.text = String(root.settingsRef.semesterStartDate || "")
            semesterWeeksField.text = String(root.settingsRef.semesterWeeks)
            weekendCheck.checked = Boolean(root.settingsRef.scheduleShowWeekend)
        }

        draftPeriods.clear()
        if (root.scheduleServiceRef) {
            var periods = root.scheduleServiceRef.getPeriods()
            for (var i = 0; i < periods.length; ++i) {
                draftPeriods.append({
                    startText: ScheduleWeeks.formatMinutes(periods[i].startMinutes),
                    endText: ScheduleWeeks.formatMinutes(periods[i].endMinutes)
                })
            }
        }
    }

    function openDialog() {
        root.reload()
        root.open()
    }

    function save() {
        root.errorText = ""

        // 学期起始日允许留空：未设置时课表页会引导用户先定锚点，
        // 而不是替他猜一个日期然后算出一堆看不懂的周次。
        var startText = semesterStartField.text.trim()
        if (startText.length > 0 && !ScheduleWeeks.parseSemesterStart(startText)) {
            root.errorText = "学期起始日格式应为 yyyy-MM-dd"
            semesterStartField.forceActiveFocus()
            return
        }

        var weeks = parseInt(semesterWeeksField.text, 10)
        if (isNaN(weeks) || weeks < 1 || weeks > 60) {
            root.errorText = "学期总周数必须在 1 到 60 之间"
            semesterWeeksField.forceActiveFocus()
            return
        }

        // 节次先整体解析并校验，再决定要不要写库。
        var periods = []
        for (var i = 0; i < draftPeriods.count; ++i) {
            var row = draftPeriods.get(i)
            var start = ScheduleWeeks.parseMinutes(row.startText)
            var end = ScheduleWeeks.parseMinutes(row.endText)
            if (start < 0 || end < 0) {
                root.errorText = "第 " + (i + 1) + " 行节次时间格式应为 HH:mm"
                return
            }
            if (end <= start) {
                root.errorText = "第 " + (i + 1) + " 行结束时间必须晚于开始时间"
                return
            }
            periods.push({ startMinutes: start, endMinutes: end })
        }
        if (periods.length === 0) {
            root.errorText = "至少需要保留一节课时"
            return
        }

        if (root.scheduleServiceRef && !root.scheduleServiceRef.setPeriods(periods)) {
            if (root.errorText.length === 0) {
                root.errorText = "节次保存失败，请重试"
            }
            return
        }

        if (root.settingsRef) {
            root.settingsRef.semesterStartDate = startText
            root.settingsRef.semesterWeeks = weeks
            root.settingsRef.scheduleShowWeekend = weekendCheck.checked
        }

        root.saved()
        root.close()
    }

    ListModel {
        id: draftPeriods
    }

    Connections {
        target: root.scheduleServiceRef
        ignoreUnknownSignals: true
        enabled: root.visible

        function onOperationFailed(message) {
            root.errorText = String(message || "操作失败")
        }
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"; from: 0.94; to: 1.0
                duration: Theme.reduceMotion ? 0 : 220; easing.type: Easing.OutCubic
            }
            OpacityAnimator {
                from: 0; to: 1
                duration: Theme.reduceMotion ? 0 : 220; easing.type: Easing.OutQuad
            }
        }
    }

    exit: Transition {
        OpacityAnimator {
            from: 1; to: 0
            duration: Theme.reduceMotion ? 0 : 180; easing.type: Easing.InQuad
        }
    }

    Overlay.modal: Rectangle {
        color: Theme.dialogScrim
        opacity: root.opened ? 1 : 0

        Behavior on opacity {
            OpacityAnimator {
                duration: Theme.reduceMotion ? 0 : 180; easing.type: Easing.InOutQuad
            }
        }
    }

    background: Rectangle {
        objectName: "dialogPanel"
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
                text: "课表设置"
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space4

            Label {
                text: "学期起始日"
                color: Theme.ink
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
            }

            Text {
                Layout.fillWidth: true
                text: "第 1 周所在的那一周；填任意一天即可，会自动对齐到该周周一。"
                textFormat: Text.PlainText
                color: Theme.inkMuted
                font.pixelSize: Theme.fontXs
                wrapMode: Text.WordWrap
            }

            SettingsField {
                id: semesterStartField

                objectName: "semesterStartField"
                placeholderText: "yyyy-MM-dd"
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space8

            Label {
                text: "学期总周数"
                color: Theme.ink
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
            }

            SettingsField {
                id: semesterWeeksField

                objectName: "semesterWeeksField"
                Layout.preferredWidth: 72
                Layout.fillWidth: false
                validator: IntValidator { bottom: 1; top: 60 }
                inputMethodHints: Qt.ImhDigitsOnly
            }

            Item { Layout.fillWidth: true }

            CheckBox {
                id: weekendCheck

                objectName: "scheduleWeekendCheck"
                text: "显示周末"

                indicator: Rectangle {
                    implicitWidth: 18
                    implicitHeight: 18
                    x: weekendCheck.leftPadding
                    y: Math.round((weekendCheck.height - height) / 2)
                    radius: Theme.radiusSm
                    color: weekendCheck.checked ? Theme.accentFill : Theme.surfaceRaised
                    border.color: weekendCheck.checked ? Theme.accent : Theme.border
                    border.width: weekendCheck.activeFocus ? 2 : 1

                    Text {
                        anchors.centerIn: parent
                        visible: weekendCheck.checked
                        text: "✓"
                        textFormat: Text.PlainText
                        font.pixelSize: Theme.fontSm
                        color: Theme.accentFillInk
                    }
                }

                contentItem: Text {
                    leftPadding: weekendCheck.indicator.width + Theme.space8
                    text: weekendCheck.text
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space8

            Label {
                text: "节次时间"
                color: Theme.ink
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
            }

            Text {
                Layout.fillWidth: true
                text: "保存时按开始时间自动排序编号"
                textFormat: Text.PlainText
                color: Theme.inkMuted
                font.pixelSize: Theme.fontXs
            }
        }

        ListView {
            id: periodList

            objectName: "schedulePeriodList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            clip: true
            spacing: Theme.space4
            model: draftPeriods

            ScrollBar.vertical: ScrollBar {
                id: periodScrollBar

                policy: ScrollBar.AsNeeded
                width: 8

                contentItem: Rectangle {
                    implicitWidth: 4
                    radius: Theme.radiusSm
                    color: periodScrollBar.pressed || periodScrollBar.hovered
                           ? Theme.accent : Theme.border
                }

                background: Rectangle { color: "transparent" }
            }

            delegate: RowLayout {
                id: periodRow

                required property int index
                required property string startText
                required property string endText

                width: ListView.view.width - Theme.space8
                spacing: Theme.space8

                Text {
                    Layout.preferredWidth: 44
                    text: "第 " + (periodRow.index + 1) + " 节"
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                }

                SettingsField {
                    Layout.preferredWidth: 80
                    Layout.fillWidth: false
                    text: periodRow.startText
                    placeholderText: "08:00"
                    onTextEdited: draftPeriods.setProperty(periodRow.index, "startText", text)
                }

                Text {
                    text: "至"
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                }

                SettingsField {
                    Layout.preferredWidth: 80
                    Layout.fillWidth: false
                    text: periodRow.endText
                    placeholderText: "08:45"
                    onTextEdited: draftPeriods.setProperty(periodRow.index, "endText", text)
                }

                Item { Layout.fillWidth: true }

                Button {
                    id: removePeriodButton

                    text: "×"
                    implicitWidth: 28
                    implicitHeight: 28

                    background: Rectangle {
                        color: removePeriodButton.hovered ? Theme.dangerSoft : "transparent"
                        border.color: removePeriodButton.hovered ? Theme.danger : Theme.border
                        border.width: 1
                        radius: Theme.radiusSm
                    }

                    contentItem: Text {
                        text: removePeriodButton.text
                        textFormat: Text.PlainText
                        color: removePeriodButton.hovered ? Theme.surface : Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    onClicked: draftPeriods.remove(periodRow.index)
                }
            }
        }

        Button {
            id: addPeriodButton

            objectName: "scheduleAddPeriodButton"
            Layout.leftMargin: Theme.space16
            text: "+ 添加一节"
            implicitWidth: 100
            implicitHeight: 32

            background: Rectangle {
                color: addPeriodButton.hovered ? Theme.glassHover : Theme.glassCard
                border.color: addPeriodButton.hovered ? Theme.accent : Theme.border
                border.width: 1
                radius: Theme.radiusMd
            }

            contentItem: Text {
                text: addPeriodButton.text
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }

            onClicked: {
                // 接在最后一节之后排一节 45 分钟的，比让用户从空白开始填要省事。
                var startMinutes = 8 * 60
                if (draftPeriods.count > 0) {
                    var last = draftPeriods.get(draftPeriods.count - 1)
                    var lastEnd = ScheduleWeeks.parseMinutes(last.endText)
                    if (lastEnd >= 0) {
                        startMinutes = Math.min(23 * 60, lastEnd + 10)
                    }
                }
                draftPeriods.append({
                    startText: ScheduleWeeks.formatMinutes(startMinutes),
                    endText: ScheduleWeeks.formatMinutes(Math.min(24 * 60, startMinutes + 45))
                })
            }
        }

        Label {
            objectName: "scheduleSettingsError"
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
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.bottomMargin: Theme.space16
            spacing: Theme.space8

            Item { Layout.fillWidth: true }

            Button {
                id: cancelButton

                text: "取消"
                implicitWidth: 76
                implicitHeight: 40

                background: Rectangle {
                    color: cancelButton.hovered ? Theme.glassHover : Theme.glassCard
                    border.color: cancelButton.hovered ? Theme.accent : Theme.border
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

                onClicked: root.close()
            }

            Button {
                id: saveButton

                objectName: "scheduleSettingsSaveButton"
                text: "保存"
                implicitWidth: 76
                implicitHeight: 40

                background: Rectangle {
                    color: saveButton.hovered ? Theme.accentFillStrong : Theme.accentFill
                    border.color: saveButton.hovered ? Theme.accentStrong : Theme.accent
                    border.width: 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: saveButton.text
                    textFormat: Text.PlainText
                    color: Theme.accentFillInk
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                onClicked: root.save()
            }
        }
    }

    component SettingsField: TextField {
        id: settingsField

        Layout.fillWidth: true
        implicitHeight: 36
        selectByMouse: true

        background: Rectangle {
            color: Theme.surfaceRaised
            border.color: settingsField.activeFocus ? Theme.accent : Theme.border
            border.width: settingsField.activeFocus ? 2 : 1
            radius: Theme.radiusMd

            Behavior on border.color {
                ColorAnimation { duration: Theme.reduceMotion ? 0 : 180; easing.type: Easing.OutQuad }
            }
        }
    }
}
