import QtQuick
import QtTest
import "../../qml/components"
import "../../qml"

TestCase {
    id: testCase
    name: "SidebarUiOptimization"
    when: windowShown
    visible: true
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
            // 用 textFormat 认 Text，不用 font：侧栏条目根是 Control，本身就带 text 和 font，
            // 按 font 判断会把整条条目当成它里面的那行字。
            if (children[i].text === value && children[i].textFormat !== undefined) {
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

    function test_keyboardCanActivateSidebar() {
        var item = sidebarItemForMarker("设")
        verify(item.activeFocusOnTab)
        item.forceActiveFocus()
        tryCompare(item, "activeFocus", true)
        settingsSpy.clear()
        keyClick(Qt.Key_Return)
        compare(settingsSpy.count, 1)
        keyClick(Qt.Key_Space)
        compare(settingsSpy.count, 2)
    }

    SignalSpy {
        id: itemClickedSpy

        target: sidebar
        signalName: "itemClicked"
    }

    function test_focusComingBackWithoutKeyboardDoesNotShowRing() {
        // 用户截图里的 bug：鼠标点过「今日任务」后切到专注计时，切走应用再切回来时
        // 焦点被还给那一项。旧实现只看 activeFocus，于是它亮起焦点环，
        // 和当前选中项一起在侧栏出现两个框。
        var item = sidebarItemForMarker("今")
        var other = sidebarItemForMarker("专")

        item.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(item, "showFocusRing", true)

        // 窗口重新激活：焦点回到原来那一项，但这不是键盘导航。
        other.forceActiveFocus(Qt.MouseFocusReason)
        item.forceActiveFocus(Qt.ActiveWindowFocusReason)
        tryCompare(item, "activeFocus", true)
        compare(item.showFocusRing, false)

        // 弹窗关闭把焦点还回来，同样不该画环。
        other.forceActiveFocus(Qt.MouseFocusReason)
        item.forceActiveFocus(Qt.PopupFocusReason)
        tryCompare(item, "activeFocus", true)
        compare(item.showFocusRing, false)
    }

    function test_focusRingOnlyAppearsForKeyboardFocus() {
        var item = sidebarItemForMarker("今")
        // 先把焦点移到别处：对已经有焦点的项再调 forceActiveFocus 不会重新派发焦点事件，
        // 焦点原因还停在上一次，测到的就不是「Tab 进来」这条路径。
        sidebarItemForMarker("设").forceActiveFocus(Qt.MouseFocusReason)
        // Tab 把焦点送进来才画焦点环。
        item.forceActiveFocus(Qt.TabFocusReason)
        tryCompare(item, "showFocusRing", true)
        // 直接触发命中区的 clicked：本文件的测试窗口没有显示，收不到真实鼠标事件。
        // 鼠标点击同样会取焦点（Tab 要能从当前项继续），但不该留下焦点环。
        itemClickedSpy.clear()
        findChild(sidebar, "sidebarHitArea-今").clicked(null)
        compare(itemClickedSpy.count, 1)
        compare(item.showFocusRing, false)
        compare(item.activeFocus, true)
    }

    function test_settingsEntryEmitsSignal() {
        var item = findChild(sidebar, "sidebarItem-设")
        verify(item, "设置条目应存在")
        settingsSpy.clear()
        item.clicked()
        compare(settingsSpy.count, 1)
    }

    SignalSpy {
        id: collapseSpy
        target: sidebar
        signalName: "collapseRequested"
    }

    function test_collapseButtonEmitsCollapseRequested() {
        var btn = findChild(sidebar, "sidebarCollapseButton")
        verify(btn !== null, "应有 Apple 风格收起按钮")
        // AbstractButton 自身即命中区，不单设 MouseArea；校验尺寸达到桌面指针可点标准。
        verify(btn.enabled, "收起钮应可点击")
        verify(btn.implicitWidth >= 30 && btn.implicitHeight >= 30, "命中区应足够大")
        compare(btn.Accessible.name, "隐藏侧栏")
        // 触发按钮自身的 clicked 信号，校验到 collapseRequested 的完整接线。
        collapseSpy.clear()
        btn.clicked()
        compare(collapseSpy.count, 1)
    }

    function test_titleTypographyUsesFontWeight() {
        var title = findText("番茄Todo");

        verify(title !== null);
        compare(title.font.pixelSize, Theme.fontXl);
        compare(title.font.weight, Font.Bold);
        verify(Qt.colorEqual(title.color, Theme.ink));

        // 「时间视图」分组标题已随可排序侧栏一起去掉：顺序交给用户之后，
        // 固定的语义分组就不再成立——用户可以把「课表」排到「今日任务」前面。
        verify(findText("时间视图") === null, "分组标题应已随可排序侧栏移除");
    }

    function test_activeSidebarItemHasVisualFeedback() {
        var activeItem = sidebarItemForMarker("今");
        var markerContainer = markerContainerFor("今");
        var markerText = findText("今");
        var mainText = findText("今日任务");

        verify(activeItem !== null);
        verify(markerContainer !== null);
        verify(Qt.colorEqual(activeItem.color, Theme.glassAccent));
        verify(Qt.colorEqual(activeItem.border.color, Theme.accent));
        compare(activeItem.border.width, 1);
        compare(activeItem.radius, Theme.radiusMd);
        compare(activeItem.height, 44);
        compare(activeItem.opacity, 1.0);
        compare(activeItem.layer.enabled, false);

        compare(markerContainer.width, 22);
        compare(markerContainer.height, 22);
        compare(markerContainer.radius, Theme.radiusSm);
        verify(Qt.colorEqual(markerContainer.color, Theme.accentFill));
        compare(markerText.font.pixelSize, Theme.fontSm);
        compare(markerText.font.weight, Font.Bold);
        verify(Qt.colorEqual(markerText.color, Theme.accentFillInk));

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
        verify(Qt.colorEqual(markerContainer.color, Theme.glassCard));
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
        tryCompare(inactiveItem, "visualHovered", true, 3000);
        wait(1200);

        verify(Qt.colorEqual(inactiveItem.color, sidebar.sidebarItemHoverColor));
        verify(Qt.colorEqual(inactiveItem.border.color, Theme.border));
        compare(inactiveItem.layer.enabled, false);
    }

    function test_hoverExitReturnsToSolidWarmBackgroundWithoutGrayFlash() {
        var inactiveItem = sidebarItemForMarker("数");

        verify(inactiveItem !== null);
        inactiveItem.setPointerInside(true);
        tryCompare(inactiveItem, "visualHovered", true, 3000);
        inactiveItem.setPointerInside(false);
        tryCompare(inactiveItem, "visualHovered", false, 3000);
        wait(1200);

        // 退场目标色必须是白基透明，不用 Qt 的黑基 transparent，避免 hover 动画插出灰闪。
        verify(Qt.colorEqual(inactiveItem.color, sidebar.sidebarItemIdleColor));
        verify(inactiveItem.color.a < 0.01);
        verify(Qt.colorEqual(inactiveItem.border.color, sidebar.sidebarItemIdleBorderColor));
        verify(inactiveItem.border.color.a < 0.01);
        compare(inactiveItem.border.width, 0);
    }

    function test_managementEntriesStayOutOfSidebar() {
        // 原来这条还断言两组之间那根分隔线的样式。顺序可由用户重排之后，
        // 分组本身没了，线也就跟着去掉；保留的是这条真正在守的东西——
        // 管理类入口不许回流到侧栏。
        verify(findText("三阶段") === null, "三阶段标签应已删除");
        verify(findChild(sidebar, "sidebarItem-例") === null, "每日例行应已移出侧栏");
        verify(findChild(sidebar, "sidebarItem-科") === null, "科目管理应已移出侧栏");
        verify(findChild(sidebar, "sidebarItem-导") === null, "数据导出应已移出侧栏");
        verify(findChild(sidebar, "sidebarItem-设") !== null, "设置项应保留");
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

    function test_pulseGatedByReduceMotion() {
        focusTimerMock.hasActiveSession = true
        focusTimerMock.isRunning = true
        focusTimerMock.mode = 1
        focusTimerMock.phase = 1
        focusTimerMock.remainingSeconds = 300
        wait(20)

        var pulse = findChild(sidebar, "sidebarStatusPulse-专")
        verify(pulse)
        sidebar.reduceMotionActive = false
        verify(pulse.pulseAnimationRunning === true, "常态下状态圆点应脉冲")

        sidebar.reduceMotionActive = true
        verify(pulse.pulseAnimationRunning === false, "减动效下状态圆点应停")
        sidebar.reduceMotionActive = false
        sidebar.visible = false
        verify(!pulse.pulseAnimationRunning, "隐藏侧栏必须停动画")
        sidebar.visible = true
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

    function test_statusTimeUsesClockFamily() {
        var statusText = findChild(sidebar, "sidebarStatus-专")
        verify(statusText)
        compare(statusText.font.family, Theme.fontFamilyClock)
    }
}
