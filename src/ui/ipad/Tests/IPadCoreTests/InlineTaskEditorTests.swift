import XCTest
@testable import IPadCore

@MainActor final class InlineTaskEditorTests: XCTestCase {
    private func fixture() -> (TaskBridgeFake, InteractionBridgeFake, ShellStore, InlineTaskEditor) {
        let tasks = TaskBridgeFake(); let interactions = InteractionBridgeFake(); let shell = ShellStore(bridge: ShellBridgeFake())
        var latest = TaskValue(); latest.id = 9; latest.title = "最新标题"; latest.notes = "最新备注"; latest.categoryID = 23
        interactions.latest = latest
        return (tasks, interactions, shell, InlineTaskEditor(tasks: tasks, interactions: interactions, shell: shell))
    }
    // 产品保证：编辑基线来自令牌最新快照，编辑期间冻结刷新，无改动不写库。
    func testLatestBaselineAndRefreshFreeze() {
        let (tasks, interactions, shell, editor) = fixture(); _ = shell
        var old = TaskValue(); old.id = 9; old.title = "列表旧标题"; tasks.result = [old]
        XCTAssertTrue(editor.begin(id: 9)); XCTAssertTrue(interactions.refreshBlocked)
        XCTAssertEqual(editor.title, "最新标题"); XCTAssertEqual(editor.notes, "最新备注")
        XCTAssertTrue(editor.focusRequested); editor.acknowledgeFocus(); XCTAssertFalse(editor.focusRequested)
        XCTAssertTrue(editor.finish()); XCTAssertFalse(interactions.refreshBlocked); XCTAssertTrue(tasks.changes.isEmpty)
    }
    // 产品保证：仅保存修改字段，空标题不覆盖旧标题，备注可清空，输入首尾空白去掉。
    func testOnlyChangedFieldsAreSubmittedAfterRelease() {
        let (tasks, interactions, shell, editor) = fixture(); _ = shell
        XCTAssertTrue(editor.begin(id: 9)); editor.title = " \n "; editor.notes = "  "
        var blockedWhenWriting: Bool?
        tasks.onWrite = { blockedWhenWriting = interactions.refreshBlocked }
        XCTAssertTrue(editor.finish()); XCTAssertEqual(blockedWhenWriting, false)
        var expected = TaskChanges(); expected.notes = ""
        XCTAssertEqual(tasks.changes.first?.0, 9); XCTAssertEqual(tasks.changes.first?.1, expected)
        XCTAssertTrue(editor.begin(id: 9)); editor.title = "  新标题 \n"; editor.notes = "最新备注"
        XCTAssertTrue(editor.finish()); expected = TaskChanges(); expected.title = "新标题"
        XCTAssertEqual(tasks.changes.last?.1, expected)
        XCTAssertTrue(editor.begin(id: 9)); editor.notes = "  新备注 \n"
        XCTAssertTrue(editor.finish()); expected = TaskChanges(); expected.notes = "新备注"
        XCTAssertEqual(tasks.changes.last?.1, expected)
    }
    // 产品保证：切换编辑任务先保存前一条，再取得下一条令牌，不丢已输入的标题。
    func testSwitchSavesPreviousTaskBeforeBeginningNext() {
        let (tasks, interactions, shell, editor) = fixture(); _ = shell
        XCTAssertTrue(editor.begin(id: 9)); editor.title = "改过的 A"
        interactions.latest.id = 4; interactions.latest.title = "B"
        var callsDuringWrite = 0
        tasks.onWrite = { callsDuringWrite = interactions.calls.count }
        XCTAssertTrue(editor.begin(id: 4)); XCTAssertEqual(callsDuringWrite, 1)
        XCTAssertEqual(tasks.changes.first?.0, 9); XCTAssertEqual(tasks.changes.first?.1.title, "改过的 A")
        XCTAssertEqual(editor.taskID, 4); XCTAssertEqual(editor.title, "B"); editor.cancel()
    }
    // 产品保证：令牌读取错误或快照编号不符都不进入编辑且显示准确原因，编号不符也释放令牌。
    func testBeginFailuresNeverEnterEditing() {
        let (_, interactions, shell, editor) = fixture()
        interactions.error = NSError(domain: "测试", code: 1, userInfo: [NSLocalizedDescriptionKey: "任务锁定"])
        XCTAssertFalse(editor.begin(id: 9)); XCTAssertFalse(editor.isEditing); XCTAssertEqual(shell.toast?.message, "任务锁定")
        interactions.error = nil; interactions.latest.id = 4
        XCTAssertFalse(editor.begin(id: 9)); XCTAssertFalse(editor.isEditing); XCTAssertFalse(interactions.refreshBlocked)
        XCTAssertEqual(shell.toast?.message, "任务信息已变化，请重试")
    }
}
