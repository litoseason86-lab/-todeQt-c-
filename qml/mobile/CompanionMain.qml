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

    // 主题令牌与完整界面同一来源：壁纸主题决定明暗，「减少透明度」「减少动效」照常生效。
    Binding {
        target: Theme
        property: "activeThemeId"
        // qmllint disable unqualified
        value: typeof appSettings !== "undefined" && appSettings
               ? Theme.migrateThemeId(appSettings.backgroundTheme) : "warm"
        // qmllint enable unqualified
    }

    Binding {
        target: Theme
        property: "glassBlurAllowed"
        // qmllint disable unqualified
        value: typeof appSettings !== "undefined" && appSettings ? !appSettings.reduceTransparency : true
        // qmllint enable unqualified
    }

    Binding {
        target: Theme
        property: "reduceMotion"
        // qmllint disable unqualified
        value: typeof appSettings !== "undefined" && appSettings ? Boolean(appSettings.reduceMotion) : false
        // qmllint enable unqualified
    }

    BackgroundWallpaper {
        anchors.fill: parent
        // qmllint disable unqualified
        themeId: typeof appSettings !== "undefined" && appSettings
                 ? Theme.migrateThemeId(appSettings.backgroundTheme) : "warm"
        // qmllint enable unqualified
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
        // qmllint disable unqualified
        taskManagerRef: typeof taskManager === "undefined" ? null : taskManager
        focusTimerRef: typeof focusTimer === "undefined" ? null : focusTimer
        appSettingsRef: typeof appSettings === "undefined" ? null : appSettings
        logicalDayServiceRef: typeof logicalDayService === "undefined" ? null : logicalDayService
        // qmllint enable unqualified

        onToastRequested: function (message) { toast.show(message) }
    }

    Toast {
        id: toast

        z: 100
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.space32 + parent.SafeArea.margins.bottom
    }

    // 到点提醒：与完整界面共用同一个协调器（系统通知、长休息文案、提示音降级）。
    PhaseCompletionCoordinator {
        windowRef: root
        // qmllint disable unqualified
        focusTimerRef: focusTimer
        settingsRef: typeof appSettings === "undefined" ? null : appSettings
        notificationServiceRef: typeof notificationService === "undefined" ? null : notificationService
        phaseSoundServiceRef: typeof phaseSoundService === "undefined" ? null : phaseSoundService
        // qmllint enable unqualified
    }

    Connections {
        // qmllint disable unqualified
        target: typeof focusTimer === "undefined" ? null : focusTimer
        // qmllint enable unqualified
        ignoreUnknownSignals: true

        // 离开期间到点、回来才结算：说明发生了什么，不自动开始下一阶段。
        function onPhaseSettledOffline(phase) {
            toast.show(phase === 1 ? qsTr("离开期间番茄已到点，已记为完成")
                                   : qsTr("离开期间休息已结束"))
        }

        function onSessionDiscarded(duration) {
            toast.show(qsTr("专注不足 3 分钟，没有计入记录"))
        }

        function onOperationFailed(message) {
            toast.show(message)
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
