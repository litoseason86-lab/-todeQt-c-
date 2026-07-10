import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "ImmersionWindowSync"

    ImmersionWindowSync {
        id: sync
    }

    function init() {
        sync.preImmersiveVisibility = Window.Windowed
        sync.enteringFullScreen = false
    }

    function test_enterFromWindowedRequestsFullScreen() {
        const target = sync.visibilityForImmersiveChange(true, Window.Windowed)
        compare(target, Window.FullScreen)
        compare(sync.preImmersiveVisibility, Window.Windowed)
        compare(sync.enteringFullScreen, true)
    }

    function test_fullScreenObservationClearsGuardAndKeepsActive() {
        sync.visibilityForImmersiveChange(true, Window.Windowed)
        compare(sync.immersiveActiveAfterVisibilityChange(Window.FullScreen, true), true)
        compare(sync.enteringFullScreen, false)
    }

    function test_systemExitDeactivatesAfterGuardCleared() {
        sync.visibilityForImmersiveChange(true, Window.Windowed)
        sync.immersiveActiveAfterVisibilityChange(Window.FullScreen, true)

        compare(sync.immersiveActiveAfterVisibilityChange(Window.Windowed, true), false)
    }

    function test_guardIgnoresIntermediateStatesDuringEntry() {
        sync.visibilityForImmersiveChange(true, Window.Maximized)

        // 进入过渡中吐出的中间 Windowed 不判为系统退出。
        compare(sync.immersiveActiveAfterVisibilityChange(Window.Windowed, true), true)
        compare(sync.immersiveActiveAfterVisibilityChange(Window.FullScreen, true), true)
        compare(sync.enteringFullScreen, false)
    }

    function test_exitRestoresSavedVisibility() {
        sync.visibilityForImmersiveChange(true, Window.Maximized)
        sync.immersiveActiveAfterVisibilityChange(Window.FullScreen, true)

        compare(sync.visibilityForImmersiveChange(false, Window.FullScreen), Window.Maximized)
        compare(sync.enteringFullScreen, false)
    }

    function test_alreadyFullScreenEntryKeepsFullScreenOnExit() {
        // 用户本来就在原生全屏：进入不挂护栏（无过渡可等），退出保持全屏只收覆盖层。
        const target = sync.visibilityForImmersiveChange(true, Window.FullScreen)
        compare(target, Window.FullScreen)
        compare(sync.enteringFullScreen, false)

        compare(sync.visibilityForImmersiveChange(false, Window.FullScreen), Window.FullScreen)
    }

    function test_cancelBeforeFullScreenRearmsGuard() {
        sync.visibilityForImmersiveChange(true, Window.Windowed)
        compare(sync.enteringFullScreen, true)

        // 过渡完成前用户已 Esc 退出：护栏必须复位，否则后续系统退出检测永久失效。
        sync.visibilityForImmersiveChange(false, Window.Windowed)
        compare(sync.enteringFullScreen, false)
        compare(sync.immersiveActiveAfterVisibilityChange(Window.Windowed, false), false)
    }
}
