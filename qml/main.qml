import QtQuick
import QtQuick.Controls
import "."
import "components"

ApplicationWindow {
    id: root

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
        countdownServiceRef: typeof countdownService === "undefined" ? null : countdownService
        appSettingsRef: typeof appSettings === "undefined" ? null : appSettings
        focusTimerRef: typeof focusTimer === "undefined" ? null : focusTimer
        logicalDayServiceRef: typeof logicalDayService === "undefined" ? null : logicalDayService
        backupServiceRef: typeof backupService === "undefined" ? null : backupService
        goalServiceRef: typeof goalService === "undefined" ? null : goalService
        phaseSoundServiceRef: typeof phaseSoundService === "undefined" ? null : phaseSoundService
        // qmllint enable unqualified
    }

    onClosing: function(close) {
        // 数据库备份/恢复尚未结束时禁止关闭或退出，避免线程被销毁在原子替换中途。
        // qmllint disable unqualified
        if (typeof backupService !== "undefined" && backupService && backupService.busy) {
            close.accepted = false
            mainContent.showToast((backupService.operationText || "数据操作正在进行")
                                  + "，完成后再关闭")
            return
        }
        // qmllint enable unqualified
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

        function onQuitRequested() {
            // qmllint disable unqualified
            if (typeof backupService !== "undefined" && backupService && backupService.busy) {
                root.show()
                root.raise()
                root.requestActivate()
                mainContent.showToast((backupService.operationText || "数据操作正在进行")
                                      + "，完成后再退出")
                return
            }
            // qmllint enable unqualified
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

    Connections {
        target: mainContent

        function onFocusImmersiveActiveChanged() {
            root.visibility = immersionSync.visibilityForImmersiveChange(
                        mainContent.focusImmersiveActive, root.visibility)
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
