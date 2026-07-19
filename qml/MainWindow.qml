import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import "."
import "components"
import "views"

Item {
    id: root

    // 默认落地页为仪表盘：一屏看全今日概览，任务/专注一步可达。
    property string currentView: "dashboard"
    property string pendingView: "dashboard"
    // 淡入淡出期间只保留最后一次视图请求，避免动画队列堆积。
    property string queuedView: ""
    property bool isSwitching: false
    // 原生全屏、主内容显隐和沉浸覆盖层都从这一事实源派生，避免三处互相写状态。
    property bool focusImmersiveActive: false
    property int pendingDeleteTaskId: -1
    property string pendingDeleteTitle: ""
    property int deleteCommitDelayMs: 5000
    property var countdownServiceRef: typeof countdownService === "undefined" ? null : countdownService
    property var appSettingsRef: typeof appSettings === "undefined" ? null : appSettings
    property var focusTimerRef: typeof focusTimer === "undefined" ? null : focusTimer
    // 侧栏展开态：优先读设置；测试未注入 settings 时本地默认真。
    property bool sidebarVisible: root.appSettingsRef
                                  ? root.appSettingsRef.sidebarVisible
                                  : true
    // 侧栏展开宽度常量：动画与毛玻璃采样共用，避免三处写死数字漂移。
    readonly property int sidebarExpandedWidth: 208
    readonly property bool sidebarMotionReduced: root.appSettingsRef
                                                 ? root.appSettingsRef.reduceMotion
                                                 : false
    readonly property string windowTitleText: root.focusTimerRef
        ? root.windowTitleFor(root.focusTimerRef.hasActiveSession,
                              root.focusTimerRef.phase,
                              root.focusTimerRef.mode,
                              root.focusTimerRef.isRunning,
                              root.focusTimerRef.remainingSeconds,
                              root.focusTimerRef.elapsedSeconds)
        : "番茄Todo"

    function setSidebarVisible(visible) {
        if (root.appSettingsRef) {
            root.appSettingsRef.sidebarVisible = visible
        } else {
            root.sidebarVisible = visible
        }
    }

    function toggleSidebar() {
        root.setSidebarVisible(!root.sidebarVisible)
    }

    function switchToView(viewName) {
        if (root.currentView === viewName && !root.isSwitching) {
            return;
        }

        // 减少动效要求立即切页，并完整清掉淡入淡出的中间状态；
        // 该分支必须在 isSwitching 早退之前，才能接住动画中途切换开关的场景。
        if (root.appSettingsRef && root.appSettingsRef.reduceMotion) {
            viewFade.stop();
            root.currentView = viewName;
            root.pendingView = viewName;
            root.queuedView = "";
            root.isSwitching = false;
            stackLayout.opacity = 1.0;
            return;
        }

        if (root.isSwitching) {
            root.queuedView = viewName;
            return;
        }

        root.isSwitching = true;
        root.pendingView = viewName;
        root.queuedView = "";
        viewFade.restart();
    }

    function finishViewSwitch() {
        root.isSwitching = false;

        if (root.queuedView.length > 0 && root.queuedView !== root.currentView) {
            // 当前切换完全结束后，再启动下一次切换。
            var nextView = root.queuedView;
            root.queuedView = "";
            root.switchToView(nextView);
            return;
        }

        root.queuedView = "";
    }

    function viewIndex(viewName) {
        switch (viewName) {
        case "focus":
            return 1;
        case "week":
            return 2;
        case "month":
            return 3;
        case "stats":
            return 4;
        case "countdown":
            return 5;
        case "dashboard":
            // 仪表盘追加在栈尾，避免挪动既有视图索引影响测试与切页逻辑。
            return 6;
        case "today":
        default:
            return 0;
        }
    }

    function formatMinuteTime(seconds) {
        var safe = Math.max(0, Number(seconds || 0))
        var minutes = Math.floor(safe / 60)
        var secs = safe % 60
        return (minutes < 10 ? "0" : "") + minutes + ":" + (secs < 10 ? "0" : "") + secs
    }

    function formatClockTime(seconds) {
        var safe = Math.max(0, Number(seconds || 0))
        var hours = Math.floor(safe / 3600)
        var minutes = Math.floor((safe % 3600) / 60)
        var secs = safe % 60
        return (hours < 10 ? "0" : "") + hours + ":"
                + (minutes < 10 ? "0" : "") + minutes + ":"
                + (secs < 10 ? "0" : "") + secs
    }

    function windowTitleFor(hasActiveSession, phase, mode, isRunning, remainingSeconds, elapsedSeconds) {
        // 与侧栏一样显式传入 timer 字段，避免函数内部动态读取导致 tick 不能刷新标题。
        var active = hasActiveSession || phase !== 0
        if (!active) {
            return "番茄Todo"
        }
        var timeText = mode === 1 ? root.formatMinuteTime(remainingSeconds) : root.formatClockTime(elapsedSeconds)
        return (isRunning ? "" : "⏸ ") + timeText + " · 番茄Todo"
    }

    function showToast(message, actionText, actionCallback) {
        globalToast.show(message, actionText, actionCallback)
    }

    function requestDeleteTask(taskId, taskTitle) {
        // 单槽撤销：新删除到来时，上一条先真正落库，撤销窗口只保护最近一次操作。
        if (!root.commitPendingDelete()) {
            return false
        }

        root.pendingDeleteTaskId = taskId
        root.pendingDeleteTitle = String(taskTitle || "")
        deleteCommitTimer.interval = root.deleteCommitDelayMs
        deleteCommitTimer.restart()
        root.showToast("已删除「" + root.pendingDeleteTitle + "」", "撤销", function() {
            root.cancelPendingDelete()
        })
        return true
    }

    function commitPendingDelete() {
        if (root.pendingDeleteTaskId <= 0) {
            return true
        }

        deleteCommitTimer.stop()
        // 到这里才真正触库；撤销窗口内数据库没有被碰过，专注记录关联不会提前丢失。
        var deletedTitle = root.pendingDeleteTitle
        if (!taskManager.deleteTask(root.pendingDeleteTaskId)) {
            // 失败后立即解除隐藏，让任务重新出现；不能把数据库失败伪装成“已删除”。
            root.pendingDeleteTaskId = -1
            root.pendingDeleteTitle = ""
            root.showToast("删除「" + deletedTitle + "」失败，请重试")
            return false
        }
        root.pendingDeleteTaskId = -1
        root.pendingDeleteTitle = ""
        return true
    }

    function cancelPendingDelete() {
        deleteCommitTimer.stop()
        root.pendingDeleteTaskId = -1
        root.pendingDeleteTitle = ""
    }

    function startFocusForTask(taskId, taskTitle) {
        // 已有自由专注、番茄工作或休息阶段时，不启动第二个会话；直接带用户去专注页处理当前状态。
        if (root.focusTimerRef.hasActiveSession || root.focusTimerRef.phase !== 0) {
            focusView.syncToActiveTimer()
            root.showToast("已有专注进行中");
            root.switchToView("focus");
            return;
        }

        // MainWindow 只传递任务和上次模式；FocusView 进入对应待机态。
        // 真正创建计时会话必须等用户在专注页再次点击“开始专注”。
        var usePomodoro = root.appSettingsRef && root.appSettingsRef.lastMode === 1
        if (focusView.enterWithTask(taskId, taskTitle, usePomodoro)) {
            root.switchToView("focus");
        }
    }

    Component.onCompleted: {
        // 旧主题 id 只在启动时迁移写回一次，此后设置里存的都是新 id。
        if (root.appSettingsRef) {
            var migrated = Theme.migrateThemeId(root.appSettingsRef.backgroundTheme)
            if (migrated !== root.appSettingsRef.backgroundTheme) {
                root.appSettingsRef.backgroundTheme = migrated
            }
        }
    }

    // 壁纸主题决定令牌走日间/夜间版（只翻明暗，色相仍是暖纸）。
    Binding {
        target: Theme
        property: "activeThemeId"
        value: root.appSettingsRef
            ? Theme.migrateThemeId(root.appSettingsRef.backgroundTheme)
            : "warm"
    }

    // 减少透明度：关掉全局实时模糊，所有玻璃面切到不透明降级（省电/更清晰）。
    Binding {
        target: Theme
        property: "glassBlurAllowed"
        value: root.appSettingsRef ? !root.appSettingsRef.reduceTransparency : true
    }

    BackgroundWallpaper {
        id: wallpaperLayer
        objectName: "backgroundWallpaperLayer"

        anchors.fill: parent
        // 声明在最前 = 画在最底层；侧栏和主内容作为后声明兄弟自然叠在其上。
        themeId: root.appSettingsRef ? root.appSettingsRef.backgroundTheme : "warm"
    }

    // 侧栏毛玻璃底：宽度跟随展开动画，收起时收缩为 0，避免空白模糊带。
    Item {
        id: sidebarFrost
        objectName: "sidebarFrost"

        width: sidebarShell.width
        height: parent.height
        // 减少透明度时整棵实时采样树停止渲染，侧栏自身改用 glassSolidSidebar。
        visible: Theme.glassBlurAllowed && !root.focusImmersiveActive && width > 0.5
        opacity: Math.min(1, sidebarShell.width / root.sidebarExpandedWidth)

        Behavior on opacity {
            enabled: !root.sidebarMotionReduced
            NumberAnimation {
                duration: 280
                easing.type: Easing.OutCubic
            }
        }

        ShaderEffectSource {
            id: sidebarBackdropSource

            anchors.fill: parent
            visible: false
            live: Theme.glassBlurAllowed
            sourceItem: wallpaperLayer
            sourceRect: Qt.rect(0, 0, Math.max(1, width), height)
        }

        MultiEffect {
            anchors.fill: parent
            source: sidebarBackdropSource
            blurEnabled: true
            blur: 0.9
            blurMax: 48
        }
    }

    RowLayout {
        objectName: "mainContentRow"

        anchors.fill: parent
        spacing: 0
        visible: !root.focusImmersiveActive

        // 收起态预留通道：把手所在的 32px 归入布局，内容右移让位，
        // 「不重叠」成为布局事实；展开时通道归零。
        Item {
            objectName: "sidebarRevealGutter"

            Layout.preferredWidth: root.sidebarVisible ? 0 : 32
            Layout.fillHeight: true

            Behavior on Layout.preferredWidth {
                enabled: !root.sidebarMotionReduced
                NumberAnimation {
                    duration: 320
                    easing.type: Easing.OutCubic
                }
            }
        }

        // 侧栏壳：裁剪 + 宽度弹簧收起；内部 Sidebar 保持 208 宽，避免内容随宽度挤扁。
        Item {
            id: sidebarShell
            objectName: "sidebarShell"

            Layout.preferredWidth: width
            Layout.minimumWidth: width
            Layout.maximumWidth: width
            Layout.fillHeight: true
            width: root.sidebarVisible ? root.sidebarExpandedWidth : 0
            clip: true

            Behavior on width {
                enabled: !root.sidebarMotionReduced
                NumberAnimation {
                    duration: 320
                    // OutCubic 接近 AppKit 侧边栏收起的减速感。
                    easing.type: Easing.OutCubic
                }
            }

            Sidebar {
                id: sidebar
                objectName: "mainSidebar"

                width: root.sidebarExpandedWidth
                height: parent.height
                // 收起末段略淡出，展开先淡入，减少硬切。
                opacity: root.sidebarVisible ? 1 : 0
                currentView: root.currentView
                focusTimerRef: root.focusTimerRef

                Behavior on opacity {
                    enabled: !root.sidebarMotionReduced
                    NumberAnimation {
                        duration: 220
                        easing.type: Easing.OutCubic
                    }
                }

                onItemClicked: function (viewName) {
                    root.switchToView(viewName);
                }

                onSettingsRequested: settingsDialog.open()
                onCollapseRequested: root.setSidebarVisible(false)
            }
        }

        Rectangle {
            objectName: "mainContentDivider"

            Layout.preferredWidth: root.sidebarVisible ? 1 : 0
            Layout.fillHeight: true
            color: Theme.border
            opacity: root.sidebarVisible ? 0.8 : 0
            visible: width > 0

            Behavior on Layout.preferredWidth {
                enabled: !root.sidebarMotionReduced
                NumberAnimation {
                    duration: 280
                    easing.type: Easing.OutCubic
                }
            }

            Behavior on opacity {
                enabled: !root.sidebarMotionReduced
                NumberAnimation {
                    duration: 200
                    easing.type: Easing.OutCubic
                }
            }
        }

        Rectangle {
            objectName: "mainContentBackground"

            Layout.fillWidth: true
            Layout.fillHeight: true
            // 透明让壁纸透出；此 Rectangle 保留为 StackLayout 的布局宿主，不再承担底色。
            color: "transparent"

            StackLayout {
                id: stackLayout
                objectName: "mainViewStack"

                anchors.fill: parent
                currentIndex: root.viewIndex(root.currentView)

                TodayTaskView {
                    pageActive: root.currentView === "today"
                    categoryManagerRef: categoryManager
                    countdownServiceRef: root.countdownServiceRef
                    settingsRef: root.appSettingsRef
                    pendingDeleteTaskId: root.pendingDeleteTaskId

                    onStartFocus: function (taskId, taskTitle) {
                        root.startFocusForTask(taskId, taskTitle);
                    }

                    onCountdownRequested: root.switchToView("countdown")
                    onDeleteRequested: function(taskId, taskTitle) {
                        root.requestDeleteTask(taskId, taskTitle)
                    }
                }

                FocusView {
                    id: focusView
                    objectName: "focusViewPage"
                    timer: root.focusTimerRef
                    settings: root.appSettingsRef
                    pageActive: root.currentView === "focus"

                    onFocusEnded: {
                        // 先退出沉浸再切页，今日页不能留在无侧栏的原生全屏状态。
                        root.focusImmersiveActive = false;
                        root.switchToView("today");
                    }

                    onImmersiveRequested: root.focusImmersiveActive = true

                    onAutoAdvanced: function (phase) {
                        // 用户正盯着专注页时切换本身可见，不必再弹提示。
                        if (root.currentView !== "focus") {
                            root.showToast(phase === 1 ? "专注完成，已自动开始休息"
                                                       : "休息结束，已自动开始下一个番茄")
                        }
                    }
                }

                WeekPlanView {
                    pageActive: root.currentView === "week"
                    categoryManagerRef: categoryManager
                    pendingDeleteTaskId: root.pendingDeleteTaskId

                    onStartFocus: function (taskId, taskTitle) {
                        root.startFocusForTask(taskId, taskTitle);
                    }

                    onDeleteRequested: function(taskId, taskTitle) {
                        root.requestDeleteTask(taskId, taskTitle)
                    }
                }

                MonthGoalView {
                    pageActive: root.currentView === "month"
                    categoryManagerRef: categoryManager

                    onStartFocus: function (taskId, taskTitle) {
                        root.startFocusForTask(taskId, taskTitle);
                    }
                }

                StatisticsView {
                    pageActive: root.currentView === "stats"
                    categoryManagerRef: categoryManager
                }

                CountdownView {
                    countdownServiceRef: root.countdownServiceRef
                }

                DashboardView {
                    objectName: "dashboardViewPage"
                    pageActive: root.currentView === "dashboard"

                    categoryManagerRef: categoryManager
                    countdownServiceRef: root.countdownServiceRef
                    settingsRef: root.appSettingsRef
                    wallpaperRef: wallpaperLayer
                    pendingDeleteTaskId: root.pendingDeleteTaskId

                    onStartFocus: function (taskId, taskTitle) {
                        root.startFocusForTask(taskId, taskTitle);
                    }

                    onCountdownRequested: root.switchToView("countdown")
                    onFocusPageRequested: root.switchToView("focus")
                    onTodayPageRequested: root.switchToView("today")
                    onDeleteRequested: function(taskId, taskTitle) {
                        root.requestDeleteTask(taskId, taskTitle)
                    }
                }
            }

            SequentialAnimation {
                id: viewFade

                OpacityAnimator {
                    objectName: "viewFadeOut"
                    target: stackLayout
                    from: 1.0
                    to: 0.96
                    duration: 70
                    easing.type: Easing.OutQuad
                }

                ScriptAction {
                    // 在透明度最低时切换页面，隐藏 StackLayout 的硬切。
                    script: root.currentView = root.pendingView
                }

                OpacityAnimator {
                    objectName: "viewFadeIn"
                    target: stackLayout
                    from: 0.96
                    to: 1.0
                    duration: 70
                    easing.type: Easing.OutQuad
                }

                ScriptAction {
                    script: root.finishViewSwitch()
                }
            }
        }
    }

    // 侧栏收起后：左缘 32px 通道整条是感应区，箭头把手默认隐身，
    // 指针进入通道才淡入滑出（自动隐藏，界面静置时零噪音）。
    Item {
        id: sidebarRevealButton
        objectName: "sidebarRevealButton"

        // 沉浸专注时不出现；展开时关闭命中。
        visible: !root.focusImmersiveActive
        enabled: !root.sidebarVisible
        width: 32
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        x: 0
        z: 40

        // 整条通道感应：把手很小，若只在把手上感应会很难“找到”它。
        HoverHandler {
            id: sidebarRevealAreaHover
            enabled: sidebarRevealButton.enabled
        }

        Item {
            id: sidebarRevealHandle

            readonly property bool shown: sidebarRevealButton.enabled
                                          && sidebarRevealAreaHover.hovered

            width: 34
            height: 56
            // 隐身态缩在窗外，显形时滑出；半胶囊左圆角始终藏在窗外。
            x: shown ? -12 : -26
            anchors.verticalCenter: parent.verticalCenter
            opacity: shown ? 1 : 0

            Behavior on opacity {
                enabled: !root.sidebarMotionReduced
                NumberAnimation {
                    duration: 200
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on x {
                enabled: !root.sidebarMotionReduced
                NumberAnimation {
                    duration: 200
                    easing.type: Easing.OutCubic
                }
            }

            // 柔和落影：贴边控件需要轻微离面感，但不抢内容。
            layer.enabled: opacity > 0.01
            layer.effect: MultiEffect {
                autoPaddingEnabled: true
                shadowEnabled: true
                shadowColor: Theme.shadow
                shadowOpacity: 0.14
                shadowBlur: 0.35
                shadowHorizontalOffset: 0
                shadowVerticalOffset: 3
            }

            Rectangle {
                anchors.fill: parent
                // 半胶囊：左侧圆角落在窗外，命中区内只见右侧弧边。
                radius: height / 2
                color: sidebarRevealMouse.pressed
                       ? Theme.glassAccent
                       : (sidebarRevealMouse.containsMouse ? Theme.glassHover : Theme.glassCard)
                border.color: Theme.glassBorder
                border.width: 1

                Behavior on color {
                    enabled: !root.sidebarMotionReduced
                    ColorAnimation {
                        duration: 140
                        easing.type: Easing.OutCubic
                    }
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                anchors.rightMargin: 7
                text: "»"
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontXl
                font.weight: Font.Medium
                color: sidebarRevealMouse.containsMouse ? Theme.accentInk : Theme.inkSoft

                Behavior on color {
                    enabled: !root.sidebarMotionReduced
                    ColorAnimation {
                        duration: 140
                        easing.type: Easing.OutCubic
                    }
                }
            }

            MouseArea {
                id: sidebarRevealMouse

                anchors.fill: parent
                enabled: sidebarRevealButton.enabled
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setSidebarVisible(true)
            }
        }

        Accessible.role: Accessible.Button
        Accessible.name: "显示侧栏"
        Accessible.onPressAction: root.setSidebarVisible(true)
    }

    FocusImmersiveOverlay {
        id: focusImmersiveOverlay
        objectName: "focusImmersiveOverlay"

        anchors.fill: parent
        visible: root.focusImmersiveActive
        active: root.focusImmersiveActive
        focusViewRef: focusView
        timerRef: root.focusTimerRef
        settingsRef: root.appSettingsRef

        onExitRequested: root.focusImmersiveActive = false
    }

    Toast {
        id: globalToast

        z: 100
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.space32
    }

    Timer {
        id: deleteCommitTimer

        interval: 5000
        onTriggered: root.commitPendingDelete()
    }

    Connections {
        target: root.focusTimerRef
        ignoreUnknownSignals: true

        function onSessionDiscarded(duration) {
            root.showToast("本次专注不足 3 分钟，未计入记录")
        }

        function onTaskAutoCompleteFailed(taskId) {
            root.showToast("专注记录已保存，但任务自动完成失败，请手动检查")
        }
    }

    CategoryDialog {
        id: categoryDialog

        parent: root
        manager: categoryManager
    }

    RoutineDialog {
        id: routineDialog
        objectName: "routineDialogRoot"

        parent: root
        routineManagerRef: typeof routineManager === "undefined" ? null : routineManager
        categoryManagerRef: categoryManager
    }

    ExportDialog {
        id: exportDialog

        parent: root
        exportServiceRef: exportService
    }

    SettingsDialog {
        id: settingsDialog
        objectName: "settingsDialog"

        parent: root
        appSettingsRef: root.appSettingsRef

        onRoutineRequested: routineDialog.open()
        onCategoryRequested: categoryDialog.open()
        onExportRequested: exportDialog.open()
    }
}
