import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml/components"
import "../../qml/components/settings"
import "../../qml"

// 设备间同步的界面（050 阶段 4）：设置「数据与管理」里的同步一节、同步日志弹窗、恢复确认里的同步提醒。
// 控制器用替身：界面只认它的属性和方法，同步本身由 SyncControllerTests 覆盖。
// 按项目约定不断言 visible === true（测试窗口的可见性在这里不可靠），改为断言驱动显示的属性。
TestCase {
    id: testCase

    name: "SettingsSync"
    when: windowShown
    width: 900
    height: 760

    Component {
        id: signalSpyComponent

        SignalSpy {}
    }

    QtObject {
        id: appSettingsMock

        property bool reduceMotion: true
        signal settingsWriteSucceeded(string key)
        signal settingsWriteFailed(string key, string message)
    }

    QtObject {
        id: syncMock

        property bool enabled: false
        property string statusKey: "stopped"
        property bool hasProblem: false
        property string summaryText: "已关闭"
        property string statusText: ""
        property string statusDetail: ""
        property int pendingCount: 0
        property bool busy: false
        property bool choosesFolder: false
        property bool hasFolder: true
        property string folderDisplayPath: "iCloud 云盘/番茄Todo同步"
        property bool choosingFolder: false
        property string folderProblem: ""
        property int logRevision: 0
        property int logCount: 0
        // 打开同步时是否真的打开（iPad 没选文件夹时，打开等于先去选，开关要回到关）。
        property bool acceptsEnable: true
        property var calls: []
        property var entries: []

        signal logChanged()
        signal notice(string message)

        function setEnabled(value) {
            calls.push("setEnabled:" + value)
            if (!value || acceptsEnable)
                enabled = value
        }
        function confirmJoin() { calls.push("confirmJoin") }
        function syncNow() { calls.push("syncNow") }
        function chooseFolder() { calls.push("chooseFolder") }
        function rebuildFolder() { calls.push("rebuildFolder") }
        function syncLog(limit) {
            calls.push("syncLog:" + limit)
            return entries
        }
    }

    SettingsDataPage {
        id: dataPage

        width: 620
        appSettingsRef: appSettingsMock
        syncControllerRef: syncMock
    }

    SyncLogDialog {
        id: logDialog

        parent: testCase
        syncControllerRef: syncMock
    }

    RestoreConfirmDialog {
        id: restoreDialog

        parent: testCase
    }

    SettingsDialog {
        id: settingsDialog

        parent: testCase
        appSettingsRef: appSettingsMock
        syncControllerRef: syncMock
    }

    function init() {
        syncMock.enabled = false
        syncMock.statusKey = "stopped"
        syncMock.hasProblem = false
        syncMock.summaryText = "已关闭"
        syncMock.statusText = ""
        syncMock.statusDetail = ""
        syncMock.pendingCount = 0
        syncMock.busy = false
        syncMock.choosesFolder = false
        syncMock.hasFolder = true
        syncMock.folderDisplayPath = "iCloud 云盘/番茄Todo同步"
        syncMock.choosingFolder = false
        syncMock.folderProblem = ""
        syncMock.logCount = 0
        syncMock.acceptsEnable = true
        syncMock.calls = []
        syncMock.entries = []
        logDialog.close()
        restoreDialog.close()
        settingsDialog.close()
        wait(20)
    }

    function test_switchAsksTheControllerAndShowsOnlyWhatItAccepted() {
        var toggle = findChild(dataPage, "settingsSyncSwitch")
        verify(toggle)
        compare(toggle.checked, false)
        // 控制器接受了：开关显示为开。
        toggle.click()
        compare(syncMock.calls[0], "setEnabled:true")
        tryCompare(toggle, "checked", true)
        toggle.click()
        tryCompare(toggle, "checked", false)

        // iPad 还没选文件夹：控制器转去弹选择器、没有真的打开，开关回到关，不显示成功。
        syncMock.acceptsEnable = false
        toggle.click()
        tryCompare(toggle, "checked", false)
        // 正在选文件夹或校验时不能再点。
        syncMock.choosingFolder = true
        verify(!toggle.enabled)
    }

    function test_explanationAppearsOnlyWhenSomethingNeedsYou() {
        syncMock.enabled = true
        syncMock.statusKey = "upToDate"
        syncMock.summaryText = "已同步 · 18:42"
        verify(!dataPage.syncShowsExplanation)

        // 第一次加入：说明和「确认加入 / 暂不加入」。
        syncMock.statusKey = "needsConfirmation"
        syncMock.statusText = "这台设备第一次加入这个同步文件夹。"
        verify(dataPage.syncShowsExplanation)
        compare(findChild(dataPage, "settingsSyncStatusText").text, "这台设备第一次加入这个同步文件夹。")
        findChild(dataPage, "settingsSyncConfirmJoin").click()
        compare(syncMock.calls[syncMock.calls.length - 1], "confirmJoin")
        findChild(dataPage, "settingsSyncDeclineJoin").click()
        compare(syncMock.calls[syncMock.calls.length - 1], "setEnabled:false")

        // 出了问题：说明用提醒色，具体原因另起一行。
        syncMock.enabled = true
        syncMock.statusKey = "folderUnavailable"
        syncMock.hasProblem = true
        syncMock.statusText = "暂时无法访问同步文件夹。"
        syncMock.statusDetail = "找不到 iCloud 云盘"
        verify(dataPage.syncShowsExplanation)
        compare(findChild(dataPage, "settingsSyncStatusText").color, Theme.danger)
        compare(findChild(dataPage, "settingsSyncStatusDetail").text, "找不到 iCloud 云盘")

        // 关着同步时什么都不展开。
        syncMock.enabled = false
        verify(!dataPage.syncShowsExplanation)
    }

    function test_missingFolderOffersTheRightWayBack() {
        syncMock.enabled = true
        syncMock.statusKey = "folderMissing"
        syncMock.hasProblem = true
        var rebuild = findChild(dataPage, "settingsSyncRebuild")
        verify(rebuild)
        // Mac 在原处重新建一个；iPad 只能重新选 Mac 建好的那个。
        compare(rebuild.text, "重新建立同步文件夹")
        rebuild.click()
        compare(syncMock.calls[syncMock.calls.length - 1], "rebuildFolder")
        syncMock.choosesFolder = true
        compare(rebuild.text, "重新选择文件夹")
    }

    function test_iPadChoosesTheFolderAndSeesWhyAPickWasRejected() {
        syncMock.choosesFolder = true
        syncMock.hasFolder = false
        var choose = findChild(dataPage, "settingsSyncChooseFolder")
        verify(choose)
        verify(choose.caption.indexOf("还没有选择") === 0)
        choose.click()
        compare(syncMock.calls[syncMock.calls.length - 1], "chooseFolder")

        syncMock.choosingFolder = true
        compare(choose.caption, "正在检查选中的文件夹…")
        verify(!choose.enabled)

        // 选错了：原因就地显示（提示条在主窗口上，会被设置弹窗盖住）。
        syncMock.choosingFolder = false
        syncMock.folderProblem = "选中的是同步文件夹里面的子文件夹。"
        compare(findChild(dataPage, "settingsSyncFolderProblem").text, "选中的是同步文件夹里面的子文件夹。")

        syncMock.hasFolder = true
        syncMock.folderDisplayPath = "iCloud 云盘/番茄Todo同步"
        compare(choose.caption, "iCloud 云盘/番茄Todo同步")
    }

    function test_syncNowAndLogEntries() {
        var now = findChild(dataPage, "settingsSyncNow")
        verify(now)
        verify(!now.enabled)
        compare(now.caption, "打开同步后才能用")
        syncMock.enabled = true
        verify(now.enabled)
        compare(now.caption, "没有等着发出的改动")
        syncMock.pendingCount = 3
        compare(now.caption, "还有 3 条改动等着发出")
        // 后台每一轮同步都会忙一下：说明文字不跟着闪。
        syncMock.busy = true
        compare(now.caption, "还有 3 条改动等着发出")
        now.click()
        compare(syncMock.calls[syncMock.calls.length - 1], "syncNow")

        var log = findChild(dataPage, "settingsSyncLog")
        verify(log)
        compare(log.caption, "还没有记录")
        syncMock.logCount = 2
        verify(log.caption.indexOf("2 条") === 0)
        var spy = createTemporaryObject(signalSpyComponent, testCase, {
            target: dataPage,
            signalName: "syncLogRequested"
        })
        log.click()
        compare(spy.count, 1)
    }

    function test_logDialogLoadsOnOpenAndWhenNewEntriesArrive() {
        logDialog.open()
        tryCompare(logDialog, "opened", true)
        // 打开时读一次；没有记录时显示空状态，而不是一个空白框。
        compare(syncMock.calls[syncMock.calls.length - 1], "syncLog:200")
        compare(logDialog.entries.length, 0)
        verify(findChild(logDialog.contentItem, "syncLogEmpty"))

        // 开着的时候来了新记录：再读一次。
        syncMock.entries = [{
            kind: "edit", kindLabel: "同时修改", time: "今天 18:42", title: "任务「背单词」",
            summary: "「标题」保留了另一台设备的「背单词 50 个」，这台设备的「背单词 30 个」没有生效。", detail: ""
        }]
        syncMock.logChanged()
        compare(logDialog.entries.length, 1)
        var list = findChild(logDialog.contentItem, "syncLogList")
        verify(list)
        compare(list.count, 1)

        logDialog.close()
        tryCompare(logDialog, "opened", false)
        // 关着的时候不去读。
        var calls = syncMock.calls.length
        syncMock.logChanged()
        compare(syncMock.calls.length, calls)
    }

    function test_restoreWarnsThatTheOtherDeviceRollsBackToo() {
        var warning = findChild(restoreDialog.contentItem, "restoreSyncWarning")
        verify(warning)
        // 没有提醒（这台没加入过同步）：这一行不占地方。
        restoreDialog.syncWarning = ""
        restoreDialog.open()
        tryCompare(restoreDialog, "opened", true)
        compare(warning.visible, false)
        restoreDialog.close()
        tryCompare(restoreDialog, "opened", false)

        // 有提醒：原样显示控制器给的那句（关着同步时也要说清楚另一台会回到这份备份）。
        var text = "这台设备加入过设备间同步（现在关着）：恢复之后，下次打开同步时，另一台设备也会回到这份备份的状态。"
        restoreDialog.syncWarning = text
        restoreDialog.open()
        tryCompare(restoreDialog, "opened", true)
        compare(warning.text, text)
        compare(warning.Accessible.name, text)
        restoreDialog.close()
        tryCompare(restoreDialog, "opened", false)
        restoreDialog.syncWarning = ""
    }

    function test_settingsDialogHandsTheControllerToTheDataPage() {
        settingsDialog.open()
        tryCompare(settingsDialog, "opened", true)
        settingsDialog.requestSection(settingsDialog.sectionTitles.indexOf("数据与管理"))
        var loader = findChild(settingsDialog, "settingsPageLoader")
        verify(loader)
        tryCompare(loader, "status", Loader.Ready)
        compare(loader.item.syncControllerRef, syncMock)

        // 日志入口：关掉设置，再由主窗口打开日志弹窗（与其它管理入口一致）。
        var spy = createTemporaryObject(signalSpyComponent, testCase, {
            target: settingsDialog,
            signalName: "syncLogRequested"
        })
        findChild(loader.item, "settingsSyncLog").click()
        compare(spy.count, 1)
        tryCompare(settingsDialog, "opened", false)
    }
}
