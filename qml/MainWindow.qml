import QtQuick
import QtQuick.Layouts
import "."
import "components"
import "views"

Item {
    id: root

    property string currentView: "today"
    property string pendingView: "today"
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
    readonly property string windowTitleText: root.focusTimerRef
        ? root.windowTitleFor(root.focusTimerRef.hasActiveSession,
                              root.focusTimerRef.phase,
                              root.focusTimerRef.mode,
                              root.focusTimerRef.isRunning,
                              root.focusTimerRef.remainingSeconds,
                              root.focusTimerRef.elapsedSeconds)
        : "番茄Todo"

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
        root.commitPendingDelete()

        root.pendingDeleteTaskId = taskId
        root.pendingDeleteTitle = String(taskTitle || "")
        deleteCommitTimer.interval = root.deleteCommitDelayMs
        deleteCommitTimer.restart()
        root.showToast("已删除「" + root.pendingDeleteTitle + "」", "撤销", function() {
            root.cancelPendingDelete()
        })
    }

    function commitPendingDelete() {
        if (root.pendingDeleteTaskId <= 0) {
            return
        }

        deleteCommitTimer.stop()
        // 到这里才真正触库；撤销窗口内数据库没有被碰过，专注记录关联不会提前丢失。
        taskManager.deleteTask(root.pendingDeleteTaskId)
        root.pendingDeleteTaskId = -1
        root.pendingDeleteTitle = ""
    }

    function cancelPendingDelete() {
        deleteCommitTimer.stop()
        root.pendingDeleteTaskId = -1
        root.pendingDeleteTitle = ""
    }

    function startFocusForTask(taskId, taskTitle) {
        // 已有自由专注、番茄工作或休息阶段时，不启动第二个会话；直接带用户去专注页处理当前状态。
        if (root.focusTimerRef.hasActiveSession || root.focusTimerRef.phase !== 0) {
            root.showToast("已有专注进行中");
            root.switchToView("focus");
            return;
        }

        // 上次使用番茄：进入待机并预载任务，不能偷跑计时，用户还需要机会调整时长。
        if (root.appSettingsRef && root.appSettingsRef.lastMode === 1) {
            focusView.enterPomodoroWithTask(taskId, taskTitle);
            root.switchToView("focus");
            return;
        }

        if (root.focusTimerRef.startFocus(taskId, taskTitle)) {
            if (root.appSettingsRef) {
                root.appSettingsRef.lastMode = 0;
            }
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

    // 设置值（可能是旧 id）迁移后驱动全局色板。
    Binding {
        target: Theme
        property: "activeThemeId"
        value: root.appSettingsRef
            ? Theme.migrateThemeId(root.appSettingsRef.backgroundTheme)
            : "warm"
    }

    BackgroundWallpaper {
        objectName: "backgroundWallpaperLayer"

        anchors.fill: parent
        // 声明在最前 = 画在最底层；侧栏和主内容作为后声明兄弟自然叠在其上。
        themeId: root.appSettingsRef ? root.appSettingsRef.backgroundTheme : "warm"
    }

    RowLayout {
        objectName: "mainContentRow"

        anchors.fill: parent
        spacing: 0
        visible: !root.focusImmersiveActive

        Sidebar {
            Layout.preferredWidth: 208
            Layout.fillHeight: true
            currentView: root.currentView
            focusTimerRef: root.focusTimerRef

            onItemClicked: function (viewName) {
                root.switchToView(viewName);
            }

            onSettingsRequested: settingsDialog.open()
        }

        Rectangle {
            objectName: "mainContentDivider"

            Layout.preferredWidth: 1
            Layout.fillHeight: true
            color: Theme.border
            opacity: 0.8
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

                    onFocusEnded: {
                        // 先退出沉浸再切页，今日页不能留在无侧栏的原生全屏状态。
                        root.focusImmersiveActive = false;
                        root.switchToView("today");
                    }

                    onImmersiveRequested: root.focusImmersiveActive = true
                }

                WeekPlanView {
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
                    categoryManagerRef: categoryManager

                    onStartFocus: function (taskId, taskTitle) {
                        root.startFocusForTask(taskId, taskTitle);
                    }
                }

                StatisticsView {
                    categoryManagerRef: categoryManager
                }

                CountdownView {
                    countdownServiceRef: root.countdownServiceRef
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
