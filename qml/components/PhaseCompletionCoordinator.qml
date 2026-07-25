import QtQuick

// 阶段完成协调器：集中处理置前、长休息文案、静默系统通知和本地提示音降级。
Item {
    id: root

    required property var windowRef
    required property var focusTimerRef
    property var settingsRef: null
    property var notificationServiceRef: null
    property var phaseSoundServiceRef: null
    property bool activeBreakWasLong: false

    visible: false

    function longBreakDue() {
        return root.settingsRef
                && root.settingsRef.longBreakEnabled
                && root.settingsRef.longBreakInterval > 0
                && root.focusTimerRef.completedPomodoros > 0
                && (root.focusTimerRef.completedPomodoros
                    % root.settingsRef.longBreakInterval) === 0
    }

    function captureActiveBreakKind() {
        if (!root.settingsRef || root.focusTimerRef.phase !== 2)
            return
        root.activeBreakWasLong = root.settingsRef.longBreakEnabled
                && root.focusTimerRef.targetSeconds
                   === Number(root.settingsRef.longBreakMinutes) * 60
    }

    function playFallbackSound() {
        if ((!root.settingsRef || root.settingsRef.soundEnabled)
                && root.phaseSoundServiceRef) {
            root.phaseSoundServiceRef.playPhaseCompleteChime()
        }
    }

    Component.onCompleted: captureActiveBreakKind()

    Connections {
        target: root.focusTimerRef

        function onPhaseChanged() {
            root.captureActiveBreakKind()
        }

        function onPhaseCompleted(phase) {
            if (!root.settingsRef || root.settingsRef.raiseOnPhaseComplete) {
                root.windowRef.raise()
                root.windowRef.requestActivate()
            }

            var isLongBreak = phase === 1
                    ? root.longBreakDue() : root.activeBreakWasLong
            var breakMinutes = 0
            if (phase === 1 && root.settingsRef) {
                breakMinutes = isLongBreak
                        ? root.settingsRef.longBreakMinutes
                        : root.settingsRef.breakMinutes
            }
            var playSound = !root.settingsRef || root.settingsRef.soundEnabled

            if (root.notificationServiceRef) {
                root.notificationServiceRef.notifyPhaseComplete(
                            phase,
                            root.focusTimerRef.completedPomodoros,
                            breakMinutes,
                            isLongBreak,
                            playSound)
            } else {
                root.playFallbackSound()
            }

            if (phase === 2)
                root.activeBreakWasLong = false
        }
    }

    Connections {
        target: root.notificationServiceRef
        ignoreUnknownSignals: true

        function onNotificationDeliveryFailed(reason) {
            root.playFallbackSound()
        }
    }
}
