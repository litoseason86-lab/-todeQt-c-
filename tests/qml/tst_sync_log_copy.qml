import QtQuick
import QtTest
import "../../qml"
import "../../qml/components"

TestCase {
    id: testCase
    name: "SyncLogCopy"
    when: windowShown
    visible: true
    width: 720
    height: 800
    property bool oldReduceMotion: false
    property string original: "完整正文\n" + "原".repeat(7000) + "\n末尾🙂"
    QtObject {
        id: controller
        signal logChanged
        signal copyRequested(string text)
        function copyLostValue(text) {
            copyRequested(text);
        }
        function syncLog(limit) {
            return [
                {
                    kindLabel: "字段冲突",
                    title: "备忘录",
                    time: "今天",
                    summary: "被缩短的摘要…",
                    canCopyLostValue: true,
                    lostValue: testCase.original
                },
                {
                    kindLabel: "科目合并",
                    title: "科目",
                    time: "昨天",
                    summary: "两科已合并",
                    canCopyLostValue: false,
                    lostValue: "不是可复制的正文"
                }
            ];
        }
    }
    SyncLogDialog {
        id: dialog
        parent: testCase
        syncControllerRef: controller
    }
    SignalSpy {
        id: copied
        target: controller
        signalName: "copyRequested"
    }
    function initTestCase() {
        oldReduceMotion = Theme.reduceMotion;
        Theme.reduceMotion = true;
    }
    function cleanupTestCase() {
        Theme.reduceMotion = oldReduceMotion;
    }
    function init() {
        copied.clear();
        dialog.open();
        tryVerify(function () {
            return dialog.opened;
        }, 3000);
    }
    function cleanup() {
        dialog.close();
        tryVerify(function () {
            return !dialog.opened;
        }, 3000);
    }
    // 产品保证：只有具备完整可找回原文的条目才有复制按钮，其它日志条目没有复制动作。
    function test_copyButtonEligibility() {
        tryVerify(function () {
            return findChild(dialog.contentItem, "syncLogCopyLostValue0") !== null;
        }, 3000);
        verify(findChild(dialog.contentItem, "syncLogEntry1") !== null, "不可复制的条目也必须真正渲染");
        verify(findChild(dialog.contentItem, "syncLogCopyLostValue1") === null);
    }
    // 产品保证：点击复制携带完整正文（包括末尾）；按钮旁边出现「已复制」，用户看得到复制成功，几秒后自动消失。
    // 抓住的错误实现：提示挂在一个不在画面里的提示条上（父项为空），只有内部标记变了，用户什么也看不到。
    function test_clickCopiesOriginalAndShowsNotice() {
        verify(original.length > 7000);
        tryVerify(function () {
            return findChild(dialog.contentItem, "syncLogCopyLostValue0") !== null;
        }, 3000);
        var notice = findChild(dialog.contentItem, "syncLogCopied0");
        verify(notice !== null);
        compare(notice.opacity, 0, "前置：点击前没有提示");
        mouseClick(findChild(dialog.contentItem, "syncLogCopyLostValue0"));
        tryCompare(copied, "count", 1, 3000);
        compare(copied.signalArguments[0][0], original);
        compare(notice.opacity, 1);
        compare(notice.text, "已复制");
        verify(notice.Window.window !== null, "提示就在弹窗的画面里，不是悬空的对象");
        tryCompare(notice, "opacity", 0, 5000);
    }
    // 产品保证：复制按钮按文字宽度显示，不被拉成和日志条目一样宽的通栏。
    function test_copyButtonKeepsNaturalWidth() {
        tryVerify(function () {
            return findChild(dialog.contentItem, "syncLogCopyLostValue0") !== null;
        }, 3000);
        var button = findChild(dialog.contentItem, "syncLogCopyLostValue0");
        var entry = findChild(dialog.contentItem, "syncLogEntry0");
        verify(button.implicitWidth < entry.width / 2, "前置：条目比按钮文字宽得多");
        compare(button.width, button.implicitWidth);
    }
}
