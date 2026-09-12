pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../.."

FocusScope {
    id: root

    objectName: "settingsAppearancePage"
    property var appSettingsRef: null
    property bool compact: false

    // 侧栏顺序的呈现名。这张表只回答「这个 id 叫什么」；顺序本身来自设置，
    // 出厂顺序的唯一定义处在 AppSettings::defaultSidebarOrder()。
    readonly property var sidebarEntryNames: ({
        "dashboard": "仪表盘",
        "today": "今日任务",
        "todayFocus": "今日专注",
        "focus": "专注计时",
        "schedule": "课表",
        "week": "本周计划",
        "month": "专注历史",
        "stats": "数据统计",
        "countdown": "目标倒计时",
        "goals": "目标",
        "knowledgeGaps": "知识缺口"
    })

    // 替身或旧配置可能给出本页没有名字的 id；直接显示 id 也好过整行空白，
    // 至少能看出是哪一条出了问题。
    // 只判 ref 非空不够：替身和旧版本设置对象都可能缺字段，
    // 直接把 undefined 赋给 bool 属性会留下运行时告警，绑定停在上一次的值。
    // 业务规则要求组件扛得住「ref 存在但缺字段」，这里统一归一化。
    function boolSetting(name, fallback) {
        if (!root.appSettingsRef || root.appSettingsRef[name] === undefined) {
            return fallback
        }
        return Boolean(root.appSettingsRef[name])
    }

    function entryLabel(id) {
        var name = root.sidebarEntryNames[id]
        return name === undefined ? String(id) : name
    }

    readonly property var sidebarOrder: root.appSettingsRef && root.appSettingsRef.sidebarOrder
                                        ? root.appSettingsRef.sidebarOrder : []

    // 由服务层判定，QML 不再抄一份默认顺序。替身缺这个属性时按「非默认」处理：
    // 让「恢复默认」点得动、由服务层兜底，比给一个永远灰着又说不清为什么的按钮好。
    readonly property bool orderIsDefault: Boolean(root.appSettingsRef
                                                   && root.appSettingsRef.sidebarOrderIsDefault)

    // 整份新顺序一次性提交，不做「和相邻项交换」那种就地改写：
    // sidebarOrder 是从设置读出来的副本，改它不会回写，只会让界面和存储悄悄分家。
    function moveEntry(from, to) {
        var order = root.sidebarOrder.slice()
        if (from < 0 || from >= order.length || to < 0 || to >= order.length || from === to) {
            return
        }
        var moved = order.splice(from, 1)[0]
        order.splice(to, 0, moved)
        if (root.appSettingsRef) {
            root.appSettingsRef.sidebarOrder = order
        }
    }

    // —— 拖动排序 ——
    // 2026-09-11 用户看过设计稿后选定「只留拖动，去掉 ↑↓」：行更干净，接受键盘无法调整顺序。
    //
    // 拖动期间完全不动模型，只记「谁在拖、要落在第几位」，松手才整份提交：
    // 中途改模型会让 Repeater 重建全部行，正在拖的那一行连同它的 DragHandler 一起被销毁。
    property string draggingEntryId: ""
    // 松手后的最终下标；-1 表示当前没有有效落点。
    property int dropTargetIndex: -1
    readonly property int draggingFromIndex: root.draggingEntryId.length > 0
                                             ? root.sidebarOrder.indexOf(root.draggingEntryId) : -1
    // 设置页自己不持有滚动区（ScrollView 在 SettingsDialog 里），拖动开始时沿父链找最近的 Flickable。
    property var dragScroller: null
    property real lastDragSceneY: 0

    // 指示线的 y（相对列表宿主）；-1 表示不画。
    // 往下拖落在目标行之后，往上拖落在目标行之前——与松手后的真实位置一致。
    readonly property real dropIndicatorY: {
        if (root.draggingFromIndex < 0 || root.dropTargetIndex < 0
                || root.dropTargetIndex === root.draggingFromIndex) {
            return -1
        }
        var targetRow = orderRepeater.itemAt(root.dropTargetIndex)
        if (!targetRow) {
            return -1
        }
        var slotY = root.dropTargetIndex > root.draggingFromIndex
                ? targetRow.y + targetRow.height + orderList.spacing / 2
                : targetRow.y - orderList.spacing / 2
        // 首行上方、末行下方各留 1px，2px 的线不越出宿主。
        return Math.max(1, Math.min(orderList.height - 1, slotY))
    }

    function findScrollFlickable() {
        var candidate = root.parent
        while (candidate) {
            // 沿父链按属性认 Flickable：这条链的静态类型只有 QQuickItem，滚动区的这三个属性
            // 只有运行时才看得到。就地压制这一处类型推导告警，不放宽整类检查。
            // qmllint disable missing-property
            if (candidate.contentY !== undefined && candidate.contentHeight !== undefined
                    && candidate.flickableDirection !== undefined) {
                return candidate
            }
            // qmllint enable missing-property
            candidate = candidate.parent
        }
        // 测试或预览里直接摆着页面时没有滚动区：不自动滚动，拖动本身照常工作。
        return null
    }

    // 落点按指针所在的行算。指针在列表之上或之下时夹到首行或末行：
    // 拖到列表顶端松手就是「放到第一个」，不能因为指针稍微出界就判成无效。
    function targetIndexAtSceneY(sceneY) {
        var count = orderRepeater.count
        if (count === 0) {
            return -1
        }
        var listY = orderList.mapFromItem(null, 0, sceneY).y
        for (var i = 0; i < count; ++i) {
            var row = orderRepeater.itemAt(i)
            if (row && listY < row.y + row.height + orderList.spacing / 2) {
                return i
            }
        }
        return count - 1
    }

    function beginDrag(entryId) {
        if (root.sidebarOrder.indexOf(entryId) < 0) {
            return
        }
        root.draggingEntryId = entryId
        root.dropTargetIndex = -1
        root.dragScroller = root.findScrollFlickable()
    }

    function updateDrag(entryId, sceneX, sceneY) {
        if (root.draggingEntryId !== entryId || root.draggingFromIndex < 0) {
            return
        }
        root.lastDragSceneY = sceneY
        root.dropTargetIndex = root.targetIndexAtSceneY(sceneY)
    }

    function finishDrag(entryId, cancelled) {
        if (root.draggingEntryId !== entryId) {
            return
        }
        var from = root.draggingFromIndex
        var target = root.dropTargetIndex
        root.draggingEntryId = ""
        root.dropTargetIndex = -1
        root.dragScroller = null
        if (cancelled === true || from < 0 || target < 0 || target === from) {
            return
        }
        root.moveEntry(from, target)
    }

    // 指针进入滚动区上下边缘 40px 时按贴边程度加速滚动，并用最后的指针位置重算落点：
    // 内容在动、指针没动，不重算的话指示线会停在旧位置。
    function autoScrollStep() {
        var flickable = root.dragScroller
        if (!flickable || root.draggingEntryId.length === 0) {
            return
        }
        var edge = 40
        var localY = flickable.mapFromItem(null, 0, root.lastDragSceneY).y
        var delta = 0
        if (localY < edge) {
            delta = -Math.ceil((edge - Math.max(0, localY)) / 4)
        } else if (localY > flickable.height - edge) {
            delta = Math.ceil((Math.min(flickable.height, localY) - (flickable.height - edge)) / 4)
        }
        if (delta === 0) {
            return
        }
        var maxY = Math.max(0, flickable.contentHeight - flickable.height)
        var nextY = Math.max(0, Math.min(maxY, flickable.contentY + delta))
        if (nextY === flickable.contentY) {
            return
        }
        flickable.contentY = nextY
        root.dropTargetIndex = root.targetIndexAtSceneY(root.lastDragSceneY)
    }

    implicitHeight: contentColumn.implicitHeight

    Timer {
        id: autoScrollTimer

        interval: 16
        repeat: true
        running: root.draggingEntryId.length > 0 && root.dragScroller !== null
        onTriggered: root.autoScrollStep()
    }

    ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space24

        SettingsSection {
            title: "背景主题"
            description: "选择背景时会立即预览并保存。深色主题会同步提高文字与控件对比度。"
            card: false

            GridLayout {
                Layout.fillWidth: true
                columns: root.compact ? 2 : 3
                columnSpacing: Theme.space8
                rowSpacing: Theme.space8

                Repeater {
                    id: themeRepeater

                    objectName: "settingsThemeRepeater"
                    model: Theme.themes

                    delegate: SettingsThemeChoice {
                        required property var modelData

                        Layout.fillWidth: true
                        appSettingsRef: root.appSettingsRef
                        themeId: modelData.id
                        themeName: modelData.name
                    }
                }
            }
        }

        SettingsSection {
            title: "显示"

            SettingsRow {
                label: "减少动效"
                caption: "关闭弹窗、开关与页面切换中的非必要动画"
                iconName: "spark"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsReduceMotionSwitch"
                    text: "减少动效"
                    persistedChecked: root.boolSetting("reduceMotion", false)
                    reduceMotion: persistedChecked
                    onChangeRequested: enabled => {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.reduceMotion = enabled
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            SettingsRow {
                label: "纤细计时字体"
                caption: "专注页使用更轻的数字字重"
                iconText: "Aa"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsSlimClockFontSwitch"
                    text: "纤细计时字体"
                    persistedChecked: root.boolSetting("slimClockFont", true)
                    reduceMotion: root.boolSetting("reduceMotion", false)
                    onChangeRequested: enabled => {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.slimClockFont = enabled
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            SettingsRow {
                label: "减少透明度"
                caption: "关闭毛玻璃，改用不透明面板，更清晰也更省电"
                iconName: "layers"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsReduceTransparencySwitch"
                    text: "减少透明度"
                    persistedChecked: root.boolSetting("reduceTransparency", false)
                    reduceMotion: root.boolSetting("reduceMotion", false)
                    onChangeRequested: enabled => {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.reduceTransparency = enabled
                        }
                    }
                }
            }
        }

        SettingsSection {
            title: "侧栏顺序"
            description: "拖动调整左侧入口的排列。「设置」固定在底部，不参与排序。"
            card: false

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.space8

                // 行列表与指示线叠在同一个宿主里：指示线不属于任何一行，
                // 放在列表同级上层，既不会被行的圆角裁掉，也不用每行复制一条线。
                Item {
                    id: orderListHost

                    Layout.fillWidth: true
                    implicitHeight: orderList.implicitHeight

                    ColumnLayout {
                        id: orderList

                        width: parent.width
                        spacing: Theme.space4

                        Repeater {
                            id: orderRepeater

                            objectName: "settingsSidebarOrderRepeater"
                            model: root.sidebarOrder

                            Rectangle {
                                id: orderRow

                                required property string modelData

                                objectName: "settingsSidebarOrderRow-" + orderRow.modelData
                                Layout.fillWidth: true
                                Layout.preferredHeight: Theme.controlHeightLg
                                radius: Theme.radiusMd
                                color: Theme.surfaceRaised
                                border.color: Theme.border
                                border.width: 1
                                // 拖动期间原位置变淡，和今日任务列表的拖动反馈一致。
                                opacity: root.draggingEntryId === orderRow.modelData ? 0.5 : 1
                                Accessible.role: Accessible.ListItem
                                Accessible.name: root.entryLabel(orderRow.modelData)

                                // 把手：六个点，提示「这一行可以拖」。整行都能按住拖，把手只是视觉提示。
                                Grid {
                                    x: Theme.space12
                                    anchors.verticalCenter: parent.verticalCenter
                                    columns: 2
                                    rowSpacing: 3
                                    columnSpacing: 3
                                    Accessible.ignored: true

                                    Repeater {
                                        model: 6

                                        Rectangle {
                                            width: 3
                                            height: 3
                                            radius: 1.5
                                            color: Theme.inkSoft
                                        }
                                    }
                                }

                                Text {
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.space12 + Theme.space16
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.space12
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.entryLabel(orderRow.modelData)
                                    textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontMd
                                    color: Theme.ink
                                    elide: Text.ElideRight
                                }

                                HoverHandler {
                                    cursorShape: root.draggingEntryId.length > 0 ? Qt.ClosedHandCursor
                                                                                 : Qt.OpenHandCursor
                                }

                                DragHandler {
                                    id: rowDrag

                                    // 行本身不跟着指针走：位置由松手后的整份新顺序决定，
                                    // 让行自己移动会和 ColumnLayout 的排版打架。
                                    target: null
                                    acceptedButtons: Qt.LeftButton
                                    dragThreshold: 6

                                    property bool wasCancelled: false

                                    onActiveChanged: {
                                        if (rowDrag.active) {
                                            rowDrag.wasCancelled = false
                                            root.beginDrag(orderRow.modelData)
                                            return
                                        }
                                        const entryId = orderRow.modelData
                                        // Qt 在不同取消路径上对 canceled 与 activeChanged 的发送先后没有稳定承诺，
                                        // 延后一轮再收口，确保 onCanceled 已写入真实终止原因（同 TaskItem）。
                                        Qt.callLater(function () {
                                            root.finishDrag(entryId, rowDrag ? rowDrag.wasCancelled : true)
                                        })
                                    }

                                    onCanceled: rowDrag.wasCancelled = true

                                    onCentroidChanged: {
                                        if (!rowDrag.active) {
                                            return
                                        }
                                        const scenePos = orderRow.mapToItem(null, rowDrag.centroid.position.x,
                                                                            rowDrag.centroid.position.y)
                                        root.updateDrag(orderRow.modelData, scenePos.x, scenePos.y)
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        objectName: "settingsSidebarDropIndicator"

                        x: 0
                        y: root.dropIndicatorY - height / 2
                        z: 2
                        width: parent.width
                        height: 2
                        radius: 1
                        color: Theme.accent
                        visible: root.dropIndicatorY >= 0
                        Accessible.ignored: true
                    }
                }

                Button {
                    id: resetOrderButton
                    objectName: "settingsSidebarOrderResetButton"

                    Layout.topMargin: Theme.space8
                    Layout.alignment: Qt.AlignRight
                    implicitHeight: Theme.controlHeightMd
                    implicitWidth: 124
                    text: "恢复默认顺序"
                    enabled: !root.orderIsDefault
                    onClicked: {
                        if (root.appSettingsRef
                                && typeof root.appSettingsRef.resetSidebarOrder === "function") {
                            root.appSettingsRef.resetSidebarOrder()
                        }
                    }

                    background: Rectangle {
                        radius: Theme.radiusMd
                        color: resetOrderButton.down ? Theme.surfaceSunken
                                                     : (resetOrderButton.hovered ? Theme.glassHover
                                                                                 : Theme.controlSurface)
                        border.color: Theme.border
                        border.width: 1
                        opacity: resetOrderButton.enabled ? 1 : 0.5
                    }

                    contentItem: Text {
                        text: resetOrderButton.text
                        textFormat: Text.PlainText
                        color: Theme.controlInk
                        font.pixelSize: Theme.fontMd
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }
}
