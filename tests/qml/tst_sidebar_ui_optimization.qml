import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

TestCase {
    id: testCase
    name: "SidebarUiOptimization"
    when: windowShown
    width: 260
    height: 520

    QtObject {
        id: focusTimerMock

        property bool isRunning: false
        property bool hasActiveSession: false
        property int mode: 0
        property int phase: 0
        property int remainingSeconds: 0
        property int elapsedSeconds: 0
    }

    Sidebar {
        id: sidebar

        width: 208
        height: 520
        currentView: "today"
        focusTimerRef: focusTimerMock
    }

    SignalSpy {
        id: settingsSpy

        target: sidebar
        signalName: "settingsRequested"
    }

    function collectChildren(item, result) {
        if (!item || !item.children) {
            return result;
        }

        for (var i = 0; i < item.children.length; ++i) {
            var child = item.children[i];
            result.push(child);
            collectChildren(child, result);
        }

        return result;
    }

    function findText(value) {
        var children = collectChildren(sidebar, []);
        for (var i = 0; i < children.length; ++i) {
            if (children[i].text === value && children[i].font !== undefined) {
                return children[i];
            }
        }
        return null;
    }

    function findDivider() {
        var children = collectChildren(sidebar, []);
        for (var i = 0; i < children.length; ++i) {
            if (children[i].height === 1 && Qt.colorEqual(children[i].color, Theme.border)) {
                return children[i];
            }
        }
        return null;
    }

    function sidebarItemForMarker(marker) {
        return findChild(sidebar, "sidebarItem-" + marker);
    }

    function markerContainerFor(marker) {
        return findChild(sidebar, "sidebarMarker-" + marker);
    }

    function test_glassSurface() {
        verify(Qt.colorEqual(sidebar.color, Theme.glassSidebar), "侧栏底色应为玻璃令牌")
        verify(!sidebar.gradient, "侧栏渐变应已移除")
    }

    function test_itemIdleIsWhiteBasedTransparent() {
        verify(sidebar.sidebarItemIdleColor.a < 0.01, "idle 底色应全透明")
        verify(sidebar.sidebarItemIdleColor.r > 0.99, "idle 底色必须白基")
        verify(sidebar.sidebarItemIdleBorderColor.a < 0.01, "idle 边框应全透明")
        verify(Qt.colorEqual(sidebar.sidebarItemHoverColor, Qt.rgba(1, 1, 1, 0.45)), "hover 应为半透明白")
    }

    function test_settingsEntryEmitsSignal() {
        var item = findChild(sidebar, "sidebarItem-设")
        verify(item, "设置条目应存在")
        settingsSpy.clear()
        item.clicked()
        compare(settingsSpy.count, 1)
    }

    function test_titleAndGroupFontWeightsUseFontWeight() {
        var title = findText("番茄Todo");
        var groupTitle = findText("时间视图");

        verify(title !== null);
        verify(groupTitle !== null);
        compare(title.font.pixelSize, Theme.fontXl);
        compare(title.font.weight, Font.Bold);
        verify(Qt.colorEqual(title.color, Theme.ink));
        compare(groupTitle.font.pixelSize, Theme.fontSm);
        compare(groupTitle.font.weight, Font.Bold);
        verify(Qt.colorEqual(groupTitle.color, Theme.inkSoft));
    }

    function test_activeSidebarItemHasVisualFeedback() {
        var activeItem = sidebarItemForMarker("今");
        var markerContainer = markerContainerFor("今");
        var markerText = findText("今");
        var mainText = findText("今日任务");

        verify(activeItem !== null);
        verify(markerContainer !== null);
        verify(Qt.colorEqual(activeItem.color, Theme.accentSoft));
        verify(Qt.colorEqual(activeItem.border.color, Theme.accent));
        compare(activeItem.border.width, 1);
        compare(activeItem.radius, Theme.radiusMd);
        compare(activeItem.height, 44);
        compare(activeItem.opacity, 1.0);
        compare(activeItem.layer.enabled, false);

        compare(markerContainer.width, 22);
        compare(markerContainer.height, 22);
        compare(markerContainer.radius, Theme.radiusSm);
        verify(Qt.colorEqual(markerContainer.color, Theme.accent));
        compare(markerText.font.pixelSize, Theme.fontSm);
        compare(markerText.font.weight, Font.Bold);
        verify(Qt.colorEqual(markerText.color, Theme.surface));

        compare(mainText.font.pixelSize, Theme.fontLg);
        compare(mainText.font.weight, Font.Medium);
        verify(Qt.colorEqual(mainText.color, Theme.ink));
        compare(mainText.elide, Text.ElideRight);
    }

    function test_inactiveSidebarItemUsesNeutralMarkerAndText() {
        var inactiveItem = sidebarItemForMarker("专");
        var markerContainer = markerContainerFor("专");
        var markerText = findText("专");
        var mainText = findText("专注计时");

        verify(inactiveItem !== null);
        verify(markerContainer !== null);
        verify(Qt.colorEqual(inactiveItem.color, sidebar.sidebarItemIdleColor));
        verify(inactiveItem.color.a < 0.01);
        verify(Qt.colorEqual(inactiveItem.border.color, sidebar.sidebarItemIdleBorderColor));
        verify(inactiveItem.border.color.a < 0.01);
        compare(inactiveItem.border.width, 0);
        compare(inactiveItem.layer.enabled, false);
        verify(Qt.colorEqual(markerContainer.color, Theme.border));
        compare(markerText.font.weight, Font.Bold);
        verify(Qt.colorEqual(markerText.color, Theme.inkSoft));
        compare(mainText.font.weight, Font.Normal);
        verify(Qt.colorEqual(mainText.color, Theme.inkSoft));
    }

    function test_hoverSidebarItemRespondsWithoutShadowWhilePointerStaysInside() {
        var inactiveItem = sidebarItemForMarker("月");

        verify(inactiveItem !== null);
        // QtTest 在 macOS 上不稳定触发真实 hover，这里直接验证组件内部悬停状态。
        inactiveItem.setPointerInside(true);
        tryCompare(inactiveItem, "visualHovered", true, 500);
        wait(1200);

        verify(Qt.colorEqual(inactiveItem.color, sidebar.sidebarItemHoverColor));
        verify(Qt.colorEqual(inactiveItem.border.color, Theme.border));
        compare(inactiveItem.layer.enabled, false);
    }

    function test_hoverExitReturnsToSolidWarmBackgroundWithoutGrayFlash() {
        var inactiveItem = sidebarItemForMarker("数");

        verify(inactiveItem !== null);
        inactiveItem.setPointerInside(true);
        tryCompare(inactiveItem, "visualHovered", true, 500);
        inactiveItem.setPointerInside(false);
        tryCompare(inactiveItem, "visualHovered", false, 500);
        wait(1200);

        // 退场目标色必须是白基透明，不用 Qt 的黑基 transparent，避免 hover 动画插出灰闪。
        verify(Qt.colorEqual(inactiveItem.color, sidebar.sidebarItemIdleColor));
        verify(inactiveItem.color.a < 0.01);
        verify(Qt.colorEqual(inactiveItem.border.color, sidebar.sidebarItemIdleBorderColor));
        verify(inactiveItem.border.color.a < 0.01);
        compare(inactiveItem.border.width, 0);
    }

    function test_dividerAndVersionStyles() {
        var divider = findDivider();
        var version = findText("三阶段");

        verify(divider !== null);
        compare(divider.height, 1);
        verify(Qt.colorEqual(divider.color, Theme.border));
        compare(divider.opacity, 0.8);

        verify(version !== null);
        compare(version.font.pixelSize, Theme.fontSm);
        compare(version.font.weight, Font.Normal);
        verify(Qt.colorEqual(version.color, Theme.inkMuted));
        compare(version.opacity, 0.7);
    }

    function test_focusStatusShowsPomodoroCountdown() {
        focusTimerMock.hasActiveSession = true;
        focusTimerMock.isRunning = true;
        focusTimerMock.mode = 1;
        focusTimerMock.phase = 1;
        focusTimerMock.remainingSeconds = 932;
        wait(20);

        const status = findChild(sidebar, "sidebarStatus-专");
        verify(status);
        compare(status.text, "15:32");

        const pulse = findChild(sidebar, "sidebarStatusPulse-专");
        verify(pulse);
        compare(pulse.text, "●");
        verify(pulse.pulseRunning);
    }

    function test_focusStatusShowsFreeElapsedAndPause() {
        focusTimerMock.hasActiveSession = true;
        focusTimerMock.isRunning = false;
        focusTimerMock.mode = 0;
        focusTimerMock.phase = 0;
        focusTimerMock.elapsedSeconds = 1934;
        wait(20);

        const status = findChild(sidebar, "sidebarStatus-专");
        verify(status);
        compare(status.text, "00:32:14");

        const pause = findChild(sidebar, "sidebarStatusPulse-专");
        verify(pause);
        compare(pause.text, "⏸");
        compare(pause.pulseRunning, false);
    }

    function test_focusStatusEmptyWhenIdle() {
        focusTimerMock.hasActiveSession = false;
        focusTimerMock.isRunning = false;
        focusTimerMock.mode = 0;
        focusTimerMock.phase = 0;
        wait(20);

        const status = findChild(sidebar, "sidebarStatus-专");
        verify(status);
        compare(status.text, "");

        const pulse = findChild(sidebar, "sidebarStatusPulse-专");
        verify(pulse);
        compare(pulse.text, "");
        compare(pulse.pulseRunning, false);
    }
}
