pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../components"
import "../LogicalDay.js" as LogicalDay

Item {
    id: root

    property bool pageActive: false
    // qmllint disable unqualified
    property var goalServiceRef: typeof goalService === "undefined" ? null : goalService
    property var categoryManagerRef: typeof categoryManager === "undefined" ? null : categoryManager
    property var settingsRef: typeof appSettings === "undefined" ? null : appSettings
    property var logicalDayServiceRef: typeof logicalDayService === "undefined" ? null : logicalDayService
    // qmllint enable unqualified
    property date currentDateOverride
    property var goals: []
    property string filterMode: "active"
    property string fallbackViewMode: "list"
    property int openGoalId: -1
    property string errorText: ""
    property var detailGoal: ({})
    property var dailyCounts: []
    property date detailToday: new Date()
    property int detailYear: detailToday.getFullYear()
    property int detailMonth: detailToday.getMonth() + 1
    property bool deletingDetail: false
    property string deleteErrorText: ""
    readonly property bool detailOpen: root.openGoalId > 0
    readonly property string detailForecastText: Number(root.detailGoal.forecastDays || -1) > 0
                                                  ? qsTr("照此速度还需 %1 天")
                                                    .arg(Number(root.detailGoal.forecastDays))
                                                  : ""
    readonly property string viewMode: root.settingsRef
                                               ? String(root.settingsRef.goalViewMode || "list")
                                               : root.fallbackViewMode
    readonly property var filteredGoals: root.filterGoals(root.goals, root.filterMode)
    readonly property int goalsCount: root.filteredGoals.length

    signal goalOpened(int goalId)

    function filterGoals(source, mode) {
        var result = []
        var values = source || []
        for (var i = 0; i < values.length; ++i) {
            var achieved = Boolean(values[i].achieved)
            if (mode === "all" || (mode === "achieved" && achieved)
                    || (mode === "active" && !achieved))
                result.push(values[i])
        }
        return result
    }

    function currentDate() {
        const overrideDate = new Date(root.currentDateOverride)
        return isNaN(overrideDate.getTime()) ? new Date() : overrideDate
    }

    function logicalToday() {
        const configuredHour = root.settingsRef ? root.settingsRef.dayStartHour : undefined
        const dayStartHour = configuredHour === undefined || configuredHour === null
                ? 4 : Number(configuredHour)
        return LogicalDay.todayDate(dayStartHour, root.currentDate())
    }

    function syncDetailDateSnapshot() {
        root.detailToday = root.logicalToday()
        root.detailYear = root.detailToday.getFullYear()
        root.detailMonth = root.detailToday.getMonth() + 1
    }

    function refresh() {
        if (!root.goalServiceRef || !root.goalServiceRef.getGoals)
            return
        root.errorText = ""
        const loadedGoals = root.goalServiceRef.getGoals() || []
        // C++ 服务以“空数组 + 同步 operationFailed”报告查询失败。此时保留旧数据，
        // 不能把数据库故障伪装成“用户没有目标”，否则还会误导用户重复创建。
        if (root.errorText.length > 0)
            return
        root.goals = loadedGoals
        if (root.detailOpen)
            root.refreshDetail()
    }

    function setFilterIndex(index) {
        root.filterMode = index === 1 ? "achieved" : (index === 2 ? "all" : "active")
    }

    function setViewMode(mode) {
        var normalized = mode === "grid" ? "grid" : "list"
        if (root.settingsRef)
            root.settingsRef.goalViewMode = normalized
        else
            root.fallbackViewMode = normalized
    }

    function openCreateForm() {
        goalForm.openForAdd()
    }

    function openEditForm(goalId) {
        if (!root.goalServiceRef || !root.goalServiceRef.getGoal)
            return
        var goal = root.goalServiceRef.getGoal(goalId)
        if (goal && Number(goal.id || -1) > 0)
            goalForm.openForEdit(goal)
    }

    function activateGoal(goalId) {
        root.openGoal(goalId)
        root.goalOpened(goalId)
    }

    function openGoal(goalId) {
        var normalizedId = Number(goalId || -1)
        if (normalizedId <= 0)
            return false
        root.syncDetailDateSnapshot()
        root.openGoalId = normalizedId
        root.refreshDetail()
        return Number(root.detailGoal.id || -1) === normalizedId
    }

    function closeGoal() {
        root.openGoalId = -1
        root.detailGoal = ({})
        root.dailyCounts = []
    }

    function refreshDetail() {
        if (!root.detailOpen || !root.goalServiceRef || !root.goalServiceRef.getGoal)
            return
        root.errorText = ""
        var loaded = root.goalServiceRef.getGoal(root.openGoalId)
        if (!loaded || Number(loaded.id || -1) <= 0) {
            // getGoal 对“已删除”和“查询失败”都返回空 map，只有后者会同步发
            // operationFailed。数据库临时故障时保留详情页，不把用户踢回列表。
            if (root.errorText.length > 0)
                return
            root.errorText = qsTr("目标不存在或已被删除")
            root.closeGoal()
            return
        }
        root.detailGoal = loaded
        root.dailyCounts = root.goalServiceRef.getGoalDailyCounts
                ? root.goalServiceRef.getGoalDailyCounts(root.openGoalId,
                                                         root.detailYear, root.detailMonth) || []
                : []
    }

    function formatDate(value, pattern) {
        if (value instanceof Date && !isNaN(value.getTime()))
            return Qt.formatDate(value, pattern)
        var parsed = new Date(String(value || ""))
        return isNaN(parsed.getTime()) ? "" : Qt.formatDate(parsed, pattern)
    }

    function detailDateText() {
        var start = root.formatDate(root.detailGoal.startDate, "yyyy.M.d")
        var deadline = root.formatDate(root.detailGoal.deadline, "yyyy.M.d")
        var suffix = deadline.length > 0 ? qsTr("截止 %1").arg(deadline) : qsTr("长期目标")
        return start.length > 0 ? qsTr("开始 %1 · %2").arg(start).arg(suffix) : suffix
    }

    function requestDeleteDetail() {
        if (root.detailOpen) {
            root.deleteErrorText = ""
            deleteConfirm.open()
        }
    }

    function confirmDeleteDetail() {
        if (!root.detailOpen || !root.goalServiceRef || !root.goalServiceRef.deleteGoal)
            return false
        const goalId = root.openGoalId
        root.deleteErrorText = ""
        root.deletingDetail = true
        if (!root.goalServiceRef.deleteGoal(goalId)) {
            root.deletingDetail = false
            return false
        }
        deleteConfirm.close()
        root.closeGoal()
        root.deletingDetail = false
        root.refresh()
        return true
    }

    Component.onCompleted: {
        if (root.pageActive) {
            root.syncDetailDateSnapshot()
            root.refresh()
        }
    }
    onPageActiveChanged: {
        if (root.pageActive) {
            root.syncDetailDateSnapshot()
            root.refresh()
        }
    }

    Connections {
        target: root.goalServiceRef
        enabled: root.pageActive
        ignoreUnknownSignals: true

        function onGoalsChanged() {
            if (!root.deletingDetail)
                root.refresh()
        }
        function onOperationFailed(message) {
            const text = String(message || qsTr("目标数据加载失败"))
            if (root.deletingDetail)
                root.deleteErrorText = text
            else
                root.errorText = text
        }
    }

    Connections {
        target: root.logicalDayServiceRef
        ignoreUnknownSignals: true

        function onChanged() {
            if (root.pageActive) {
                root.syncDetailDateSnapshot()
                root.refresh()
            }
        }
    }

    ColumnLayout {
        visible: !root.detailOpen
        anchors.fill: parent
        anchors.leftMargin: Theme.space32
        anchors.rightMargin: Theme.space32
        anchors.topMargin: Theme.space24
        anchors.bottomMargin: Theme.space24
        spacing: Theme.space16

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space16

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.space4

                Text {
                    text: qsTr("目标")
                    color: Theme.inkStrong
                    font.pixelSize: Theme.fontXxl
                    font.weight: Font.Bold
                }

                Text {
                    Layout.fillWidth: true
                    text: qsTr("把长期投入折成 100 格，看得见才坚持得下去")
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                    elide: Text.ElideRight
                }
            }

            // 尺寸与倒计时页的「添加目标」保持一致（108×44），两页的主操作按钮同款。
            GoalActionButton {
                objectName: "newGoalButton"
                text: qsTr("新建")
                accentAction: true
                implicitWidth: 108
                implicitHeight: 44
                onClicked: root.openCreateForm()
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space12

            SegmentedSwitch {
                objectName: "goalFilterSwitch"
                segments: [qsTr("进行中"), qsTr("已达成"), qsTr("全部")]
                currentIndex: root.filterMode === "achieved" ? 1 : (root.filterMode === "all" ? 2 : 0)
                minSegmentWidth: 72
                reduceMotion: Theme.reduceMotion || (root.settingsRef && root.settingsRef.reduceMotion)
                solidFallback: !Theme.glassBlurAllowed
                onActivated: function(index) { root.setFilterIndex(index) }
            }

            Item { Layout.fillWidth: true }

            // 与相邻的分段控件同材质：都是浮在内容之上的控制条，
            // 走 GlassPanel 的凹槽轨道 + 棱边，避免同一行里两种玻璃质感。
            GlassPanel {
                color: Theme.glassBlurAllowed ? Theme.glassTrack : Theme.glassSolidTrack
                radius: Theme.radiusMd
                specularEnabled: false
                panelShadowEnabled: false
                Layout.preferredWidth: 82
                Layout.preferredHeight: 40

                Row {
                    anchors.fill: parent
                    anchors.margins: 3
                    spacing: 2

                    Repeater {
                        model: ["list", "grid"]

                        AbstractButton {
                            id: modeButton

                            required property int index
                            required property string modelData
                            readonly property bool selected: root.viewMode === modeButton.modelData

                            objectName: "goalViewMode-" + modeButton.modelData
                            width: 36
                            height: 32
                            focusPolicy: Qt.StrongFocus
                            Accessible.name: modeButton.modelData === "list" ? qsTr("列表视图") : qsTr("网格视图")
                            Accessible.checked: modeButton.selected
                            onClicked: root.setViewMode(modeButton.modelData)

                            // 选中态用暖色淡罩，不用 glassThumb——后者在浅色下接近纯白，
                            // 压在壁纸上就是一块突兀的白方框。淡罩与侧栏选中项是同一套语汇。
                            background: Item {
                                Rectangle {
                                    objectName: "goalViewModeFill-" + modeButton.modelData
                                    anchors.fill: parent
                                    visible: modeButton.selected
                                    color: Theme.accentFill
                                    radius: Theme.radiusSm
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    visible: modeButton.activeFocus
                                    color: Qt.rgba(0, 0, 0, 0)
                                    border.color: Theme.focusRing
                                    border.width: 2
                                    radius: Theme.radiusSm
                                }
                            }

                            contentItem: GlyphIcon {
                                name: modeButton.modelData
                                size: 18
                                // 选中格底是 accentFill 淡罩，字色必须用配套的 accentFillInk 才达对比。
                                color: modeButton.selected ? Theme.accentFillInk : Theme.inkSoft
                            }
                        }
                    }
                }
            }
        }

        Text {
            // 没有错误时整条让出布局位。ColumnLayout 会跳过不可见项，
            // 否则这里始终占着一行行高 + 一档 spacing，把列表整体往下推。
            visible: root.errorText.length > 0
            text: root.errorText
            color: Theme.danger
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
                id: listView
                objectName: "goalsListView"

                anchors.fill: parent
                visible: root.viewMode === "list" && root.goalsCount > 0
                clip: true
                spacing: Theme.space12
                model: root.filteredGoals
                reuseItems: true

                delegate: GoalCard {
                    required property var modelData

                    width: ListView.view.width
                    goal: modelData
                    onClicked: root.activateGoal(goalId)
                }
            }

            GridView {
                id: gridView
                objectName: "goalsGridView"

                readonly property int columnCount: width >= 560 ? 3 : (width >= 360 ? 2 : 1)

                anchors.fill: parent
                visible: root.viewMode === "grid" && root.goalsCount > 0
                clip: true
                cellWidth: Math.floor(width / columnCount)
                cellHeight: 170
                model: root.filteredGoals
                reuseItems: true

                delegate: GoalTile {
                    required property var modelData

                    width: Math.max(150, GridView.view.cellWidth - Theme.space12)
                    goal: modelData
                    onClicked: root.activateGoal(goalId)
                }
            }

            Column {
                objectName: "goalsEmptyState"
                readonly property bool shouldShow: root.goalsCount === 0
                                                   && root.errorText.length === 0
                anchors.centerIn: parent
                width: Math.min(360, parent.width)
                spacing: Theme.space12
                visible: shouldShow

                Text {
                    width: parent.width
                    text: root.filterMode === "active" ? qsTr("没有进行中的目标")
                                                       : qsTr("这里还没有目标")
                    color: Theme.inkStrong
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    width: parent.width
                    text: qsTr("先定义一个可计数的长期投入，再让每次专注推动它。")
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                }

                GoalActionButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("新建目标")
                    accentAction: true
                    implicitHeight: 44
                    onClicked: root.openCreateForm()
                }
            }
        }
    }

    ScrollView {
        id: detailScroll

        anchors.fill: parent
        visible: root.detailOpen
        clip: true
        contentWidth: availableWidth

        ColumnLayout {
            width: Math.max(detailScroll.availableWidth, 1)
            spacing: Theme.space16

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space32
                Layout.rightMargin: Theme.space32
                Layout.topMargin: Theme.space24
                spacing: Theme.space12

                GoalActionButton {
                    objectName: "goalDetailBackButton"
                    text: qsTr("返回")
                    implicitWidth: 76
                    implicitHeight: 44
                    onClicked: root.closeGoal()
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space4

                    Text {
                        Layout.fillWidth: true
                        text: String(root.detailGoal.title || qsTr("目标详情"))
                        textFormat: Text.PlainText
                        color: Theme.inkStrong
                        font.pixelSize: Theme.fontXxl
                        font.weight: Font.Bold
                        elide: Text.ElideRight
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.detailDateText()
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        elide: Text.ElideRight
                    }
                }
            }

            GlassPanel {
                Layout.fillWidth: true
                Layout.maximumWidth: 560
                Layout.alignment: Qt.AlignHCenter
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                implicitHeight: progressContent.implicitHeight + Theme.space32
                border.color: Theme.glassBorderContrast
                border.width: 1
                radius: Theme.radiusLg
                bottomRimEnabled: true
                panelShadowEnabled: false
                solidFallback: !Theme.glassBlurAllowed

                ColumnLayout {
                    id: progressContent
                    anchors.fill: parent
                    anchors.margins: Theme.space16
                    spacing: Theme.space8

                    RowLayout {
                        Layout.fillWidth: true

                        Text {
                            text: qsTr("总进度")
                            color: Theme.inkStrong
                            font.pixelSize: Theme.fontLg
                            font.weight: Font.DemiBold
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: qsTr("%1 / %2 番茄")
                                  .arg(Number(root.detailGoal.doneCount || 0))
                                  .arg(Number(root.detailGoal.targetPomodoros || 0))
                            color: Theme.ink
                            font.pixelSize: Theme.fontMd
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 10
                        radius: height / 2
                        color: Theme.surfaceSunken
                        clip: true

                        Rectangle {
                            width: parent.width * Math.max(0, Math.min(100,
                                   Number(root.detailGoal.percent || 0))) / 100
                            height: parent.height
                            radius: height / 2
                            color: Theme.accent
                        }
                    }
                }
            }

            GlassPanel {
                Layout.fillWidth: true
                Layout.maximumWidth: 560
                Layout.alignment: Qt.AlignHCenter
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                implicitHeight: gridContent.implicitHeight + Theme.space32
                border.color: Theme.glassBorderContrast
                border.width: 1
                radius: Theme.radiusLg
                bottomRimEnabled: true
                panelShadowEnabled: false
                solidFallback: !Theme.glassBlurAllowed

                ColumnLayout {
                    id: gridContent
                    anchors.fill: parent
                    anchors.margins: Theme.space16
                    spacing: Theme.space12

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: qsTr("100 格进度")
                            color: Theme.inkStrong
                            font.pixelSize: Theme.fontLg
                            font.weight: Font.DemiBold
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: Number(root.detailGoal.percent || 0) + "%"
                            color: Theme.accentInk
                            font.pixelSize: Theme.fontLg
                            font.family: Theme.fontFamilyData
                            font.weight: Font.Bold
                        }
                    }

                    Grid100 {
                        id: detailGrid
                        objectName: "goalDetailGrid100"
                        Layout.fillWidth: true
                        Layout.maximumWidth: 360
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredHeight: implicitHeight
                        doneCount: Number(root.detailGoal.doneCount || 0)
                        targetCount: Number(root.detailGoal.targetPomodoros || 0)
                    }

                    Text {
                        id: forecastLabel
                        objectName: "goalDetailForecastText"
                        Layout.fillWidth: true
                        Layout.preferredHeight: text.length > 0 ? implicitHeight : 0
                        text: root.detailForecastText
                        color: Theme.accentInk
                        font.pixelSize: Theme.fontMd
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }

            GlassPanel {
                Layout.fillWidth: true
                Layout.maximumWidth: 560
                Layout.alignment: Qt.AlignHCenter
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                implicitHeight: heatmapContent.implicitHeight + Theme.space32
                border.color: Theme.glassBorderContrast
                border.width: 1
                radius: Theme.radiusLg
                bottomRimEnabled: true
                panelShadowEnabled: false
                solidFallback: !Theme.glassBlurAllowed

                ColumnLayout {
                    id: heatmapContent
                    anchors.fill: parent
                    anchors.margins: Theme.space16
                    spacing: Theme.space12

                    Text {
                        text: qsTr("%1 年 %2 月投入").arg(root.detailYear).arg(root.detailMonth)
                        color: Theme.inkStrong
                        font.pixelSize: Theme.fontLg
                        font.weight: Font.DemiBold
                    }

                    GoalHeatmap {
                        objectName: "goalDetailHeatmap"
                        Layout.fillWidth: true
                        Layout.maximumWidth: 420
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredHeight: implicitHeight
                        year: root.detailYear
                        month: root.detailMonth
                        today: root.detailToday
                        dailyCounts: root.dailyCounts
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.maximumWidth: 560
                Layout.alignment: Qt.AlignHCenter
                Layout.leftMargin: Theme.space16
                Layout.rightMargin: Theme.space16
                Layout.bottomMargin: Theme.space24
                spacing: Theme.space8

                GoalActionButton {
                    text: qsTr("编辑")
                    implicitWidth: 88
                    implicitHeight: 44
                    onClicked: goalForm.openForEdit(root.detailGoal)
                }
                Item { Layout.fillWidth: true }
                GoalActionButton {
                    text: qsTr("删除")
                    dangerAction: true
                    implicitWidth: 88
                    implicitHeight: 44
                    onClicked: root.requestDeleteDetail()
                }
            }
        }
    }

    GoalFormDialog {
        id: goalForm
        objectName: "goalFormDialog"
        parent: root
        goalServiceRef: root.goalServiceRef
        categoryManagerRef: root.categoryManagerRef
        settingsRef: root.settingsRef
        currentDateOverride: root.currentDateOverride
    }

    Popup {
        id: deleteConfirm
        objectName: "goalDeleteConfirm"
        parent: root
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape
        width: Math.min(380, parent ? parent.width - Theme.space32 : 380)
        height: deleteColumn.implicitHeight + Theme.space32
        x: parent ? Math.round((parent.width - width) / 2) : 0
        y: parent ? Math.round((parent.height - height) / 2) : 0
        padding: Theme.space16
        Overlay.modal: Rectangle { color: Theme.modalScrim }
        background: Rectangle {
            color: Theme.glassBlurAllowed ? Theme.glassDialog : Theme.glassSolidCard
            border.color: Theme.glassBorder
            border.width: 1
            radius: Theme.radiusLg
        }
        contentItem: ColumnLayout {
            id: deleteColumn
            spacing: Theme.space12
            Text {
                Layout.fillWidth: true
                text: qsTr("删除“%1”？").arg(String(root.detailGoal.title || qsTr("该目标")))
                color: Theme.inkStrong
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                wrapMode: Text.WordWrap
            }
            Text {
                objectName: "goalDeleteError"
                Layout.fillWidth: true
                Layout.preferredHeight: text.length > 0 ? implicitHeight : 0
                text: root.deleteErrorText
                color: Theme.danger
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
            }
            Text {
                Layout.fillWidth: true
                text: qsTr("专注记录不会被删除，但这个目标及其里程碑状态无法恢复。")
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                GoalActionButton {
                    text: qsTr("取消")
                    implicitHeight: 44
                    onClicked: deleteConfirm.close()
                }
                GoalActionButton {
                    text: qsTr("确认删除")
                    dangerAction: true
                    implicitHeight: 44
                    onClicked: root.confirmDeleteDetail()
                }
            }
        }
    }

    component GoalActionButton: Button {
        id: actionButton

        property bool accentAction: false
        property bool dangerAction: false

        hoverEnabled: true
        background: Rectangle {
            color: actionButton.accentAction
                   ? (actionButton.down || actionButton.hovered
                      ? Theme.accentFillStrong : Theme.accentFill)
                   : (actionButton.down || actionButton.hovered
                      ? Theme.glassHover : Theme.glassCard)
            // 主操作（accentAction）与倒计时页的「添加目标」同款：纯淡罩、不描边、大圆角。
            // 次级和危险操作保留描边——它们叠在玻璃卡上，没有描边会糊进背景。
            border.color: actionButton.dangerAction ? Theme.dangerBorder : Theme.border
            border.width: actionButton.accentAction ? 0 : 1
            radius: actionButton.accentAction ? Theme.radiusLg : Theme.radiusMd
        }
        contentItem: Text {
            text: actionButton.text
            color: actionButton.dangerAction ? Theme.danger
                   : (actionButton.accentAction ? Theme.accentFillInk : Theme.ink)
            font.pixelSize: Theme.fontMd
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }
}
