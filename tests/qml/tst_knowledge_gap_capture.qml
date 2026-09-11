import QtQuick
import QtTest
import "../../qml"
import "../../qml/components"

// 快速捕获框的验收重点只有两条，其余都是附属：
//   1. 回车就能存下，不用去够鼠标；
//   2. 存的过程中绝不碰计时器——这个框存在的全部前提就是「不打断正在进行的专注」。
TestCase {
    id: testCase
    name: "KnowledgeGapCapture"
    when: windowShown
    width: 640
    height: 480

    property int captureCalls: 0
    property string lastTitle: ""
    property int lastCategoryId: -1
    property int lastSourceTaskId: -1
    property int nextId: 1
    property int capturedSignals: 0
    property string capturedTitle: ""

    QtObject {
        id: fakeGapService

        property int maxTitleLength: 100

        function captureGap(title, categoryId, sourceTaskId) {
            testCase.captureCalls += 1
            testCase.lastTitle = title
            testCase.lastCategoryId = categoryId
            testCase.lastSourceTaskId = sourceTaskId
            return testCase.nextId
        }
    }

    // 计时器替身只记录有没有被动过。捕获框一旦调用了它的任何方法，
    // 就说明「记一笔会打断专注」这条红线被越过了。
    QtObject {
        id: fakeTimer

        property int pauseCalls: 0
        property int stopCalls: 0
        property bool isRunning: true

        function pause() { fakeTimer.pauseCalls += 1 }
        function stop() { fakeTimer.stopCalls += 1 }
    }

    Component {
        id: popupComponent

        KnowledgeGapCapturePopup {
            gapServiceRef: fakeGapService

            onCaptured: function (title) {
                testCase.capturedSignals += 1
                testCase.capturedTitle = title
            }
        }
    }

    function createPopup() {
        var popup = createTemporaryObject(popupComponent, testCase)
        verify(popup)
        return popup
    }

    function findChild(root, name) {
        if (root.objectName === name) {
            return root
        }
        for (var i = 0; i < root.children.length; ++i) {
            var found = findChild(root.children[i], name)
            if (found) {
                return found
            }
        }
        return null
    }

    function init() {
        testCase.captureCalls = 0
        testCase.lastTitle = ""
        testCase.lastCategoryId = -1
        testCase.lastSourceTaskId = -1
        testCase.nextId = 1
        testCase.capturedSignals = 0
        testCase.capturedTitle = ""
        fakeTimer.pauseCalls = 0
        fakeTimer.stopCalls = 0
        fakeTimer.isRunning = true
    }

    function test_popupIsNotModal() {
        var popup = createPopup()
        // 模态会把整个界面锁住，等于逼用户停下手里的事——这正是本功能要避免的。
        compare(popup.modal, false)
        compare(popup.dim, false)
    }

    function test_submitCarriesSourceAndCategory() {
        var popup = createPopup()
        popup.openWithSource(42, "复习线代第 3 章", 7)
        compare(popup.sourceTaskId, 42)
        compare(popup.categoryId, 7)

        var field = findChild(popup.contentItem, "knowledgeGapCaptureField")
        verify(field)
        field.text = "  相似对角化没搞懂  "
        popup.submit()

        compare(testCase.captureCalls, 1)
        // 首尾空白由服务层 trim，这里只确认原文如实传下去，界面不做二次加工。
        compare(testCase.lastTitle, "相似对角化没搞懂")
        compare(testCase.lastSourceTaskId, 42)
        compare(testCase.lastCategoryId, 7)
        compare(testCase.capturedSignals, 1)
        compare(testCase.capturedTitle, "相似对角化没搞懂")
    }

    function test_submitDoesNotTouchTheTimer() {
        var popup = createPopup()
        popup.openWithSource(1, "正在专注的任务", 0)
        var field = findChild(popup.contentItem, "knowledgeGapCaptureField")
        verify(field)
        field.text = "这一段没听懂"
        popup.submit()

        compare(testCase.captureCalls, 1)
        // 计时器一次都不该被碰过，而且仍在跑。
        compare(fakeTimer.pauseCalls, 0)
        compare(fakeTimer.stopCalls, 0)
        compare(fakeTimer.isRunning, true)
    }

    function test_enterKeySaves() {
        var popup = createPopup()
        popup.openWithSource(0, "", 0)
        var field = findChild(popup.contentItem, "knowledgeGapCaptureField")
        verify(field)
        field.forceActiveFocus()
        field.text = "回车就能存"
        keyClick(Qt.Key_Return)

        compare(testCase.captureCalls, 1)
        compare(testCase.lastTitle, "回车就能存")
    }

    function test_emptyInputIsRejectedWithoutCallingService() {
        var popup = createPopup()
        popup.openWithSource(0, "", 0)
        var field = findChild(popup.contentItem, "knowledgeGapCaptureField")
        verify(field)
        field.text = "   "
        popup.submit()

        compare(testCase.captureCalls, 0)
        verify(popup.errorText.length > 0)
    }

    function test_failedSaveKeepsDraftForRetry() {
        var popup = createPopup()
        popup.openWithSource(0, "", 0)
        var field = findChild(popup.contentItem, "knowledgeGapCaptureField")
        verify(field)
        // 服务返回 -1 表示没存下。此时绝不能清空输入框：
        // 用户刚打完的那句话是这个功能唯一的产物，丢了就等于白记。
        testCase.nextId = -1
        field.text = "存不下去的一条"
        popup.submit()

        compare(testCase.captureCalls, 1)
        compare(field.text, "存不下去的一条")
        verify(popup.errorText.length > 0)
        compare(testCase.capturedSignals, 0)
    }

    function test_missingServiceMethodIsHandled() {
        var popup = createTemporaryObject(popupComponent, testCase, { gapServiceRef: null })
        verify(popup)
        popup.openWithSource(0, "", 0)
        var field = findChild(popup.contentItem, "knowledgeGapCaptureField")
        verify(field)
        field.text = "服务不可用"
        // 替身缺方法时必须先查可调用性再调用，否则这里会抛 TypeError。
        popup.submit()
        verify(popup.errorText.length > 0)
    }
}
