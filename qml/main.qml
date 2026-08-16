import QtQuick
import QtQuick.Controls
import "."
import "components"

ApplicationWindow {
    id: root

    // 全应用输入框字色的兜底层。Qt Quick Controls 的 TextField 从 palette 取正文/占位/
    // 选区颜色，Basic 风格的默认值写死深灰，夜间主题下几乎看不见。palette 会从窗口
    // 传播到每个子项和弹窗（弹窗虽然重挂到 overlay，仍以窗口为调色板来源），
    // 所以这一处就覆盖了全部输入控件，包括以后新加的。各弹窗自己也写了一份，
    // 那份只为独立实例化（离屏走查、QML 测试）准确，线上以这里为准。
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

    // 只有真实应用入口绑定全局令牌，避免多个独立 MainWindow 测试实例争抢单例属性。
    Binding {
        target: Theme
        property: "reduceMotion"
        // qmllint disable unqualified
        value: typeof appSettings !== "undefined" && appSettings
               ? Boolean(appSettings.reduceMotion) : false
        // qmllint enable unqualified
    }

    // 这里是 QML 应用入口，只负责窗口尺寸和装载真正的主界面。
    visible: true
    width: 1024
    height: 768
    minimumWidth: 860
    minimumHeight: 620
    title: mainContent.windowTitleText
    color: Theme.surface

    MainWindow {
        id: mainContent

        anchors.fill: parent
        // 上下文属性只在应用入口解包，业务组件内部全部消费显式引用，避免动态作用域漂移。
        // qmllint disable unqualified
        taskManagerRef: typeof taskManager === "undefined" ? null : taskManager
        categoryManagerRef: typeof categoryManager === "undefined" ? null : categoryManager
        routineManagerRef: typeof routineManager === "undefined" ? null : routineManager
        exportServiceRef: typeof exportService === "undefined" ? null : exportService
        statisticsServiceRef: typeof statisticsService === "undefined" ? null : statisticsService
        focusHistoryServiceRef: typeof focusHistoryService === "undefined" ? null : focusHistoryService
        countdownServiceRef: typeof countdownService === "undefined" ? null : countdownService
        appSettingsRef: typeof appSettings === "undefined" ? null : appSettings
        focusTimerRef: typeof focusTimer === "undefined" ? null : focusTimer
        logicalDayServiceRef: typeof logicalDayService === "undefined" ? null : logicalDayService
        backupServiceRef: typeof backupService === "undefined" ? null : backupService
        goalServiceRef: typeof goalService === "undefined" ? null : goalService
        phaseSoundServiceRef: typeof phaseSoundService === "undefined" ? null : phaseSoundService
        shortcutRegistryRef: typeof shortcutRegistry === "undefined" ? null : shortcutRegistry
        // qmllint enable unqualified
    }

    function acknowledgeNaturalCompletionNotice() {
        // 上下文条件与 Loader 已保证设置存在；这里仍保留守卫，避免独立 QML 验证时误写空对象。
        // qmllint disable unqualified
        if (typeof appSettings === "undefined" || !appSettings)
            return

        appSettings.naturalCompletionNoticeShown = true
        if (appSettings.naturalCompletionNoticeShown)
            return

        // 写盘失败时不能把一次性说明伪装成已确认。弹窗自身已关闭，下一事件循环重新打开，
        // 让用户修复权限后仍可明确确认；这里不改 Loader.active，以保留其声明式绑定。
        mainContent.showToast(qsTr("提示确认未保存，请检查设置文件权限后重试"))
        Qt.callLater(function() {
            if (naturalCompletionNoticeLoader.status === Loader.Ready
                    && naturalCompletionNoticeLoader.item) {
                // Loader.item 的静态类型是 QObject；实际来源固定为该说明 Popup。
                // qmllint disable missing-property
                naturalCompletionNoticeLoader.item.open()
                // qmllint enable missing-property
            }
        })
        // qmllint enable unqualified
    }

    Loader {
        id: naturalCompletionNoticeLoader
        objectName: "naturalCompletionNoticeLoader"

        anchors.fill: parent
        // 仅向升级前已有数据库且尚未确认的用户展示。设置写成功后绑定自动变 false，
        // Loader 会销毁 Popup，避免它在当前会话或后续启动再次出现。
        // qmllint disable unqualified
        active: typeof naturalCompletionNoticeRequired !== "undefined"
                && Boolean(naturalCompletionNoticeRequired)
                && typeof appSettings !== "undefined" && appSettings
                && !appSettings.naturalCompletionNoticeShown
        // qmllint enable unqualified
        source: "components/NaturalCompletionNoticeDialog.qml"

        onLoaded: {
            if (status !== Loader.Ready || !item)
                return
            // source 固定为 NaturalCompletionNoticeDialog；Loader 的 QObject 推导不到其信号和方法。
            // qmllint disable missing-property
            item.acknowledged.connect(root.acknowledgeNaturalCompletionNotice)
            item.open()
            // qmllint enable missing-property
        }
    }

    onClosing: function(close) {
        // 备份/恢复或导出尚未结束时禁止关闭，避免线程被销毁在原子替换或写文件中途。
        const blockReason = root.shutdownBlockReason()
        if (blockReason.length > 0) {
            close.accepted = false
            mainContent.showToast(blockReason)
            return
        }
        // 撤销窗口尚未结束时关闭应用，必须先同步提交；失败则阻止退出，避免任务下次启动“复活”。
        if (!mainContent.commitPendingDelete()) {
            close.accepted = false
            return
        }
        // 只有用户明确开启菜单栏驻留时才隐藏；默认关闭必须真正结束进程。
        // qmllint disable unqualified
        var toTray = (typeof appSettings !== "undefined" && appSettings)
                ? appSettings.closeToTray : false
        if (toTray) {
            close.accepted = false
            root.hide()
            // 窗口已经隐藏，应用内 Toast 不可见；首次改用静默系统通知，成功投递后再记为已提示。
            if (typeof appSettings !== "undefined" && appSettings && !appSettings.closeToTrayHintShown) {
                if (typeof notificationService !== "undefined" && notificationService) {
                    notificationService.notify(
                                "已隐藏到菜单栏",
                                "专注仍在继续。点菜单栏图标可召回窗口，「退出」才会完全关闭。",
                                false)
                }
            }
        } else {
            // 全局禁用了“最后窗口关闭即退出”，这里必须显式结束事件循环。
            Qt.callLater(Qt.quit)
        }
        // qmllint enable unqualified
    }

    // 菜单栏「显示主窗口」「退出」意图在这里落实：复用窗口召回与待删提交逻辑，
    // 平台层（TrayController）只发意图，不直接操作窗口或进程。
    Connections {
        // qmllint disable unqualified
        target: typeof trayController === "undefined" ? null : trayController
        // qmllint enable unqualified
        ignoreUnknownSignals: true

        function onShowWindowRequested() {
            root.show()
            root.raise()
            root.requestActivate()
        }

        function onLongFreeFocusStopRequested() {
            mainContent.requestLongFreeFocusStop()
        }

        function onQuitRequested() {
            const blockReason = root.shutdownBlockReason()
            if (blockReason.length > 0) {
                // 窗口可能已隐藏到菜单栏，不先叫回前台用户看不到这条提示。
                root.show()
                root.raise()
                root.requestActivate()
                mainContent.showToast(blockReason)
                return
            }
            // 退出前仍要提交待删任务，避免下次启动“复活”；提交失败则不退出。
            if (mainContent.commitPendingDelete()) {
                Qt.quit()
            }
        }
    }

    // macOS 从 Dock 再次激活一个已隐藏的进程时不会自动显示被显式 hide() 的窗口。
    // 单实例 IPC 覆盖“第二进程启动”，这里覆盖“系统直接复用旧进程”这条路径。
    Connections {
        target: Application

        function onStateChanged() {
            if (Application.state === Qt.ApplicationActive && !root.visible) {
                root.show()
                root.raise()
                root.requestActivate()
            }
        }
    }

    ImmersionWindowSync {
        id: immersionSync
    }

    ShutdownGuard {
        id: shutdownGuard
    }

    // 上下文属性在这里解包一次，两条退出路径（关窗、菜单栏退出）共用同一判据，
    // 避免两处各写一份而漂移。
    function shutdownBlockReason() {
        // qmllint disable unqualified
        const backupBusy = typeof backupService !== "undefined" && backupService
                && backupService.busy
        const backupText = backupBusy ? backupService.operationText : ""
        const exportBusy = typeof exportService !== "undefined" && exportService
                && exportService.busy
        // qmllint enable unqualified
        return shutdownGuard.blockReason(backupBusy, backupText, exportBusy)
    }

    Connections {
        target: mainContent

        function onFocusImmersiveActiveChanged() {
            root.visibility = immersionSync.visibilityForImmersiveChange(
                        mainContent.focusImmersiveActive, root.visibility)
        }

        // 全局热键的「召回 / 隐藏主窗口」。判据是「可见且已激活」而不是只看 visible：
        // 窗口露在别的应用后面时，用户按这组键的意图是把它叫到前面，不是把它藏起来。
        function onWindowToggleRequested() {
            if (root.visible && root.active) {
                root.hide()
                return
            }
            root.show()
            root.raise()
            root.requestActivate()
        }
    }

    // 系统手势或绿灯退出原生全屏时，反向归零沉浸事实源。
    onVisibilityChanged: {
        if (!immersionSync.immersiveActiveAfterVisibilityChange(
                    root.visibility, mainContent.focusImmersiveActive)
                && mainContent.focusImmersiveActive) {
            mainContent.focusImmersiveActive = false
        }
    }

    PhaseCompletionCoordinator {
        windowRef: root
        // 运行时上下文属性由 main.cpp 注入，独立协调器只消费引用，不持有服务生命周期。
        // qmllint disable unqualified
        focusTimerRef: focusTimer
        settingsRef: typeof appSettings === "undefined" ? null : appSettings
        notificationServiceRef: typeof notificationService === "undefined"
                                ? null : notificationService
        phaseSoundServiceRef: typeof phaseSoundService === "undefined"
                              ? null : phaseSoundService
        // qmllint enable unqualified
    }

    Connections {
        // qmllint disable unqualified
        target: typeof notificationService === "undefined" ? null : notificationService
        // qmllint enable unqualified
        ignoreUnknownSignals: true

        function onNotificationDelivered(title) {
            // 只有系统真正接收了首次隐藏通知，才永久关闭这条教育提示。
            // qmllint disable unqualified
            if (title === "已隐藏到菜单栏"
                    && typeof appSettings !== "undefined" && appSettings) {
                appSettings.closeToTrayHintShown = true
            }
            // qmllint enable unqualified
        }
    }
}
