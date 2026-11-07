import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml/components"
import "../../qml/components/settings"
import "../../qml"

// 设备间同步的界面（050 阶段 4）：设置「数据与管理」里的同步一节、同步日志弹窗、恢复确认里的同步提醒。
// 控制器用替身：界面只认它的属性和方法，同步本身由 SyncControllerTests 覆盖。
// 宿主显式可见，新增鼠标/键盘用例验证真实输入；隐藏行断言有可见行作对照，避免恒假误通过。
TestCase {
    id: testCase

    name: "SettingsSync"
    when: windowShown
    visible: true
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
        property string transport: "icloud"
        property string serverHost: ""
        property string serverUrl: ""
        property bool switchingTransport: false
        property string transportProblem: ""
        property string pairingCodeValue: "ptsync1.test-pairing-code"
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
        function createServerSpace(url, key) {
            calls.push("createServerSpace:" + url + "|" + key)
            switchingTransport = true
        }
        function switchToICloud() { calls.push("switchToICloud") }
        function pairingCode() { return pairingCodeValue }
        function copyPairingCode() { calls.push("copyPairingCode") }
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
        syncMock.transport = "icloud"
        syncMock.serverHost = ""
        syncMock.serverUrl = ""
        syncMock.switchingTransport = false
        syncMock.transportProblem = ""
        syncMock.pairingCodeValue = "ptsync1.test-pairing-code"
        syncMock.logCount = 0
        syncMock.acceptsEnable = true
        syncMock.calls = []
        syncMock.entries = []
        logDialog.close()
        restoreDialog.close()
        settingsDialog.close()
        var serverDialog = findChild(dataPage, "serverSpaceDialog")
        var pairingDialog = findChild(dataPage, "pairingCodeDialog")
        var iCloudDialog = findChild(dataPage, "settingsSyncICloudConfirm")
        if (serverDialog)
            serverDialog.close()
        if (pairingDialog)
            pairingDialog.close()
        if (iCloudDialog)
            iCloudDialog.close()
        tryVerify(function () {
            return !logDialog.visible && !restoreDialog.visible && !settingsDialog.visible
                    && (!serverDialog || !serverDialog.opened)
                    && (!pairingDialog || !pairingDialog.opened)
                    && (!iCloudDialog || !iCloudDialog.opened)
        }, 3000, "上一条用例的弹窗还没收起")
    }

    // 等布局就绪后发送鼠标事件，避免刚切换方式时按到上一帧的位置。
    function clickControl(control) {
        verify(control !== null)
        verify(waitForItemPolished(control.parent))
        verify(control.visible && control.enabled)
        verify(control.width > 0 && control.height > 0)
        mouseClick(control, control.width / 2, control.height / 2)
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

    // 产品保证：同步方式决定分区说明与服务器/文件夹行，切换进行中不能改方式。
    function test_transportModesSwapTheRowsAndCaption() {
        compare(dataPage.syncTransport, "icloud")
        compare(dataPage.syncTransportCaption, "经 iCloud 云盘中转，可能要几分钟")
        compare(dataPage.syncSectionDescription.indexOf("通过 iCloud 云盘里的"), 0)
        verify(findChild(dataPage, "settingsSyncFolderRow").visible)
        verify(!findChild(dataPage, "settingsSyncServerRow").visible)
        verify(!findChild(dataPage, "settingsSyncPairingButton").visible)
        verify(!findChild(dataPage, "settingsSyncRebuildSpaceButton").visible)

        syncMock.transport = "server"
        syncMock.serverHost = "sync.example.com"
        tryCompare(dataPage, "syncTransport", "server")
        compare(dataPage.syncTransportCaption, "改动几秒内到另一台")
        compare(dataPage.syncSectionDescription.indexOf("经你自己的同步服务器"), 0)
        verify(!findChild(dataPage, "settingsSyncFolderRow").visible)
        var serverRow = findChild(dataPage, "settingsSyncServerRow")
        verify(serverRow.visible)
        compare(serverRow.caption, "sync.example.com · 端到端加密")
        verify(findChild(dataPage, "settingsSyncPairingButton").visible)
        verify(findChild(dataPage, "settingsSyncRebuildSpaceButton").visible)

        var transportSwitch = findChild(dataPage, "settingsSyncTransportSwitch")
        compare(transportSwitch.currentIndex, 0)
        syncMock.switchingTransport = true
        verify(!transportSwitch.enabled)
    }

    // 产品保证：iCloud 方式选择自建服务器只打开建空间弹窗，取消后仍保持 iCloud。
    function test_iCloudServerChoiceDoesNotSwitchBeforeSpaceExists() {
        var transportSwitch = findChild(dataPage, "settingsSyncTransportSwitch")
        compare(transportSwitch.currentIndex, 1)
        clickControl(findChild(transportSwitch, "segmentedSwitchSegment0"))
        var serverDialog = findChild(dataPage, "serverSpaceDialog")
        tryCompare(serverDialog, "opened", true)
        compare(serverDialog.rebuilding, false)
        compare(findChild(serverDialog, "serverSpaceDialogTitle").text, "改用自建服务器同步")
        compare(syncMock.calls.length, 0)
        compare(transportSwitch.currentIndex, 1)

        clickControl(findChild(serverDialog, "serverSpaceCancelButton"))
        tryCompare(serverDialog, "opened", false)
        compare(dataPage.syncTransport, "icloud")
        compare(syncMock.calls.length, 0)
    }

    // 产品保证：服务器方式切回 iCloud 必须先确认，确认后才调用控制器切换。
    function test_serverICloudChoiceRequiresConfirmation() {
        syncMock.transport = "server"
        syncMock.serverHost = "sync.example.com"
        var transportSwitch = findChild(dataPage, "settingsSyncTransportSwitch")
        clickControl(findChild(transportSwitch, "segmentedSwitchSegment1"))
        var confirmation = findChild(dataPage, "settingsSyncICloudConfirm")
        tryCompare(confirmation, "opened", true)
        compare(findChild(confirmation, "settingsSyncICloudConfirmTitle").text, "改用 iCloud 云盘？")
        compare(findChild(confirmation, "settingsSyncICloudConfirmText").text,
                "会在 iCloud 云盘里新建「番茄Todo同步」文件夹，iPad 要在设置里重新选择它并确认加入。服务器上的同步空间留着不删。")
        compare(syncMock.calls.length, 0)
        compare(transportSwitch.currentIndex, 0)

        clickControl(findChild(confirmation, "settingsSyncICloudConfirmButton"))
        tryCompare(confirmation, "opened", false)
        compare(syncMock.calls[syncMock.calls.length - 1], "switchToICloud")
    }

    // 产品保证：建空间提交使用输入值，连接时锁住表单，成功后关窗并接上配对码弹窗。
    function test_spaceCreationSuccessChainsThePairingDialog() {
        var serverDialog = findChild(dataPage, "serverSpaceDialog")
        clickControl(findChild(findChild(dataPage, "settingsSyncTransportSwitch"), "segmentedSwitchSegment0"))
        tryCompare(serverDialog, "opened", true)
        var addressField = findChild(serverDialog, "serverSpaceAddressField")
        var keyField = findChild(serverDialog, "serverSpaceEnrollmentKeyField")
        var submit = findChild(serverDialog, "serverSpaceSubmitButton")
        compare(addressField.text, "")
        addressField.text = "https://sync.example.com"
        keyField.text = "enroll-secret"
        clickControl(submit)
        compare(syncMock.calls[syncMock.calls.length - 1],
                "createServerSpace:https://sync.example.com|enroll-secret")
        tryCompare(syncMock, "switchingTransport", true)
        verify(!submit.enabled)
        compare(submit.text, "正在建立…")
        verify(addressField.readOnly)
        verify(keyField.readOnly)

        syncMock.transport = "server"
        syncMock.serverHost = "sync.example.com"
        syncMock.switchingTransport = false
        tryCompare(serverDialog, "opened", false)
        var pairingDialog = findChild(dataPage, "pairingCodeDialog")
        tryCompare(pairingDialog, "opened", true)
        compare(findChild(pairingDialog, "pairingCodeValue").text, pairingDialog.maskedCode)
    }

    // 产品保证：建空间失败留在原弹窗显示原因，关闭时清掉注册口令。
    function test_spaceCreationFailureKeepsTheDialogForCorrection() {
        syncMock.transport = "server"
        syncMock.serverHost = "sync.example.com"
        syncMock.serverUrl = "https://sync.example.com"
        var serverDialog = findChild(dataPage, "serverSpaceDialog")
        clickControl(findChild(dataPage, "settingsSyncRebuildSpaceButton"))
        tryCompare(serverDialog, "opened", true)
        compare(serverDialog.dialogTitle, "重新建立同步空间")
        var addressField = findChild(serverDialog, "serverSpaceAddressField")
        var keyField = findChild(serverDialog, "serverSpaceEnrollmentKeyField")
        compare(addressField.text, "https://sync.example.com")
        addressField.text = "https://sync.example.com"
        keyField.text = "wrong-key"
        clickControl(findChild(serverDialog, "serverSpaceSubmitButton"))
        tryCompare(syncMock, "switchingTransport", true)
        syncMock.transportProblem = "注册口令不对，服务器拒绝建立"
        syncMock.switchingTransport = false
        verify(serverDialog.opened)
        compare(findChild(serverDialog, "serverSpaceProblem").text, "注册口令不对，服务器拒绝建立")
        verify(!findChild(dataPage, "pairingCodeDialog").opened)

        clickControl(findChild(serverDialog, "serverSpaceCancelButton"))
        tryCompare(serverDialog, "opened", false)
        compare(keyField.text, "")
    }

    // 产品保证：重新建立空间预填完整服务器地址，非默认端口与路径不会被丢弃。
    function test_rebuildPrefillsTheCompleteServerUrl() {
        syncMock.transport = "server"
        syncMock.serverHost = "sync.example.com"
        syncMock.serverUrl = "https://sync.example.com:9443/pt-sync"
        var rebuild = findChild(dataPage, "settingsSyncRebuildSpaceButton")
        verify(rebuild)
        verify(waitForItemPolished(dataPage))
        clickControl(rebuild)
        var dialog = findChild(dataPage, "serverSpaceDialog")
        tryCompare(dialog, "opened", true)
        compare(findChild(dialog, "serverSpaceAddressField").text, syncMock.serverUrl)
        keyClick(Qt.Key_Escape)
        tryCompare(dialog, "opened", false)
    }

    // 产品保证：配对码默认遮住、眼睛按钮揭示，复制后按钮短暂显示「已复制」，重开后复位。
    function test_pairingCodeMaskRevealCopyAndReset() {
        syncMock.transport = "server"
        var pairingDialog = findChild(dataPage, "pairingCodeDialog")
        syncMock.pairingCodeValue = "ptsync1.visible-secret"
        clickControl(findChild(dataPage, "settingsSyncPairingButton"))
        tryCompare(pairingDialog, "opened", true)
        var codeText = findChild(pairingDialog, "pairingCodeValue")
        var reveal = findChild(pairingDialog, "pairingCodeRevealButton")
        var copy = findChild(pairingDialog, "pairingCodeCopyButton")
        compare(codeText.text, pairingDialog.maskedCode)
        compare(reveal.Accessible.name, "显示配对码")
        clickControl(reveal)
        compare(codeText.text, "ptsync1.visible-secret")
        compare(reveal.Accessible.name, "隐藏配对码")

        clickControl(copy)
        compare(syncMock.calls[syncMock.calls.length - 1], "copyPairingCode")
        compare(copy.text, "已复制")
        tryCompare(copy, "text", "复制配对码", 3000)

        clickControl(findChild(pairingDialog, "pairingCodeDoneButton"))
        tryCompare(pairingDialog, "opened", false)
        clickControl(findChild(dataPage, "settingsSyncPairingButton"))
        tryCompare(pairingDialog, "opened", true)
        compare(findChild(pairingDialog, "pairingCodeValue").text, pairingDialog.maskedCode)
        compare(findChild(pairingDialog, "pairingCodeRevealButton").Accessible.name, "显示配对码")
        clickControl(findChild(pairingDialog, "pairingCodeDoneButton"))
    }

    // 产品保证：空闲时 Esc 可关闭建空间弹窗，正在切换时 Esc 和重复点击不会中断或重提请求。
    function test_spaceDialogEscapeRespectsAnActiveSwitch() {
        var segment = findChild(findChild(dataPage, "settingsSyncTransportSwitch"), "segmentedSwitchSegment0")
        var dialog = findChild(dataPage, "serverSpaceDialog")
        clickControl(segment)
        tryCompare(dialog, "opened", true)
        keyClick(Qt.Key_Escape)
        tryCompare(dialog, "opened", false)

        clickControl(segment)
        tryCompare(dialog, "opened", true)
        findChild(dialog, "serverSpaceAddressField").text = "https://sync.example.com"
        findChild(dialog, "serverSpaceEnrollmentKeyField").text = "enroll-secret"
        var submit = findChild(dialog, "serverSpaceSubmitButton")
        clickControl(submit)
        tryCompare(syncMock, "switchingTransport", true)
        var callCount = syncMock.calls.length
        verify(!submit.enabled)
        keyClick(Qt.Key_Escape)
        compare(dialog.opened, true)
        mouseClick(submit)
        compare(syncMock.calls.length, callCount)
        syncMock.transportProblem = "连不上同步服务器"
        syncMock.switchingTransport = false
        tryCompare(submit, "enabled", true)
        keyClick(Qt.Key_Escape)
        tryCompare(dialog, "opened", false)
        compare(findChild(dialog, "serverSpaceEnrollmentKeyField").text, "")
    }
}
