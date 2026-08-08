pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
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
    property string restoreInspectionPath: ""
    property var taskManagerRef: null
    property var categoryManagerRef: null
    property var routineManagerRef: null
    property var exportServiceRef: null
    property var statisticsServiceRef: null
    property var countdownServiceRef: null
    property var appSettingsRef: null
    property var focusTimerRef: null
    property var logicalDayServiceRef: null
    property var backupServiceRef: null
    property var goalServiceRef: null
    property var phaseSoundServiceRef: null
    property var shortcutRegistryRef: null
    // 「召回 / 隐藏主窗口」只能由 ApplicationWindow 落实；这里和菜单栏一样只发意图。
    signal windowToggleRequested()
    property var milestoneQueue: []
    property var suppressedMilestones: []
    property bool milestonePresentationScheduled: false
    readonly property var pendingMilestone: root.milestoneQueue.length > 0
                                            ? root.milestoneQueue[0] : null
    readonly property var suppressedMilestone: root.suppressedMilestones.length > 0
                                               ? root.suppressedMilestones[root.suppressedMilestones.length - 1]
                                               : null
    property var activeMilestoneDialog: null
    readonly property int rewardParticleCount: rewardParticles.particleCount
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

    // 弹窗是否已经把输入焦点接管走。Qt 的 Shortcut 不受弹窗遮挡影响：不挡住的话，
    // 用户正在新建任务对话框里打字时按 ⌘1，页面会在弹窗背后被切走（已实测复现）。
    //
    // 判据用「焦点是否落进 overlay」而不是「overlay 上有没有子项」：本应用的弹窗
    // 全部是 modal + focus，而目标热力图的悬停 ToolTip 同样挂在 overlay 上却不取焦，
    // 按子项判断会让鼠标划过热力图时快捷键整体失灵。
    readonly property bool overlayHoldsFocus: root.itemInsideOverlay(
        root.Window.window ? root.Window.window.activeFocusItem : null)

    // 焦点是否落在文本输入框上。用鸭子类型判断而不是类型判断：应用里的输入框
    // 既有 TextField 也有 TextArea，还包在 SettingsRow / TaskItem 等自定义组件里，
    // selectedText + inputMethodComposing 这两个属性是 TextInput/TextEdit 系独有的。
    // 注意「任务行内联重命名」和「每日目标编辑器」的输入框都不在弹窗里，
    // overlayHoldsFocus 盖不住它们，必须单独判。
    readonly property bool textInputFocused: root.isTextInputItem(
        root.Window.window ? root.Window.window.activeFocusItem : null)

    function isTextInputItem(item) {
        return !!item
                && typeof item.selectedText !== "undefined"
                && typeof item.inputMethodComposing !== "undefined"
    }

    function itemInsideOverlay(item) {
        const overlay = root.Overlay.overlay
        if (!overlay || !item) {
            return false
        }
        let current = item
        while (current) {
            if (current === overlay) {
                return true
            }
            current = current.parent
        }
        return false
    }

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
        if (Theme.reduceMotion || root.sidebarMotionReduced) {
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
        case "goals":
            // 目标页继续追加在栈尾，既有视图索引保持不变。
            return 7;
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
        // 提示条是单槽：任何新提示都会顶掉撤销条。撤销入口一旦不可见就立即提交删除，
        // 不让“看不见的删除倒计时”在背后继续走完 5 秒。
        if (root.pendingDeleteTaskId > 0) {
            root.commitPendingDelete()
        }
        globalToast.show(message, actionText, actionCallback)
    }

    function scheduleMilestonePresentation() {
        if (root.milestonePresentationScheduled || root.activeMilestoneDialog
                || root.milestoneQueue.length === 0) {
            return
        }

        root.milestonePresentationScheduled = true
        Qt.callLater(root.presentPendingMilestone)
    }

    function enqueueMilestone(goalId, title, percent) {
        // 同一个同步信号链可能连续跨过多个目标的阈值。数组每次复制后再赋值，确保 QML 发出属性变更。
        const queued = root.milestoneQueue.slice()
        queued.push({ goalId: goalId, title: title, percent: percent })
        root.milestoneQueue = queued
        root.scheduleMilestonePresentation()
    }

    function presentPendingMilestone() {
        root.milestonePresentationScheduled = false
        if (root.activeMilestoneDialog || root.milestoneQueue.length === 0)
            return

        const queued = root.milestoneQueue.slice()
        const milestone = queued.shift()
        root.milestoneQueue = queued

        // 声音不依赖当前页面，也不被沉浸层压制；它是专注完成后的第一层即时反馈。
        const soundAllowed = !root.appSettingsRef || Boolean(root.appSettingsRef.soundEnabled)
        if (soundAllowed && root.phaseSoundServiceRef) {
            if (Number(milestone.percent) === 100
                    && root.phaseSoundServiceRef.playGoalAchievedChime)
                root.phaseSoundServiceRef.playGoalAchievedChime()
            else if (root.phaseSoundServiceRef.playMilestoneChime)
                root.phaseSoundServiceRef.playMilestoneChime()
        }

        if (root.focusImmersiveActive) {
            // 沉浸时保留每个稀有事件，但不盖住全屏专注；退出后合并为一条补告知 Toast。
            const suppressed = root.suppressedMilestones.slice()
            suppressed.push(milestone)
            root.suppressedMilestones = suppressed
            root.scheduleMilestonePresentation()
            return
        }

        const goal = root.goalServiceRef && root.goalServiceRef.getGoal
                ? root.goalServiceRef.getGoal(Number(milestone.goalId)) : ({})
        const dialog = milestoneDialogComponent.createObject(root, {
            goalId: Number(milestone.goalId),
            goalTitle: String(milestone.title || ""),
            percent: Number(milestone.percent || 0),
            doneCount: Number(goal.doneCount || 0),
            targetCount: Number(goal.targetPomodoros || 0),
            achieved: Number(milestone.percent) === 100,
            reduceMotion: Theme.reduceMotion
                          || Boolean(root.appSettingsRef && root.appSettingsRef.reduceMotion)
        })
        if (!dialog) {
            root.showToast(String(milestone.title || "") + " 已达成 "
                           + Number(milestone.percent || 0) + "%")
            root.scheduleMilestonePresentation()
            return
        }
        root.activeMilestoneDialog = dialog
        dialog.closed.connect(function() { root.finalizeMilestoneDialog(dialog) })
        dialog.viewGoalRequested.connect(function() { root.openRewardGoal(dialog.goalId) })
        dialog.open()

        if (!Theme.reduceMotion
                && !(root.appSettingsRef && root.appSettingsRef.reduceMotion)) {
            Qt.callLater(function() {
                if (root.activeMilestoneDialog === dialog) {
                    // Popup 的视觉项会被 Controls 重挂到 overlay，因此用坐标映射取得
                    // 真实屏幕中心，不依赖 Popup 逻辑 parent 的 x/y 语义。
                    const center = dialog.contentItem.mapToItem(
                                rewardParticles,
                                dialog.contentItem.width / 2,
                                dialog.contentItem.height / 2)
                    rewardParticles.burst(center.x, center.y)
                }
            })
        }
    }

    function finalizeMilestoneDialog(dialog) {
        if (root.activeMilestoneDialog === dialog)
            root.activeMilestoneDialog = null
        dialog.destroy()
        root.scheduleMilestonePresentation()
    }

    function disposeActiveMilestoneDialog() {
        const dialog = root.activeMilestoneDialog
        if (!dialog)
            return
        // Popup.closed 在退出动画完成后统一销毁，避免提前 destroy 截断动画或漏接 Escape 关闭。
        dialog.close()
    }

    function openRewardGoal(goalId) {
        root.disposeActiveMilestoneDialog()
        root.switchToView("goals")
        // 切页由既有淡入淡出状态机管理；详情子状态可先写入，页面出现时已经是正确目标。
        Qt.callLater(function() { goalsView.openGoal(goalId) })
    }

    onFocusImmersiveActiveChanged: {
        if (!root.focusImmersiveActive && root.suppressedMilestones.length > 0) {
            const suppressed = root.suppressedMilestones.slice()
            root.suppressedMilestones = []
            const messages = []
            for (let i = 0; i < suppressed.length; ++i) {
                const milestone = suppressed[i]
                messages.push(String(milestone.title || "") + " "
                              + Number(milestone.percent || 0) + "%")
            }
            root.showToast("✦ " + messages.join("；"))
        }
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
        // 例行生成的当日实例：删除只影响今天，例行规则本身不受影响，撤销文案据此区分，
        // 让用户明白这不是删掉了整条例行规则。
        const isRoutine = root.taskManagerRef && root.taskManagerRef.isRoutineGeneratedTask
                ? root.taskManagerRef.isRoutineGeneratedTask(taskId) : false
        var deleteMessage = isRoutine
                ? "已删除今天的例行任务「" + root.pendingDeleteTitle + "」"
                : "已删除「" + root.pendingDeleteTitle + "」"
        // 直接走 globalToast：showToast 会把“已有待删任务”先提交，撤销条自己不能触发这条规则。
        globalToast.show(deleteMessage, "撤销", function() {
            root.cancelPendingDelete()
        })
        return true
    }

    // 完成撤销：完成已即时写库，撤销时把完成态翻回。5 秒撤销条内点击即可恢复完成前状态，
    // 任务 ID、排序、字段都不变（只改了 completed 一列）。
    function showCompletionUndoToast(taskId, taskTitle) {
        showToast("已完成「" + String(taskTitle || "") + "」", "撤销", function() {
            if (!root.taskManagerRef || !root.taskManagerRef.setTaskCompleted(taskId, false)) {
                root.showToast("撤销完成失败，请重试")
            }
        })
    }

    function commitPendingDelete() {
        if (root.pendingDeleteTaskId <= 0) {
            return true
        }

        deleteCommitTimer.stop()
        // 到这里才真正触库；撤销窗口内数据库没有被碰过，专注记录关联不会提前丢失。
        var deletedTitle = root.pendingDeleteTitle
        if (!root.taskManagerRef || !root.taskManagerRef.deleteTask(root.pendingDeleteTaskId)) {
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

    // —— 快捷键动作分发 ——
    // 应用内快捷键与全局热键最终都落到这里，按动作 id 分发。键位是什么、由谁触发，
    // 全部由 ShortcutRegistry 决定，这一层只关心「做什么」。
    function triggerShortcutAction(actionId) {
        switch (String(actionId)) {
        case "view.dashboard": root.switchToView("dashboard"); return
        case "view.today": root.switchToView("today"); return
        case "view.focus": root.switchToView("focus"); return
        case "view.week": root.switchToView("week"); return
        case "view.month": root.switchToView("month"); return
        case "view.stats": root.switchToView("stats"); return
        case "view.countdown": root.switchToView("countdown"); return
        case "view.goals": root.switchToView("goals"); return
        case "task.new": root.newTaskFromShortcut(); return
        case "window.toggleSidebar": root.toggleSidebar(); return
        case "window.settings": settingsDialog.open(); return
        case "window.shortcutHelp": root.openShortcutSettings(); return
        // 应用内与全局是两条独立的键位，但落到同一个动作上。
        case "focus.toggle":
        case "global.focusToggle": root.toggleFocusFromShortcut(); return
        case "focus.stop":
        case "global.focusStop": root.stopFocusFromShortcut(); return
        case "focus.immersive": root.toggleImmersiveFromShortcut(); return
        case "global.toggleWindow": root.windowToggleRequested(); return
        }
    }

    function newTaskFromShortcut() {
        // 新建任务对话框属于今日任务页；先切页再打开，避免在统计页这类无关页面上
        // 弹出一个没有上下文的输入框。切页可能带淡入淡出，用 callLater 等它落定。
        root.switchToView("today")
        Qt.callLater(function() { todayTaskView.openAddTaskDialog() })
    }

    function openShortcutSettings() {
        settingsDialog.open()
        settingsDialog.requestSection(settingsDialog.shortcutSectionIndex)
    }

    function toggleFocusFromShortcut() {
        if (!root.focusTimerRef) {
            return
        }
        if (root.focusTimerRef.hasActiveSession || root.focusTimerRef.phase !== 0) {
            focusView.togglePause()
            // togglePause 是同步的，这里读到的已经是切换之后的状态。
            root.showToast(root.focusTimerRef.isRunning ? "已继续专注" : "已暂停专注")
            return
        }

        // 没有会话时不能凭空开始：番茄和自由计时都要先绑定任务，交回专注页由用户选。
        root.switchToView("focus")
        root.showToast("请先选择要专注的任务")
    }

    function stopFocusFromShortcut() {
        if (!root.focusTimerRef) {
            return
        }
        if (!root.focusTimerRef.hasActiveSession && root.focusTimerRef.phase === 0) {
            root.showToast("当前没有进行中的专注")
            return
        }

        // 结束分番茄/自由两条路径，自由计时超时还要走确认弹窗——这些规则都在 FocusView 里，
        // 快捷键不复制一份，只切到专注页再调它的单点入口（确认弹窗要可见才有意义）。
        root.focusImmersiveActive = false
        root.switchToView("focus")
        Qt.callLater(function() {
            if (focusView.pomodoroModeSelected) {
                focusView.endPomodoro()
            } else {
                focusView.endFreeFocus()
            }
        })
    }

    function toggleImmersiveFromShortcut() {
        if (root.focusImmersiveActive) {
            root.focusImmersiveActive = false
            return
        }
        if (!focusView.immersiveAvailable) {
            root.showToast("沉浸模式只在番茄专注或休息进行中可用")
            return
        }
        root.switchToView("focus")
        root.focusImmersiveActive = true
    }

    function requestLongFreeFocusStop() {
        root.focusImmersiveActive = false
        root.switchToView("focus")
        // 弹窗状态属于 FocusView；菜单栏只传递“用户要结束”这一意图。
        Qt.callLater(focusView.endFreeFocus)
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
                duration: Theme.reduceMotion ? 0 : 280
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
                    duration: Theme.reduceMotion ? 0 : 320
                    easing.type: Easing.OutCubic
                }
            }
        }

        // 侧栏壳：裁剪 + 宽度弹簧收起；内部 Sidebar 保持 208 宽，避免内容随宽度挤扁。
        Item {
            id: sidebarShell
            objectName: "sidebarShell"

            Layout.preferredWidth: root.sidebarVisible ? root.sidebarExpandedWidth : 0
            Layout.minimumWidth: Layout.preferredWidth
            Layout.maximumWidth: Layout.preferredWidth
            Layout.fillHeight: true
            clip: true

            Behavior on Layout.preferredWidth {
                enabled: !root.sidebarMotionReduced
                NumberAnimation {
                    duration: Theme.reduceMotion ? 0 : 320
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
                        duration: Theme.reduceMotion ? 0 : 220
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
            // visible 不能只看布局产出的 width：Qt Quick Layouts 会排除不可见的项，
            // 而 width 初始为 0 → visible 为假 → 布局排除它 → width 永远上不去。
            // 这条分隔线因此一直没渲染出来过（既有用例只查颜色和 opacity，查不到）。
            visible: root.sidebarVisible || width > 0

            Behavior on Layout.preferredWidth {
                enabled: !root.sidebarMotionReduced
                NumberAnimation {
                    duration: Theme.reduceMotion ? 0 : 280
                    easing.type: Easing.OutCubic
                }
            }

            Behavior on opacity {
                enabled: !root.sidebarMotionReduced
                NumberAnimation {
                    duration: Theme.reduceMotion ? 0 : 200
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
                    id: todayTaskView
                    objectName: "todayTaskViewPage"
                    pageActive: root.currentView === "today"
                    categoryManagerRef: root.categoryManagerRef
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
                    onTaskCompletionUndoable: function(taskId, title) {
                        root.showCompletionUndoToast(taskId, title)
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
                    categoryManagerRef: root.categoryManagerRef
                    pendingDeleteTaskId: root.pendingDeleteTaskId

                    onStartFocus: function (taskId, taskTitle) {
                        root.startFocusForTask(taskId, taskTitle);
                    }

                    onDeleteRequested: function(taskId, taskTitle) {
                        root.requestDeleteTask(taskId, taskTitle)
                    }
                    onTaskCompletionUndoable: function(taskId, title) {
                        root.showCompletionUndoToast(taskId, title)
                    }
                }

                MonthGoalView {
                    pageActive: root.currentView === "month"
                    categoryManagerRef: root.categoryManagerRef

                    onStartFocus: function (taskId, taskTitle) {
                        root.startFocusForTask(taskId, taskTitle);
                    }
                }

                StatisticsView {
                    pageActive: root.currentView === "stats"
                    taskManagerRef: root.taskManagerRef
                    statisticsServiceRef: root.statisticsServiceRef
                    focusTimerRef: root.focusTimerRef
                    logicalDayServiceRef: root.logicalDayServiceRef
                    appSettingsRef: root.appSettingsRef
                    categoryManagerRef: root.categoryManagerRef
                }

                CountdownView {
                    countdownServiceRef: root.countdownServiceRef
                }

                DashboardView {
                    objectName: "dashboardViewPage"
                    pageActive: root.currentView === "dashboard"

                    taskManagerRef: root.taskManagerRef
                    statisticsServiceRef: root.statisticsServiceRef
                    routineManagerRef: root.routineManagerRef
                    focusTimerRef: root.focusTimerRef
                    categoryManagerRef: root.categoryManagerRef
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
                    onTaskCompletionUndoable: function(taskId, title) {
                        root.showCompletionUndoToast(taskId, title)
                    }
                }

                GoalsView {
                    id: goalsView
                    objectName: "goalsViewPage"
                    pageActive: root.currentView === "goals"
                    goalServiceRef: root.goalServiceRef
                    categoryManagerRef: root.categoryManagerRef
                    settingsRef: root.appSettingsRef
                }
            }

            SequentialAnimation {
                id: viewFade

                OpacityAnimator {
                    objectName: "viewFadeOut"
                    target: stackLayout
                    from: 1.0
                    to: 0.96
                    duration: Theme.reduceMotion ? 0 : 70
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
                    duration: Theme.reduceMotion ? 0 : 70
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
                    duration: Theme.reduceMotion ? 0 : 200
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on x {
                enabled: !root.sidebarMotionReduced
                NumberAnimation {
                    duration: Theme.reduceMotion ? 0 : 200
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
                        duration: Theme.reduceMotion ? 0 : 140
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
                        duration: Theme.reduceMotion ? 0 : 140
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

    CompletionParticles {
        id: rewardParticles
        objectName: "goalRewardParticles"
        // Popup 渲染在窗口 overlay 层，该层整体高于 contentItem；MainWindow 内部
        // 的 z 值再高也跨不过这个边界，所以奖励粒子必须直接挂在同一 overlay。
        parent: root.Overlay.overlay
        anchors.fill: parent
        z: 110
    }

    Component {
        id: milestoneDialogComponent

        MilestoneDialog {
            parent: root
        }
    }

    AppShortcuts {
        id: appShortcuts
        objectName: "appShortcuts"

        registryRef: root.shortcutRegistryRef
        // 两种情况必须整体让路：设置页正在录制新键位（否则录不到已被占用的组合），
        // 以及任何弹窗已经接管输入焦点（否则会在弹窗背后偷偷切页/开始专注）。
        suspended: settingsDialog.recordingShortcut || root.overlayHoldsFocus
        textInputFocused: root.textInputFocused

        onActionTriggered: function (actionId) {
            root.triggerShortcutAction(actionId)
        }
    }

    Connections {
        // 全局热键被系统拒绝（多半是被别的应用占用）时给一句可执行的提示；
        // 设置页里那一行也会同时标成「未生效」。
        target: root.shortcutRegistryRef
        ignoreUnknownSignals: true

        function onGlobalRegistrationFailed(actionId, title) {
            root.showToast("全局快捷键「" + String(title) + "」未能生效，可能已被其他应用占用")
        }
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
        // 奖励回路挂在全局壳层，目标页开不开着都能收到推进与里程碑事件。
        target: root.goalServiceRef
        ignoreUnknownSignals: true

        function onGoalProgressed(goalId, title, doneCount, targetPomodoros) {
            root.showToast(String(title || "") + " +1 · "
                           + Number(doneCount) + "/" + Number(targetPomodoros))
        }

        function onMilestoneReached(goalId, title, percent) {
            // C++ 的 focusCompleted 信号链仍在同步收尾；这里只记录参数，把 UI 和声音推迟到下一轮事件循环。
            root.enqueueMilestone(goalId, title, percent)
        }
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

        function onOperationFailed(message) {
            root.showToast(String(message || "专注操作失败"))
        }
    }

    CategoryDialog {
        id: categoryDialog

        parent: root
        manager: root.categoryManagerRef
    }

    RoutineDialog {
        id: routineDialog
        objectName: "routineDialogRoot"

        parent: root
        routineManagerRef: root.routineManagerRef
        categoryManagerRef: root.categoryManagerRef
    }

    ExportDialog {
        id: exportDialog

        parent: root
        exportServiceRef: root.exportServiceRef
    }

    SettingsDialog {
        id: settingsDialog
        objectName: "settingsDialog"

        parent: root
        appSettingsRef: root.appSettingsRef
        backupServiceRef: root.backupServiceRef
        shortcutRegistryRef: root.shortcutRegistryRef

        onRoutineRequested: routineDialog.open()
        onCategoryRequested: categoryDialog.open()
        onExportRequested: exportDialog.open()
        onBackupRequested: root.openBackupSaveDialog()
        onRestoreRequested: restoreOpenDialog.open()
    }

    function openBackupSaveDialog() {
        // 建议文件名含当前时间，必须在每次打开前重新生成；FileDialog 会改写 selectedFile，
        // 不能依赖一个没有 NOTIFY 的长期绑定。
        if (!root.backupServiceRef)
            return
        var directory = root.backupServiceRef.backupsDirectory()
        backupSaveDialog.currentFolder = Qt.resolvedUrl("file://" + directory)
        backupSaveDialog.selectedFile = Qt.resolvedUrl(
                    "file://" + directory + "/" + root.backupServiceRef.suggestedBackupFileName())
        backupSaveDialog.open()
    }

    function backupLocalPath(urlValue) {
        // FileDialog 返回 URL，服务层需要真实本地路径。
        var value = String(urlValue)
        return value.startsWith("file://") ? decodeURIComponent(value.substring(7)) : value
    }

    FileDialog {
        id: backupSaveDialog

        title: "保存备份"
        fileMode: FileDialog.SaveFile
        nameFilters: ["番茄Todo 备份 (*.tomatobackup)"]
        onAccepted: {
            if (root.backupServiceRef)
                root.backupServiceRef.requestBackup(root.backupLocalPath(selectedFile))
        }
    }

    FileDialog {
        id: restoreOpenDialog

        title: "选择要恢复的备份"
        fileMode: FileDialog.OpenFile
        nameFilters: ["番茄Todo 备份 (*.tomatobackup)"]
        onAccepted: {
            if (!root.backupServiceRef)
                return
            var path = root.backupLocalPath(selectedFile)
            root.restoreInspectionPath = path
            root.backupServiceRef.requestBackupInfo(path)
        }
    }

    RestoreConfirmDialog {
        id: restoreConfirmDialog

        parent: root
        onConfirmed: function (path) {
            if (root.backupServiceRef)
                root.backupServiceRef.requestRestore(path)
        }
    }

    Connections {
        // 备份/恢复结果统一用底部 Toast 反馈，成功失败都给可理解的说明。
        target: root.backupServiceRef
        ignoreUnknownSignals: true

        function onBackupCompleted(success, message) {
            root.showToast(String(message || (success ? "备份完成" : "备份失败")))
        }
        function onBackupInfoReady(sourcePath, info) {
            if (String(sourcePath) !== root.restoreInspectionPath)
                return
            root.restoreInspectionPath = ""
            // Connections 的目标是运行时注入的 var，qmllint 无法推导该信号参数结构。
            // qmllint disable missing-property
            if (!info.valid) {
                root.showToast(info.reason && String(info.reason).length > 0
                               ? info.reason : "该备份文件无法恢复")
                return
            }
            // qmllint enable missing-property
            restoreConfirmDialog.backupPath = String(sourcePath)
            restoreConfirmDialog.info = info
            restoreConfirmDialog.open()
        }
        function onRestoreStarted() {
            // 旧库的撤销删除命令不能跨过数据库整体替换边界，否则相同主键会删错恢复数据。
            root.cancelPendingDelete()
        }
        function onRestoreCompleted(success, message) {
            root.showToast(String(message || (success ? "恢复完成" : "恢复失败")))
        }
    }

    Loader {
        anchors.fill: parent
        z: 10000
        active: root.backupServiceRef && root.backupServiceRef.operationBlocksUi

        sourceComponent: Component {
            BackupOperationOverlay {
                message: root.backupServiceRef ? root.backupServiceRef.operationText : ""
                reduceMotion: root.sidebarMotionReduced
            }
        }
    }
}
