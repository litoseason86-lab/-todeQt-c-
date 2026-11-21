import QtQuick
import QtQuick.Controls
import ".."
import "../components"

// 手机的应用入口窗口：只装随身伴侣页，外加阶段完成提醒与提示条。
// 平板与桌面仍载入 main.qml 的完整界面；选哪一个由 main.cpp 在启动时按屏幕尺寸决定。
ApplicationWindow {
    id: root
    objectName: "companionMainWindow"

    // 输入框字色等调色板与完整界面同一来源，夜间主题下输入内容才看得清。
    palette.text: Theme.inputInk
    palette.placeholderText: Theme.inputPlaceholderInk
    palette.highlight: Theme.inputSelection
    palette.highlightedText: Theme.inputSelectedInk
    palette.base: Theme.controlSurface
    palette.button: Theme.controlSurface
    palette.buttonText: Theme.controlInk
    palette.windowText: Theme.controlInk

    visible: true
    width: 390
    height: 844
    title: qsTr("番茄Todo")
    color: Theme.surface
    // 延伸到状态栏与底部横条之下：壁纸铺满整屏，内容按 SafeArea 让开系统区域。
    flags: Qt.Window | Qt.ExpandedClientAreaHint

    // qmllint disable unqualified
    property var taskManagerRef: typeof taskManager === "undefined" ? null : taskManager
    property var focusTimerRef: typeof focusTimer === "undefined" ? null : focusTimer
    property var appSettingsRef: typeof appSettings === "undefined" ? null : appSettings
    property var logicalDayServiceRef: typeof logicalDayService === "undefined" ? null : logicalDayService
    property var backupServiceRef: typeof backupService === "undefined" ? null : backupService
    // qmllint enable unqualified

    // 主题令牌与完整界面同一来源：壁纸主题决定明暗，「减少透明度」「减少动效」照常生效。
    Binding {
        target: Theme
        property: "activeThemeId"
        value: root.appSettingsRef && root.appSettingsRef.backgroundTheme
               ? Theme.migrateThemeId(root.appSettingsRef.backgroundTheme) : "warm"
    }

    Binding {
        target: Theme
        property: "glassBlurAllowed"
        value: root.appSettingsRef ? !root.appSettingsRef.reduceTransparency : true
    }

    Binding {
        target: Theme
        property: "reduceMotion"
        value: root.appSettingsRef ? Boolean(root.appSettingsRef.reduceMotion) : false
    }

    BackgroundWallpaper {
        anchors.fill: parent
        themeId: root.appSettingsRef && root.appSettingsRef.backgroundTheme
                 ? Theme.migrateThemeId(root.appSettingsRef.backgroundTheme) : "warm"
    }

    CompanionWindow {
        id: companion

        anchors.fill: parent
        // 系统区域（刘海、状态栏、底部横条）之外再留出页边距。
        anchors.topMargin: parent.SafeArea.margins.top + Theme.space12
        anchors.bottomMargin: parent.SafeArea.margins.bottom + Theme.space12
        anchors.leftMargin: parent.SafeArea.margins.left + Theme.space16
        anchors.rightMargin: parent.SafeArea.margins.right + Theme.space16
        // 上下文属性只在入口解包，伴侣页内部只用显式引用。
        taskManagerRef: root.taskManagerRef
        focusTimerRef: root.focusTimerRef
        appSettingsRef: root.appSettingsRef
        logicalDayServiceRef: root.logicalDayServiceRef

        onToastRequested: function (message) { toast.show(message) }
    }

    Toast {
        id: toast
        objectName: "companionToast"

        z: 100
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.space32 + parent.SafeArea.margins.bottom
    }

    // 到点置前窗口：与完整界面共用同一个协调器。系统通知、长休息文案与提示音兜底在 C++ PhaseCompletionNotifier，
    // main.cpp 装配，伴侣页同样生效。
    PhaseCompletionCoordinator {
        windowRef: root
        focusTimerRef: root.focusTimerRef
        settingsRef: root.appSettingsRef
    }

    Connections {
        target: root.focusTimerRef
        ignoreUnknownSignals: true

        // 离开期间到点、回来才结算：说明发生了什么，不自动开始下一阶段。
        function onPhaseSettledOffline(phase) {
            toast.show(phase === 1 ? qsTr("离开期间番茄已到点，已记为完成")
                                   : qsTr("离开期间休息已结束"))
        }

        function onSessionDiscarded(duration) {
            if (companion.endingFocusForCompletion)
                return
            toast.show(qsTr("专注不足 3 分钟，没有计入记录"))
        }

        function onOperationFailed(message) {
            if (!companion.timerFailureCall) toast.show(message)
        }

        // 番茄专注结束自动完成任务失败时，与桌面端同口径提示用户手动核查。
        function onTaskAutoCompleteFailed(taskId) {
            toast.show(qsTr("专注记录已保存，但任务自动完成失败，请手动检查"))
        }
    }

    Loader {
        id: companionBackupOverlayLoader
        objectName: "companionBackupOverlayLoader"

        anchors.fill: parent
        z: 10000
        active: Boolean(root.backupServiceRef && root.backupServiceRef.operationBlocksUi)

        sourceComponent: Component {
            BackupOperationOverlay {
                // qmllint disable unqualified
                message: root.backupServiceRef ? String(root.backupServiceRef.operationText || "") : ""
                // qmllint enable unqualified
                reduceMotion: Theme.reduceMotion
            }
        }
    }

    Connections {
        // qmllint disable unqualified
        target: typeof phaseAlarmCoordinator === "undefined" ? null : phaseAlarmCoordinator
        // qmllint enable unqualified
        ignoreUnknownSignals: true

        // 到点提醒没能交给系统预约：离开应用后不会有任何提醒，必须在前台说清楚。
        function onAlarmUnavailable(reason) {
            toast.show(qsTr("到点提醒没有预约成功（%1），离开应用后不会提醒").arg(reason))
        }
    }

    Connections {
        // qmllint disable unqualified
        target: typeof notificationService === "undefined" ? null : notificationService
        // qmllint enable unqualified
        ignoreUnknownSignals: true

        // 手机上没有提示音后端，系统通知又发不出去时只能靠前台提示条。
        function onNotificationDeliveryFailed(reason) {
            toast.show(qsTr("系统通知没有发出（%1）").arg(reason))
        }
    }
}
