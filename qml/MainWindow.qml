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

    // 输入/控件字色必须接管：Basic 风格的默认调色板写死一组浅色主题的值，
    // 既不跟随本应用主题也不跟随 macOS 外观。视图里的控件由这一层覆盖。
    palette.text: Theme.inputInk
    palette.placeholderText: Theme.inputPlaceholderInk
    palette.highlight: Theme.inputSelection
    palette.highlightedText: Theme.inputSelectedInk
    palette.window: Theme.inputPopupSurface
    palette.mid: Theme.inputPopupBorder
    palette.light: Theme.inputPopupHighlight
    palette.midlight: Theme.inputPopupHighlight
    palette.base: Theme.controlSurface
    palette.button: Theme.controlSurface
    palette.buttonText: Theme.controlInk
    palette.windowText: Theme.controlInk

    // 默认落地页为仪表盘：一屏看全今日概览，任务/专注一步可达。
    property string currentView: "dashboard"
    property string pendingView: "dashboard"
    // 淡入淡出期间只保留最后一次视图请求，避免动画队列堆积。
    property string queuedView: ""
    property bool isSwitching: false
    // 原生全屏、主内容显隐和沉浸覆盖层都从这一事实源派生，避免三处互相写状态。
    property bool focusImmersiveActive: false
    property int pendingDeleteTaskId: -1
    property int pendingDeleteSessionId: -1
    property bool pendingDeleteIsRest: false
    property string pendingDeleteTitle: ""
    property int deleteCommitDelayMs: 5000
    property string restoreInspectionPath: ""
    property var interactionCoordinatorRef: null
    onPendingDeleteTaskIdChanged: {
        if (root.interactionCoordinatorRef)
            root.interactionCoordinatorRef.setPendingDelete(root, root.pendingDeleteTaskId)
    }
    Component.onDestruction: {
        if (root.interactionCoordinatorRef) root.interactionCoordinatorRef.end(root)
    }
    property var taskManagerRef: null
    property var categoryManagerRef: null
    property var routineManagerRef: null
    property var exportServiceRef: null
    property var statisticsServiceRef: null
    property var focusHistoryServiceRef: null
    property var countdownServiceRef: null
    property var memoServiceRef: null
    property var memoTextLayoutRef: null
    property var knowledgeGapServiceRef: null
    property var appSettingsRef: null
    property var focusTimerRef: null
    property var logicalDayServiceRef: null
    property var backupServiceRef: null
    property var mcpAccessRef: null
    property var syncControllerRef: null
    property var scheduleServiceRef: null
    property var shortcutRegistryRef: null
    // 「召回 / 隐藏主窗口」只能由 ApplicationWindow 落实；这里和菜单栏一样只发意图。
    signal windowToggleRequested()
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

    // 恢复期间会经过数据库校验、快照与原子替换；Shortcut 和系统全局热键
    // 不经过鼠标命中测试，必须直接从服务的临界区事实状态派生输入守卫。
    readonly property bool backupOperationBlocksInput: !!root.backupServiceRef
                                                       && root.backupServiceRef.operationBlocksUi

    // 弹窗是否已经把输入焦点接管走。Qt 的 Shortcut 不受弹窗遮挡影响：不挡住的话，
    // 用户正在新建任务对话框里打字时按 ⌘1，页面会在弹窗背后被切走（已实测复现）。
    //
    // 判据用「焦点是否落进 overlay」而不是「overlay 上有没有子项」：本应用的弹窗
    // 全部是 modal + focus，而悬停 ToolTip 这类子项同样挂在 overlay 上却不取焦
    // （当初撞上的是目标页热力图的格子提示，那一页已删除），按子项判断会让鼠标划过
    // 带提示的控件时快捷键整体失灵。
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
        case "todayFocus":
            // 这里的数字必须与下方 StackLayout 里页面的书写顺序一一对应，切页状态机按它取页，
            // 新页面一律追加在栈尾。2026-09 删除了原第 7 页「目标」，排在它后面的三页各前移一位；
            // 页面编号没有写进任何设置，只在这里和 StackLayout 之间对应。
            return 7;
        case "schedule":
            return 8;
        case "memo":
            return 10
        case "knowledgeGaps":
            return 9;
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
        var manualRest = mode === 2 && phase === 3
        return (isRunning ? "" : "⏸ ") + (manualRest ? "休息 " : "")
                + timeText + " · 番茄Todo"
    }

    function showToast(message, actionText, actionCallback) {
        // 提示条是单槽：任何新提示都会顶掉撤销条。撤销入口一旦不可见就立即提交删除，
        // 不让“看不见的删除倒计时”在背后继续走完 5 秒。
        if (root.pendingDeleteTaskId > 0 || root.pendingDeleteSessionId > 0) {
            root.commitPendingDelete()
        }
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
        // 例行生成的当日实例：删除只影响今天，例行规则本身不受影响，撤销文案据此区分，
        // 让用户明白这不是删掉了整条例行规则。
        const isRoutine = root.taskManagerRef && root.taskManagerRef.isRoutineGeneratedTask
                ? root.taskManagerRef.isRoutineGeneratedTask(taskId) : false
        var deleteMessage = isRoutine
                ? "已删除今天的例行任务「" + root.pendingDeleteTitle + "」"
                : "已删除「" + root.pendingDeleteTitle + "」"
        // 直接走 globalToast：showToast 会把“已有待删任务”先提交，撤销条自己不能触发这条规则。
        root.pendingDeleteUndoAction = function() {
            root.cancelPendingDelete()
        }
        globalToast.show(deleteMessage, "撤销", root.pendingDeleteUndoAction)
        return true
    }

    function requestDeleteSession(sessionId, title, isRest) {
        if (sessionId <= 0 || !root.commitPendingDelete())
            return false
        root.pendingDeleteIsRest = Boolean(isRest)
        root.pendingDeleteSessionId = sessionId
        root.pendingDeleteTitle = String(title || qsTr("专注记录"))
        deleteCommitTimer.interval = root.deleteCommitDelayMs
        deleteCommitTimer.restart()
        root.pendingDeleteUndoAction = function() {
            root.cancelPendingDelete()
        }
        globalToast.show(qsTr("已删除%1记录「%2」").arg(root.pendingDeleteIsRest ? qsTr("休息") : qsTr("专注")).arg(root.pendingDeleteTitle), qsTr("撤销"), root.pendingDeleteUndoAction)
        return true
    }

    // 完成撤销：完成已即时写库，撤销时把完成态翻回。5 秒撤销条内点击即可恢复完成前状态，
    // 任务 ID、排序、字段都不变（只改了 completed 一列）。
    // 例外是「完成」弹窗写下的完成记录：撤销不清除它——未完成的卡片不显示记录，
    // 再次完成时弹窗会预填回来，免得一次误触就把刚写的内容丢掉。
    // 完成时顺带结束的专注也不恢复：那段记录已经按正常结束保存，撤销只管任务的完成态。
    function showCompletionUndoToast(taskId, message) {
        showToast(message, "撤销", function() {
            if (!root.taskManagerRef || !root.taskManagerRef.setTaskCompleted(taskId, false)) {
                root.showToast("撤销完成失败，请重试")
            }
        })
    }

    // 当前待删除项的「撤销」回调。提前提交后要凭它收起那条撤销条（见 commitPendingDelete）。
    property var pendingDeleteUndoAction: null

    function flushMemoEdits() {
        if (memoView.saveNow()) return true
        root.switchToView("memo")
        return false
    }

    function commitPendingDelete() {
        if (root.pendingDeleteTaskId <= 0 && root.pendingDeleteSessionId <= 0) {
            return true
        }

        deleteCommitTimer.stop()
        // 删除一旦触库就不能撤销了。补录、备份、恢复、关窗等路径会提前提交，
        // 此时撤销条可能还在剩余的几秒里挂着：用户点「撤销」提示条会消失、看起来像撤销成功，
        // 记录却已经永久删除。所以不论成败，先收起属于这次删除的撤销条。
        globalToast.dismissAction(root.pendingDeleteUndoAction)
        root.pendingDeleteUndoAction = null
        // 到这里才真正触库；撤销窗口内数据库没有被碰过，专注记录关联不会提前丢失。
        var deletedTitle = root.pendingDeleteTitle
        // 任务和专注记录共用单槽撤销及退出守卫，避免切页后遗失尚未提交的删除。
        var deleted = root.pendingDeleteSessionId > 0
                ? root.focusHistoryServiceRef && (root.pendingDeleteIsRest
                    ? root.focusHistoryServiceRef.deleteRestSession(root.pendingDeleteSessionId)
                    : root.focusHistoryServiceRef.deleteSession(root.pendingDeleteSessionId))
                : root.taskManagerRef && root.taskManagerRef.deleteTask(root.pendingDeleteTaskId)
        if (!deleted) {
            // 失败后立即解除隐藏，让任务重新出现；不能把数据库失败伪装成“已删除”。
            root.pendingDeleteTaskId = -1
            root.pendingDeleteSessionId = -1
            root.pendingDeleteTitle = ""
            root.showToast("删除「" + deletedTitle + "」失败，请重试")
            return false
        }
        root.pendingDeleteTaskId = -1
        root.pendingDeleteSessionId = -1
        root.pendingDeleteTitle = ""
        return true
    }

    function cancelPendingDelete() {
        deleteCommitTimer.stop()
        root.pendingDeleteUndoAction = null
        root.pendingDeleteTaskId = -1
        root.pendingDeleteSessionId = -1
        root.pendingDeleteTitle = ""
    }

    // 今日任务、本周计划、仪表盘三个任务入口都从这里分流。
    // 开启「快速开始」：沿用上次模式立即计时；关闭（默认）：只进入专注页待机，
    // 预选上次的模式，由用户确认模式和时长后再点开始。
    function startFocusForTask(taskId, taskTitle) {
        var usePomodoro = root.appSettingsRef && root.appSettingsRef.lastMode === 1
        root.switchToView("focus")
        if (root.appSettingsRef && root.appSettingsRef.quickStartEnabled)
            focusView.startTask(taskId, taskTitle, usePomodoro)
        else
            focusView.prepareTask(taskId, taskTitle, usePomodoro)
    }

    function isManualRestActive() {
        return !!root.focusTimerRef && Number(root.focusTimerRef.mode) === 2
                && Number(root.focusTimerRef.phase) === 3
    }

    function startManualRest() {
        if (!root.focusTimerRef) {
            root.showToast("休息计时不可用")
            return
        }
        if (root.focusTimerRef.hasActiveSession || root.focusTimerRef.phase !== 0) {
            focusView.syncToActiveTimer()
            root.showToast(root.isManualRestActive() ? "正在休息" : "已有计时进行中")
            root.switchToView("focus")
            return
        }
        if (!root.focusTimerRef.startManualRest()) {
            root.showToast("休息启动失败，请重试")
            return
        }
        focusView.syncToActiveTimer()
        root.switchToView("focus")
    }

    // —— 快捷键动作分发 ——
    // 应用内快捷键与全局热键最终都落到这里，按动作 id 分发。键位是什么、由谁触发，
    // 全部由 ShortcutRegistry 决定，这一层只关心「做什么」。
    function triggerShortcutAction(actionId) {
        // 最终出口也要守住：测试或其他代码可能直接调用分发函数，
        // 不能只依赖 AppShortcuts 的 enabled 状态。
        if (root.backupOperationBlocksInput)
            return

        switch (String(actionId)) {
        case "view.dashboard": root.switchToView("dashboard"); return
        case "view.today": root.switchToView("today"); return
        case "view.focus": root.switchToView("focus"); return
        case "view.week": root.switchToView("week"); return
        case "view.month": root.switchToView("month"); return
        case "view.stats": root.switchToView("stats"); return
        case "view.countdown": root.switchToView("countdown"); return
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
        case "gap.capture":
        case "global.captureGap": root.captureKnowledgeGapFromShortcut(); return
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
            var manualRest = root.isManualRestActive()
            root.showToast(root.focusTimerRef.isRunning
                           ? (manualRest ? "已继续休息" : "已继续专注")
                           : (manualRest ? "已暂停休息" : "已暂停专注"))
            return
        }

        // 没有会话时按当前模式直接开始。取哪一条由专注页的 startFromShortcut 决定：
        // 已有选中项优先，否则取今日第一个未完成任务。
        //
        // 取不到时它会展开任务选择器（今日零任务、今日任务全部已完成，两种情况同等对待），
        // 用户可以挑一条已完成的再练一轮，也可以直接敲一个新任务。
        // 此前这里只弹一句「请先选择要专注的任务」，而专注页当时并没有选择器，
        // 于是快捷键把人送到一个做不到该动作的页面——那是一条死路。
        root.switchToView("focus")
        Qt.callLater(function () {
            if (!focusView.startFromShortcut() && focusView.shortcutOpenedSelector) {
                root.showToast("今天还没有可以开始的任务，挑一条或新建一个")
            }
        })
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
            if (focusView.state === "manualRest") {
                focusView.endManualRest()
            } else if (focusView.pomodoroModeSelected) {
                focusView.endPomodoro()
            } else {
                focusView.endFreeFocus()
            }
        })
    }

    // 由 main.qml 绑定到窗口的 active。默认真：嵌入式组件测试和旧上下文没有窗口概念，
    // 那里捕获框照常直接打开。
    property bool windowActive: true
    // 窗口还没激活时收到的捕获请求。等它真激活了再开框。
    property bool pendingGapCapture: false

    // 请求把主窗口叫到前台。main.qml 负责 show/raise/requestActivate——
    // 窗口操作属于窗口那一层，MainWindow 只表达意图。
    signal windowActivationRequested()

    // 记一笔的键盘入口（应用内 gap.capture 与全局 global.captureGap 落到这里）。
    //
    // 窗口在后台时**不能直接开框**：此时键盘焦点还在原来那个应用里，
    // 框开出来了用户打的字会落到别处。所以先请求前置，等 windowActive 真的变真再开。
    // 挂起的后台捕获请求多久作废。窗口激活正常在一瞬间完成；等不到说明系统拒绝了前置，
    // 这时请求必须作废——否则用户过一小时随手打开应用，捕获框会莫名其妙弹出来。
    property int gapCaptureRequestTimeoutMs: 3000

    // 捕获此刻是否被阻断：弹窗占着焦点、正在录快捷键，或备份/恢复正处在数据库临界区。
    // 与应用内快捷键整体让路（AppShortcuts.suspended）的条件一致；全局热键不经过 suspended，
    // 挂起请求又是在激活时才执行——triggerShortcutAction 入口的数据库守卫管不到那一刻，
    // 所以三项必须在这一处一起判。捕获框挂在 overlay 上，会盖过恢复遮罩并接收键盘。
    function gapCaptureBlocked() {
        return root.overlayHoldsFocus || settingsDialog.recordingShortcut
                || root.backupOperationBlocksInput
    }

    function captureKnowledgeGapFromShortcut() {
        if (root.gapCaptureBlocked()) {
            return
        }
        if (root.windowActive) {
            root.openKnowledgeGapCapture()
            return
        }
        root.pendingGapCapture = true
        gapCaptureRequestExpiry.restart()
        root.windowActivationRequested()
    }

    function cancelPendingGapCapture() {
        gapCaptureRequestExpiry.stop()
        root.pendingGapCapture = false
    }

    Timer {
        id: gapCaptureRequestExpiry
        interval: root.gapCaptureRequestTimeoutMs
        repeat: false
        onTriggered: root.pendingGapCapture = false
    }

    onWindowActiveChanged: {
        if (!root.windowActive || !root.pendingGapCapture) {
            return
        }
        // 先作废请求再判阻断：被挡住的请求不留到下一次激活。
        // 挂起期间可能开了弹窗或进入了快捷键录制，执行前必须再判一次。
        root.cancelPendingGapCapture()
        if (root.gapCaptureBlocked()) {
            return
        }
        root.openKnowledgeGapCapture()
    }

    // 在专注页、且专注页自己的入口可用时，用那个入口——它带来源任务与科目。
    // 其它页面没有「当前任务」；主动休息时专注页入口隐藏、也没有任务上下文。
    // 这两种情况都走窗口级的无来源捕获：没有上下文只意味着不附带任务和科目，不是禁止捕获。
    function openKnowledgeGapCapture() {
        if (root.currentView === "focus" && focusView.knowledgeGapEntryAvailable) {
            focusView.openKnowledgeGapCapture()
            return
        }
        globalGapCapturePopup.openWithSource(0, "", 0)
    }

    function toggleImmersiveFromShortcut() {
        if (root.focusImmersiveActive) {
            root.focusImmersiveActive = false
            return
        }
        if (!focusView.immersiveAvailable) {
            root.showToast("沉浸模式只在进行中的计时内可用")
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

    // 在其它页面原地结束计时期间为真（仪表盘「结束」、完成正在计时的任务）。
    // 专注页的结束入口会同步发 focusEnded / manualRestEnded，那两个处理函数据此跳过「回今日页」：
    // 那条规则针对的是从专注页结束，用户在仪表盘或今日页操作就该留在原页。
    property bool endingFocusInPlace: false

    // 在当前页原地结束计时。规则不在这里复制：超长自由专注确认、番茄循环计数归零、
    // 主动休息收尾都走专注页的单点入口，与专注页按钮、菜单栏、快捷键同口径。
    // 返回结果，提示怎么写由调用方决定：
    //   "none"       没有进行中的计时；
    //   "confirming" 自由专注超过提醒时长，已转去专注页弹确认框，此刻还没有结束；
    //   "ended"      已结束（包括不足 3 分钟被丢弃的情况）；
    //   "failed"     结束失败，计时仍在继续，原因写在 focusView.errorText。
    function endFocusInPlace() {
        var timer = root.focusTimerRef
        if (!timer || (!timer.hasActiveSession && Number(timer.phase) === 0)) {
            return "none"
        }
        if (focusView.shouldConfirmLongFreeStop()) {
            // 确认弹窗属于专注页，要切过去才看得见；记录、丢弃或修正由弹窗走完。
            root.requestLongFreeFocusStop()
            return "confirming"
        }

        // 按计时器的真实模式分发，不看专注页本地的模式选择：
        // 用户可能从没打开过专注页，本地选择未必和计时器一致。
        // 模式取值：0 = 自由专注，1 = 番茄，2 = 主动休息（阶段 3）。
        root.endingFocusInPlace = true
        if (Number(timer.mode) === 2 && Number(timer.phase) === 3) {
            focusView.endManualRest()
        } else if (Number(timer.mode) === 1) {
            focusView.endPomodoro()
        } else {
            focusView.endFreeFocus()
        }
        root.endingFocusInPlace = false
        // 三个结束入口成功时都会清空 errorText、失败时写入原因，所以调用之后读到的就是这一次的结果。
        return focusView.errorText.length > 0 ? "failed" : "ended"
    }

    // 仪表盘「结束」。
    function endFocusFromDashboard() {
        // 结束入口失败时只写专注页的 errorText，仪表盘上看不见，得转成提示条。
        if (root.endFocusInPlace() === "failed") {
            root.showToast(focusView.errorText)
        }
    }

    // 为完成任务而结束专注期间为真。这段时间计时器同步发出的「不足 3 分钟未计入」
    // 不单独弹提示，改由完成提示一并说明：提示条只有一个槽，单独弹会被紧跟着的撤销条顶掉；
    // 反过来先弹撤销条，又会被它顶掉撤销入口。
    property bool endingFocusForCompletion: false
    property bool completionFocusDiscarded: false

    // 用户在今日、仪表盘或本周页亲手完成了任务（复选框或「完成」弹窗），写库已经成功。
    // 完成的正是正在计时的任务时，顺带结束这段专注：任务已经做完，计时再走下去
    // 只会把之后的时间也记到它头上，此前用户得专门去专注页再点一次「结束专注」。
    function handleTaskCompletedByUser(taskId, taskTitle) {
        var timer = root.focusTimerRef
        var focusResult = "none"
        // 只认「此刻正在给这个任务计时」时的这一下完成，不能写成「任务已完成就停表」：
        // 已完成的任务允许再练一轮（专注页选择器里可以挑），那种计时不该被打断。
        // 番茄休息阶段没有专注会话（hasActiveSession 为假），休息照常进行。
        if (timer && timer.hasActiveSession && Number(timer.currentTaskId) === Number(taskId)) {
            root.completionFocusDiscarded = false
            root.endingFocusForCompletion = true
            focusResult = root.endFocusInPlace()
            root.endingFocusForCompletion = false
        }

        var message = "已完成「" + String(taskTitle || "") + "」"
        if (focusResult === "ended") {
            message += root.completionFocusDiscarded ? "，专注不足 3 分钟，未计入记录" : "，专注已结束"
        } else if (focusResult === "failed") {
            // 失败原因同时留在专注页的错误行里，用户去专注页还能再点「结束专注」。
            message += "，但结束专注失败，计时仍在继续"
        }
        // "confirming" 不加说明：页面已切到专注页，确认框自己会讲清楚这段专注怎么记。
        root.showCompletionUndoToast(taskId, message)
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
        // 移动端窗口延伸到状态栏与底部横条之下（见 main.qml 的 ExpandedClientAreaHint）：
        // 只让内容让开系统区域，壁纸与侧栏玻璃仍铺满整个窗口。桌面上这些边距恒为 0。
        anchors.topMargin: root.SafeArea.margins.top
        anchors.bottomMargin: root.SafeArea.margins.bottom
        anchors.leftMargin: root.SafeArea.margins.left
        anchors.rightMargin: root.SafeArea.margins.right
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
                settingsRef: root.appSettingsRef

                Behavior on opacity {
                    enabled: !root.sidebarMotionReduced
                    NumberAnimation {
                        duration: Theme.reduceMotion ? 0 : 220
                        easing.type: Easing.OutCubic
                    }
                }

                onItemClicked: function (viewName) {
                    // 左侧“今日专注”永远回到逻辑今天；历史月历跳转会直接指定日期，
                    // 两条入口不能共用一个隐式的“上次查看日期”。
                    if (viewName === "todayFocus") {
                        todayFocusView.showToday();
                    }
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
                    interactionCoordinatorRef: root.interactionCoordinatorRef
                    taskManagerRef: root.taskManagerRef
                    statisticsServiceRef: root.statisticsServiceRef
                    routineManagerRef: root.routineManagerRef
                    focusTimerRef: root.focusTimerRef
                    logicalDayServiceRef: root.logicalDayServiceRef
                    categoryManagerRef: root.categoryManagerRef
                    countdownServiceRef: root.countdownServiceRef
                    knowledgeGapServiceRef: root.knowledgeGapServiceRef
                    settingsRef: root.appSettingsRef
                    pendingDeleteTaskId: root.pendingDeleteTaskId

                    onStartFocus: function (taskId, taskTitle) {
                        root.startFocusForTask(taskId, taskTitle);
                    }

                    onKnowledgeGapsRequested: root.switchToView("knowledgeGaps")
                    onKnowledgeGapCaptured: root.showToast(qsTr("已记入知识缺口"))
                    onKnowledgeGapsConverted: function (count) {
                        root.showToast(qsTr("已把 %1 条知识缺口加到今天的任务").arg(count))
                    }

                    onManualRestRequested: root.startManualRest()
                    onManualRestPageRequested: {
                        focusView.syncToActiveTimer()
                        root.switchToView("focus")
                    }

                    onCountdownRequested: root.switchToView("countdown")
                    onDeleteRequested: function(taskId, taskTitle) {
                        root.requestDeleteTask(taskId, taskTitle)
                    }
                    onTaskCompletionUndoable: function(taskId, title) {
                        root.handleTaskCompletedByUser(taskId, title)
                    }
                }

                FocusView {
                    id: focusView
                    objectName: "focusViewPage"
                    timer: root.focusTimerRef
                    taskManagerRef: root.taskManagerRef
                    knowledgeGapServiceRef: root.knowledgeGapServiceRef
                    settings: root.appSettingsRef
                    pageActive: root.currentView === "focus"
                    pendingDeleteTaskId: root.pendingDeleteTaskId

                    onKnowledgeGapCaptured: root.showToast(qsTr("已记入知识缺口"))

                    onFocusEnded: {
                        // 先退出沉浸再切页，今日页不能留在无侧栏的原生全屏状态。
                        root.focusImmersiveActive = false;
                        if (!root.endingFocusInPlace)
                            root.switchToView("today");
                    }

                    onManualRestEnded: {
                        root.focusImmersiveActive = false;
                        if (!root.endingFocusInPlace)
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
                    objectName: "weekPlanViewPage"
                    pageActive: root.currentView === "week"
                    interactionCoordinatorRef: root.interactionCoordinatorRef
                    taskManagerRef: root.taskManagerRef
                    logicalDayServiceRef: root.logicalDayServiceRef
                    settingsRef: root.appSettingsRef
                    categoryManagerRef: root.categoryManagerRef
                    pendingDeleteTaskId: root.pendingDeleteTaskId

                    onStartFocus: function (taskId, taskTitle) {
                        root.startFocusForTask(taskId, taskTitle);
                    }

                    onDeleteRequested: function(taskId, taskTitle) {
                        root.requestDeleteTask(taskId, taskTitle)
                    }
                    onTaskCompletionUndoable: function(taskId, title) {
                        root.handleTaskCompletedByUser(taskId, title)
                    }
                }

                MonthGoalView {
                    objectName: "monthGoalViewPage"
                    pageActive: root.currentView === "month"
                    focusTimerRef: root.focusTimerRef
                    focusHistoryServiceRef: root.focusHistoryServiceRef
                    logicalDayServiceRef: root.logicalDayServiceRef
                    settingsRef: root.appSettingsRef
                    categoryManagerRef: root.categoryManagerRef

                    onFocusDateRequested: function (date) {
                        todayFocusView.showDate(date)
                        root.switchToView("todayFocus")
                    }
                }

                StatisticsView {
                    objectName: "statisticsViewPage"
                    pageActive: root.currentView === "stats"
                    taskManagerRef: root.taskManagerRef
                    statisticsServiceRef: root.statisticsServiceRef
                    focusTimerRef: root.focusTimerRef
                    logicalDayServiceRef: root.logicalDayServiceRef
                    appSettingsRef: root.appSettingsRef
                    categoryManagerRef: root.categoryManagerRef
                }

                CountdownView {
                    objectName: "countdownViewPage"
                    countdownServiceRef: root.countdownServiceRef
                }

                DashboardView {
                    objectName: "dashboardViewPage"
                    pageActive: root.currentView === "dashboard"

                    interactionCoordinatorRef: root.interactionCoordinatorRef
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
                    onStopFocusRequested: root.endFocusFromDashboard()
                    onDeleteRequested: function(taskId, taskTitle) {
                        root.requestDeleteTask(taskId, taskTitle)
                    }
                    onTaskCompletionUndoable: function(taskId, title) {
                        root.handleTaskCompletedByUser(taskId, title)
                    }
                }

                TodayFocusView {
                    id: todayFocusView
                    objectName: "todayFocusViewPage"
                    pendingDeleteSessionId: root.pendingDeleteSessionId
                    pendingDeleteIsRest: root.pendingDeleteIsRest
                    pendingDeleteTaskId: root.pendingDeleteTaskId
                    onDeleteRequested: function(sessionId, title, isRest) {
                        root.requestDeleteSession(sessionId, title, isRest)
                    }
                    onPendingDeleteFlushRequested: root.commitPendingDelete()
                    pageActive: root.currentView === "todayFocus"
                    focusTimerRef: root.focusTimerRef
                    focusHistoryServiceRef: root.focusHistoryServiceRef
                    logicalDayServiceRef: root.logicalDayServiceRef
                    settingsRef: root.appSettingsRef
                    taskManagerRef: root.taskManagerRef
                }

                SchedulePlanView {
                    objectName: "schedulePlanViewPage"
                    pageActive: root.currentView === "schedule"
                    scheduleServiceRef: root.scheduleServiceRef
                    settingsRef: root.appSettingsRef
                    categoryManagerRef: root.categoryManagerRef
                    logicalDayServiceRef: root.logicalDayServiceRef
                }

                KnowledgeGapView {
                    objectName: "knowledgeGapViewPage"
                    pageActive: root.currentView === "knowledgeGaps"
                    knowledgeGapServiceRef: root.knowledgeGapServiceRef
                    categoryManagerRef: root.categoryManagerRef
                    logicalDayServiceRef: root.logicalDayServiceRef
                    settingsRef: root.appSettingsRef
                    taskManagerRef: root.taskManagerRef

                    onGapConvertedToTask: function (title) {
                        root.showToast(qsTr("已加到今天的任务：%1").arg(title))
                    }
                }
                MemoView {
                    id: memoView
                    objectName: "memoViewPage"
                    pageActive: root.currentView === "memo"
                    memoServiceRef: root.memoServiceRef
                    categoryManagerRef: root.categoryManagerRef
                    textLayoutRef: root.memoTextLayoutRef
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

    AppShortcuts {
        id: appShortcuts
        objectName: "appShortcuts"

        registryRef: root.shortcutRegistryRef
        // 录制键位、弹窗接管焦点或数据库恢复占用临界区时，
        // 都必须停用应用内与系统级快捷键，避免在遮罩后修改新数据库。
        suspended: settingsDialog.recordingShortcut || root.overlayHoldsFocus
                   || root.backupOperationBlocksInput
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
        anchors.bottomMargin: Theme.space32 + root.SafeArea.margins.bottom
    }

    Timer {
        id: deleteCommitTimer

        interval: 5000
        onTriggered: root.commitPendingDelete()
    }

    Connections {
        // 待删任务可能被别的路径先删掉：删除、停用每日例行会顺带收回今天那条还没动过的实例，
        // 外部 AI 接入也能删任务。这时既没有东西可提交，也没有东西可撤销。
        // 不清掉单槽的话，窗口到期再删一次必然失败，弹出一条假的「删除失败，请重试」；
        // 撤销条留着，也会让用户以为还能把任务找回来。
        // taskDeleted 只在删除提交之后才发出，按它解绑不需要再去查询任务是否还在。
        target: root.taskManagerRef
        ignoreUnknownSignals: true

        function onTaskDeleted(taskId) {
            if (Number(taskId) !== root.pendingDeleteTaskId)
                return
            // commitPendingDelete 自己调用 deleteTask 时也会同步走到这里。那时计时器已停、
            // 撤销条已收、回调已清空，下面几步再执行一遍没有副作用，提交流程照常收尾。
            deleteCommitTimer.stop()
            globalToast.dismissAction(root.pendingDeleteUndoAction)
            root.pendingDeleteUndoAction = null
            root.pendingDeleteTaskId = -1
            root.pendingDeleteTitle = ""
        }
    }

    Connections {
        target: root.focusTimerRef
        ignoreUnknownSignals: true

        function onSessionDiscarded(duration) {
            if (root.endingFocusForCompletion) {
                root.completionFocusDiscarded = true
                return
            }
            root.showToast("本次专注不足 3 分钟，未计入记录")
        }

        function onTaskAutoCompleteFailed(taskId) {
            root.showToast("专注记录已保存，但任务自动完成失败，请手动检查")
        }

        function onOperationFailed(message) {
            root.showToast(String(message || "专注操作失败"))
        }
    }

    KnowledgeGapCapturePopup {
        id: globalGapCapturePopup
        objectName: "globalKnowledgeGapCapturePopup"

        // Popup 渲染在窗口 overlay 层，挂同一层并居中，才不会被页面内容盖住。
        parent: root.Overlay.overlay
        anchors.centerIn: parent
        gapServiceRef: root.knowledgeGapServiceRef

        onCaptured: root.showToast(qsTr("已记入知识缺口"))
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
        mcpAccessRef: root.mcpAccessRef
        backupServiceRef: root.backupServiceRef
        syncControllerRef: root.syncControllerRef
        shortcutRegistryRef: root.shortcutRegistryRef

        onRoutineRequested: routineDialog.open()
        onCategoryRequested: categoryDialog.open()
        onExportRequested: exportDialog.open()
        onBackupRequested: root.openBackupSaveDialog()
        onRestoreRequested: restoreOpenDialog.open()
        onSyncLogRequested: syncLogDialog.open()
    }

    SyncLogDialog {
        id: syncLogDialog

        parent: root
        syncControllerRef: root.syncControllerRef
    }

    Connections {
        // 同步里值得告诉你的事（已经加入、建好了文件夹、另一台设备恢复了备份）用提示条说。
        // 需要你处理的问题不走这里：它们一直显示在设置页的同步状态里，提示条几秒就消失了。
        target: root.syncControllerRef
        ignoreUnknownSignals: true

        function onNotice(message) {
            root.showToast(String(message))
        }
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
            if (root.backupServiceRef && root.commitPendingDelete())
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
        objectName: "restoreConfirmDialog"

        parent: root
        onConfirmed: function (path) {
            if (root.backupServiceRef && root.commitPendingDelete())
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
            // 打开确认框这一刻取一次提醒：弹窗是模态的，确认之前同步开关和加入状态不会再变。
            restoreConfirmDialog.syncWarning = root.syncControllerRef
                    ? String(root.syncControllerRef.restoreWarning()) : ""
            restoreConfirmDialog.open()
        }
        function onRestoreStarted() {
            // 不同数据库可以有相同任务编号，换库前清理选择及所有待续动作，不能按旧编号重新绑定。
            focusView.clearSelectedTask()
            focusView.pendingSwitch = null
            focusView.cancelAutoAdvance()
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
