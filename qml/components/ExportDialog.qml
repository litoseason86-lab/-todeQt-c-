import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import ".."
import "../LogicalDay.js" as LogicalDay

Popup {
    id: root

    property var exportServiceRef: null
    property date currentDate: new Date()
    property string statusText: ""
    property int exportCurrent: 0
    property int exportTotal: 0

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(500, parent ? Math.max(340, parent.width - 64) : 500)
    height: Math.min(520, parent ? Math.max(420, parent.height - 64) : 520)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 0.96
                to: 1
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

    onOpened: {
        setDateRangeThisMonth()
        root.statusText = ""
        root.exportCurrent = 0
        root.exportTotal = 0
    }

    Connections {
        target: root.exportServiceRef
        ignoreUnknownSignals: true

        function onExportCompleted(success, message) {
            root.statusText = success ? message : "错误：" + message
        }

        function onExportProgress(current, total) {
            root.exportCurrent = current
            root.exportTotal = total
        }
    }

    function logicalToday() {
        // qmllint disable unqualified
        var hour = (typeof appSettings !== "undefined" && appSettings)
                ? appSettings.dayStartHour : 4
        // qmllint enable unqualified
        return LogicalDay.todayDate(hour, new Date())
    }

    function mondayOf(value) {
        // JS 的 getDay() 周日为 0，这里转换成以周一为起点。
        var date = new Date(value)
        var day = date.getDay()
        var diff = day === 0 ? -6 : 1 - day
        date.setDate(date.getDate() + diff)
        return date
    }

    function setDateRangeThisWeek() {
        var today = logicalToday()
        startDateInput.text = Qt.formatDate(mondayOf(today), "yyyy-MM-dd")
        endDateInput.text = Qt.formatDate(today, "yyyy-MM-dd")
    }

    function setDateRangeThisMonth() {
        var today = logicalToday()
        startDateInput.text = Qt.formatDate(new Date(today.getFullYear(), today.getMonth(), 1), "yyyy-MM-dd")
        endDateInput.text = Qt.formatDate(today, "yyyy-MM-dd")
    }

    function setDateRangeLastMonth() {
        var today = logicalToday()
        startDateInput.text = Qt.formatDate(new Date(today.getFullYear(), today.getMonth() - 1, 1), "yyyy-MM-dd")
        endDateInput.text = Qt.formatDate(new Date(today.getFullYear(), today.getMonth(), 0), "yyyy-MM-dd")
    }

    function setDateRangeAll() {
        startDateInput.text = "2020-01-01"
        endDateInput.text = Qt.formatDate(logicalToday(), "yyyy-MM-dd")
    }

    function parsedDate(text) {
        var date = new Date(text)
        return isNaN(date.getTime()) ? null : date
    }

    function validateRange() {
        var start = parsedDate(startDateInput.text)
        var end = parsedDate(endDateInput.text)
        if (!start || !end) {
            root.statusText = "日期格式必须是 yyyy-MM-dd"
            return false
        }
        if (start > end) {
            root.statusText = "开始日期不能晚于结束日期"
            return false
        }
        return true
    }

    function performExport() {
        if (!root.exportServiceRef) {
            root.statusText = "导出服务不可用"
            return
        }
        if (!validateRange()) {
            return
        }

        root.statusText = ""
        root.exportCurrent = 0
        root.exportTotal = 0
        if (exportAllRadio.checked) {
            folderDialog.open()
        } else {
            fileDialog.exportType = exportTasksRadio.checked ? "tasks" : "focus_sessions"
            fileDialog.currentFile = root.exportServiceRef.generateFileName(
                        fileDialog.exportType,
                        startDateInput.text,
                        endDateInput.text)
            fileDialog.open()
        }
    }

    function localPath(urlValue) {
        // FileDialog 返回 URL，服务层需要真实本地路径。
        var value = String(urlValue)
        return value.startsWith("file://") ? decodeURIComponent(value.substring(7)) : value
    }

    background: Rectangle {
        implicitWidth: root.width
        implicitHeight: root.height
        radius: Theme.radiusMd
        color: Theme.glassDialog
        border.color: Theme.border
        border.width: 1
    }

    contentItem: ColumnLayout {
        width: root.width
        height: root.height
        spacing: Theme.space12

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 52
            radius: Theme.radiusMd
            color: Theme.surface

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Theme.space16
                text: "数据导出"
                font.pixelSize: Theme.fontXl
                font.bold: true
                color: Theme.ink
            }
        }

        GroupBox {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            title: "日期范围"

            ColumnLayout {
                anchors.fill: parent
                spacing: 10

                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.space8

                    Button { text: "本周"; onClicked: root.setDateRangeThisWeek() }
                    Button { text: "本月"; onClicked: root.setDateRangeThisMonth() }
                    Button { text: "上月"; onClicked: root.setDateRangeLastMonth() }
                    Button { text: "全部"; onClicked: root.setDateRangeAll() }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space8

                    Label { text: "开始"; color: Theme.ink }
                    TextField {
                        id: startDateInput
                        objectName: "startDateInput"
                        Layout.fillWidth: true
                        placeholderText: "yyyy-MM-dd"
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space8

                    Label { text: "结束"; color: Theme.ink }
                    TextField {
                        id: endDateInput
                        objectName: "endDateInput"
                        Layout.fillWidth: true
                        placeholderText: "yyyy-MM-dd"
                    }
                }
            }
        }

        GroupBox {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            title: "导出内容"

            ColumnLayout {
                anchors.fill: parent

                RadioButton {
                    id: exportAllRadio
                    text: "全部（任务 + 专注记录）"
                    checked: true
                }

                RadioButton {
                    id: exportTasksRadio
                    text: "仅任务"
                }

                RadioButton {
                    id: exportSessionsRadio
                    text: "仅专注记录"
                }
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            visible: root.statusText.length > 0
            text: root.statusText
            color: root.statusText.startsWith("错误") ? Theme.danger : Theme.ink
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
        }

        ProgressBar {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            visible: root.exportTotal > 0 && root.exportCurrent < root.exportTotal
            from: 0
            to: Math.max(1, root.exportTotal)
            value: root.exportCurrent
        }

        Item { Layout.fillHeight: true }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.bottomMargin: Theme.space16
            spacing: Theme.space8

            Button {
                text: "取消"
                Layout.fillWidth: true
                implicitHeight: 42
                onClicked: root.close()
            }

            Button {
                objectName: "exportButton"
                text: "导出"
                Layout.fillWidth: true
                implicitHeight: 42
                onClicked: root.performExport()
            }
        }
    }

    FileDialog {
        id: fileDialog
        fileMode: FileDialog.SaveFile
        nameFilters: ["CSV files (*.csv)"]
        property string exportType: "tasks"

        onAccepted: {
            var path = root.localPath(selectedFile)
            var ok = exportType === "tasks"
                    ? root.exportServiceRef.exportTasks(startDateInput.text, endDateInput.text, path)
                    : root.exportServiceRef.exportFocusSessions(startDateInput.text, endDateInput.text, path)
            if (!ok) {
                if (root.statusText.length === 0) {
                    root.statusText = "错误：导出失败，请检查文件路径权限"
                }
            }
        }
    }

    FolderDialog {
        id: folderDialog

        onAccepted: {
            var ok = root.exportServiceRef.exportAll(
                        startDateInput.text,
                        endDateInput.text,
                        root.localPath(selectedFolder))
            if (!ok) {
                if (root.statusText.length === 0) {
                    root.statusText = "错误：导出失败，请检查目录权限"
                }
            }
        }
    }
}
