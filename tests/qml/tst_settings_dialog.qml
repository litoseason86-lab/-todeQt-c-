import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase

    name: "SettingsDialog"
    when: windowShown
    width: 1000
    height: 760

    Component {
        id: signalSpyComponent

        SignalSpy {}
    }

    QtObject {
        id: appSettingsMock

        property string backgroundTheme: "warm"
        property bool soundEnabled: true
        property bool reduceMotion: false
        property bool slimClockFont: true
        property bool reduceTransparency: false
        property bool sidebarVisible: true
        property bool raiseOnPhaseComplete: true
        property bool autoStartBreak: false
        property bool autoStartNextPomodoro: false
        property bool longBreakEnabled: true
        property int longBreakMinutes: 15
        property int longBreakInterval: 4
        property int dayStartHour: 4
        property string nickname: ""
        property int workMinutes: 25
        property int breakMinutes: 5
        signal settingsWriteSucceeded(string key)
        signal settingsWriteFailed(string key, string message)
    }

    SettingsDialog {
        id: dialog

        appSettingsRef: appSettingsMock
    }

    function init() {
        appSettingsMock.reduceMotion = false
        appSettingsMock.nickname = ""
        dialog.close()
        dialog.currentSection = 0
        dialog.statusIsError = false
        dialog.statusText = "设置将自动保存到本机"
        wait(20)
    }

    function test_shellUsesSixCategoryNavigation() {
        dialog.open()
        tryCompare(dialog, "opened", true)
        // 820×680：原来的 760×640 让专注/快捷键/数据三页的内容被页脚硬切。
        compare(dialog.width, 820)
        verify(dialog.height <= 680)
        // 页脚分隔线让"内容还能往下滚"成为版式事实，而不是看起来像渲染缺陷。
        verify(findChild(dialog, "settingsFooterDivider"))
        // 标题显示当前分页名而不是固定的「设置」，承担 wayfinding。
        var title = findChild(dialog, "settingsSectionTitle")
        verify(title)
        compare(title.text, dialog.sectionTitles[dialog.currentSection])

        var navigation = findChild(dialog, "settingsNavigation")
        verify(navigation)
        // 外观 / 专注 / 通用 / 快捷键 / 数据与管理 / 关于
        compare(findChild(navigation, "settingsCategoryRepeater").count, 6)
        compare(dialog.sectionTitles.length, 6)
        // ⌘/「快捷键速查」靠这个索引直达；它必须真的指向快捷键页，
        // 否则以后插入分段时会静默跳到隔壁页面。
        compare(dialog.sectionTitles[dialog.shortcutSectionIndex], "快捷键")
        verify(findChild(dialog, "settingsStatusText"))
        verify(findChild(dialog, "settingsCloseButton"))
    }

    function test_sectionChangeCommitsNicknameDraft() {
        dialog.open()
        tryCompare(dialog, "opened", true)
        dialog.requestSection(2)

        var pageLoader = findChild(dialog, "settingsPageLoader")
        verify(pageLoader)
        tryCompare(pageLoader, "status", Loader.Ready)
        var field = findChild(pageLoader.item, "settingsNicknameField")
        verify(field)
        field.text = "  小番茄  "
        pageLoader.item.nicknameDraft = field.text

        dialog.requestSection(0)
        compare(appSettingsMock.nickname, "小番茄")
        compare(dialog.currentSection, 0)
    }

    function test_categoryButtonIsKeyboardFocusable() {
        dialog.open()
        tryCompare(dialog, "opened", true)

        var navigation = findChild(dialog, "settingsNavigation")
        verify(navigation)
        var focusButton = findChild(navigation, "settingsCategoryFocus")
        verify(focusButton)
        verify(focusButton.activeFocusOnTab)
        focusButton.forceActiveFocus()
        keyClick(Qt.Key_Return)
        compare(dialog.currentSection, 1)
    }

    function test_dialogRespectsSmallWindowMargins() {
        testCase.width = 860
        testCase.height = 620
        dialog.open()
        tryCompare(dialog, "opened", true)

        verify(dialog.width <= testCase.width - 64)
        verify(dialog.height <= testCase.height - 64)

        testCase.width = 1000
        testCase.height = 760
    }

    function test_dataActionClosesDialogAndForwardsSignal() {
        var routineSpy = createTemporaryObject(signalSpyComponent, testCase, {
            target: dialog,
            signalName: "routineRequested"
        })
        verify(routineSpy)

        dialog.open()
        tryCompare(dialog, "opened", true)
        // 「数据与管理」在快捷键页插入后后移了一位；索引写死会随分段增减漂移。
        var dataSection = dialog.sectionTitles.indexOf("数据与管理")
        dialog.requestSection(dataSection)
        compare(dialog.currentSection, dataSection)

        var pageLoader = findChild(dialog, "settingsPageLoader")
        verify(pageLoader)
        tryCompare(pageLoader, "status", Loader.Ready)
        var routineButton = findChild(pageLoader.item, "settingsManageRoutine")
        verify(routineButton)
        routineButton.click()

        compare(routineSpy.count, 1)
        tryCompare(dialog, "opened", false)
    }

    function test_writeFailureStaysVisibleUntilSuccess() {
        dialog.open()
        tryCompare(dialog, "opened", true)
        appSettingsMock.settingsWriteFailed("appearance/reduceMotion", "设置文件不可写")

        var status = findChild(dialog, "settingsStatusText")
        verify(status)
        compare(status.text, "无法保存设置，请检查系统权限后重试")
        verify(status.visible)
        verify(dialog.statusIsError)

        appSettingsMock.settingsWriteSucceeded("appearance/reduceMotion")
        compare(status.text, "所有设置已保存到本机")
        verify(!dialog.statusIsError)
    }

    function test_controlsMeetMinimumTarget() {
        dialog.open()
        tryCompare(dialog, "opened", true)
        var navigation = findChild(dialog, "settingsNavigation")
        verify(navigation)
        verify(findChild(dialog, "settingsCloseButton").implicitHeight >= 44)
        verify(findChild(navigation, "settingsCategoryAppearance").implicitHeight >= 44)
    }

    function test_reduceMotionStopsDialogAndNavigationAnimations() {
        appSettingsMock.reduceMotion = true
        dialog.open()
        tryCompare(dialog, "opened", true)
        compare(dialog.animationDuration, 0)
        var navigation = findChild(dialog, "settingsNavigation")
        verify(navigation)
        compare(navigation.animationDuration, 0)
        appSettingsMock.reduceMotion = false
    }

    function test_keyboardFocusScrollsLongPageIntoViewAndSectionResets() {
        dialog.open()
        tryCompare(dialog, "opened", true)
        dialog.requestSection(1)

        var pageLoader = findChild(dialog, "settingsPageLoader")
        var pageScroll = findChild(dialog, "settingsPageScroll")
        verify(pageLoader)
        verify(pageScroll)
        tryCompare(pageLoader, "status", Loader.Ready)

        var bottomSwitch = findChild(pageLoader.item, "settingsRaiseOnPhaseSwitch")
        verify(bottomSwitch)
        bottomSwitch.forceActiveFocus()
        tryVerify(function() { return pageScroll.contentItem.contentY > 0 })

        dialog.requestSection(0)
        tryCompare(pageScroll.contentItem, "contentY", 0)
    }
}
