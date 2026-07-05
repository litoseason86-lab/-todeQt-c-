# 任务管理补洞第二部分：任务编辑 + 延迟删除撤销 + hover 化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 双击行内改标题 + 编辑弹窗改全字段（含日期快捷项）；删除改为延迟提交 + Toast 撤销（5 秒窗口）；编辑/删除按钮 hover 化，已完成任务隐藏"开始专注"。

**Architecture:** TaskItem 保持信号上抛的哑组件模式（`renameSubmitted`/`editClicked`/`deleteClicked`），原值由 delegate 作用域的 `modelData` 提供；删除流集中到 MainWindow（同 `startFocusForTask` 模式）：`pendingDeleteTaskId` 注入视图过滤隐藏，Toast 超时才真调 `deleteTask`——因为 `deleteTask` 会先解绑专注记录，删了再插回会永久丢关联；Toast 扩展可选 action 按钮。

**Tech Stack:** Qt 6.9 / Qt Quick(QML) / Qt Test。

**对应规格:** `docs/superpowers/specs/2026-07-06-task-management-gaps-design.md` 的「任务编辑」「删除撤销 + hover 化」。

**前置依赖:** 第一部分已合入（依赖 `TaskManager::updateTask`、`tst_today_rollover.qml`）。

## Global Constraints

- git 提交说明用**中文**；非显然逻辑加**中文注释**（解释为什么/边界）。
- 不改 `build/`；每个任务改完跑构建与相关测试再提交。
- 单文件 QML：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/<file>.qml 2>/dev/null | grep -E "FAIL|Totals"`；qmllint：`/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint <file>`；全量：`cmake --build build && ctest --test-dir build --output-on-failure`。
- 分支 `task-management-gaps`（第一部分创建，直接继续）。
- **QML 测试纪律**：绝不断言 `something.visible === true`；hover 显隐用 opacity+enabled 门控并断言 `enabled`。
- **hover 按钮用 opacity+enabled 而非 visible**：visible 会把按钮从 RowLayout 里抽走导致标题宽度跳变；opacity 门控保住布局占位。程序化 `button.clicked()` 发信号不受 enabled 影响，既有测试（`test_taskItemExposesDeleteAction`）无需改动。
- 文案用裸中文（不加 `qsTr()`）。
- 规格提到给 TaskItem 加 `taskCategoryId`/`taskDate` 属性传原值；实现按更薄的等效方案走——原值由 delegate 作用域 `modelData` 在视图层提供，TaskItem 不新增数据属性。

---

### Task 1: Toast 可选 action 按钮

**Files:**

- Modify: `qml/components/Toast.qml`
- Modify: `qml/MainWindow.qml`（showToast 透传参数）
- Test: `tests/qml/tst_focus_start_flow.qml`

**Interfaces:**

- Produces:

  - `Toast.show(message, actionText, actionCallback)` —— 后两参可省略，省略时行为与现状完全一致
  - 带 action 时展示时长用 `property int actionDisplayDurationMs: 5000`（与删除提交窗口对齐）
  - action 按钮 objectName `toastActionButton`；`function triggerAction()` 供测试直接调用
  - MainWindow `showToast(message, actionText, actionCallback)` 透传

- [x] **Step 1: 写失败测试**

`tests/qml/tst_focus_start_flow.qml` 文件末尾加：

```qml
    function test_toastActionShowsAndFires() {
        var toast = findChild(mainWindow, "globalToast");
        verify(toast);
        var fired = false;

        mainWindow.showToast("已删除「测试」", "撤销", function () { fired = true; });
        compare(toast.shown, true);
        compare(toast.actionText, "撤销");

        toast.triggerAction();
        compare(fired, true);
        compare(toast.shown, false);
    }

    function test_toastWithoutActionKeepsOldBehavior() {
        var toast = findChild(mainWindow, "globalToast");
        verify(toast);

        mainWindow.showToast("普通提示");
        compare(toast.shown, true);
        compare(toast.actionText, "");
    }
```

- [x] **Step 2: 运行确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_start_flow.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: FAIL（`actionText`/`triggerAction` 不存在）。

- [x] **Step 3: 写实现**

`qml/components/Toast.qml`：

属性区（`shown` 之后）加：

```qml
    property string actionText: ""
    property var actionCallback: null
    // 带撤销按钮的提示要给用户更长的反应窗口，与删除延迟提交对齐。
    property int actionDisplayDurationMs: 5000
```

`show` 函数替换为：

```qml
    function show(message, action, callback) {
        label.text = message
        root.actionText = action === undefined || action === null ? "" : String(action)
        root.actionCallback = callback === undefined ? null : callback
        hideTimer.interval = root.actionText.length > 0
                ? root.actionDisplayDurationMs
                : root.displayDurationMs
        root.shown = true
        hideTimer.restart()
    }

    function triggerAction() {
        // 先取回调再收起：收起可能触发外部状态变化，避免回调被清掉。
        var callback = root.actionCallback
        root.actionCallback = null
        root.shown = false
        hideTimer.stop()
        if (callback) {
            callback()
        }
    }
```

`hideTimer` 的 `interval: root.displayDurationMs` 绑定删除（show 里已按需赋值）。

内容区改为文本+按钮并排（替换原 label 单独居中）：

```qml
    Row {
        anchors.centerIn: parent
        spacing: Theme.space12

        Text {
            id: label

            objectName: "toastText"
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            color: Theme.surface
            font.pixelSize: Theme.fontMd
        }

        Text {
            objectName: "toastActionButton"
            anchors.verticalCenter: parent.verticalCenter
            visible: root.actionText.length > 0
            text: root.actionText
            textFormat: Text.PlainText
            color: Theme.accentSoft
            font.pixelSize: Theme.fontMd
            font.weight: Font.DemiBold

            TapHandler {
                onTapped: root.triggerAction()
            }
        }
    }
```

`implicitWidth` 改为 `implicitWidth: contentRow.implicitWidth + Theme.space24 * 2`，给 Row 加 `id: contentRow`。

`qml/MainWindow.qml` 的 `showToast` 改为：

```qml
    function showToast(message, actionText, actionCallback) {
        globalToast.show(message, actionText, actionCallback)
    }
```

- [x] **Step 4: qmllint + 测试确认通过**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/Toast.qml qml/MainWindow.qml && /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_start_flow.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: lint 无输出；全部 PASS（既有 toast 用例走无 action 路径不受影响）。

- [x] **Step 5: 提交**

```bash
git add qml/components/Toast.qml qml/MainWindow.qml tests/qml/tst_focus_start_flow.qml
git commit -m "Toast 支持可选撤销动作按钮"
```

---

### Task 2: TaskItem 行内编辑 + 按钮 hover 化

**Files:**

- Modify: `qml/components/TaskItem.qml`
- Create: `tests/qml/tst_task_item_edit.qml`

**Interfaces:**

- Produces:

  - 信号 `renameSubmitted(int taskId, string newTitle)`、`editClicked(int taskId)`
  - `property bool titleEditing: false`；函数 `beginTitleEdit()`/`commitTitleEdit()`/`cancelTitleEdit()`
  - objectName：`taskTitleEditField`、`taskEditButton`
  - "编辑/删除"按钮 `opacity: itemHovered ? 1 : 0` + `enabled: itemHovered`；已完成任务 `focusButton.visible: false`

- [x] **Step 1: 写失败测试**

新建 `tests/qml/tst_task_item_edit.qml`：

```qml
import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "TaskItemEdit"
    when: windowShown
    width: 600
    height: 200

    TaskItem {
        id: item
        width: testCase.width
        taskId: 42
        taskTitle: "原始标题"
        taskCompleted: false
    }

    SignalSpy {
        id: renameSpy
        target: item
        signalName: "renameSubmitted"
    }

    SignalSpy {
        id: editSpy
        target: item
        signalName: "editClicked"
    }

    function init() {
        item.taskTitle = "原始标题";
        item.taskCompleted = false;
        item.titleEditing = false;
        item.setPointerInside(false);
        renameSpy.clear();
        editSpy.clear();
        wait(20);
    }

    function test_beginEditPrefillsAndCommitEmits() {
        item.beginTitleEdit();
        compare(item.titleEditing, true);

        const field = findChild(item, "taskTitleEditField");
        verify(field);
        compare(field.text, "原始标题");

        field.text = "改好的标题";
        item.commitTitleEdit();

        compare(item.titleEditing, false);
        compare(renameSpy.count, 1);
        compare(renameSpy.signalArguments[0][0], 42);
        compare(renameSpy.signalArguments[0][1], "改好的标题");
    }

    function test_blankOrUnchangedTitleIsCancel() {
        item.beginTitleEdit();
        const field = findChild(item, "taskTitleEditField");
        field.text = "   ";
        item.commitTitleEdit();
        compare(renameSpy.count, 0);
        compare(item.titleEditing, false);

        item.beginTitleEdit();
        field.text = "原始标题"; // 未修改
        item.commitTitleEdit();
        compare(renameSpy.count, 0);
    }

    function test_cancelRestoresWithoutSignal() {
        item.beginTitleEdit();
        const field = findChild(item, "taskTitleEditField");
        field.text = "不该生效";
        item.cancelTitleEdit();

        compare(item.titleEditing, false);
        compare(renameSpy.count, 0);
    }

    function test_hoverGatesEditAndDeleteButtons() {
        const editButton = findChild(item, "taskEditButton");
        const deleteButton = findChild(item, "taskDeleteButton");
        verify(editButton);
        verify(deleteButton);

        compare(editButton.enabled, false);
        compare(deleteButton.enabled, false);

        item.setPointerInside(true);
        wait(20);
        compare(editButton.enabled, true);
        compare(deleteButton.enabled, true);

        editButton.clicked();
        compare(editSpy.count, 1);
        compare(editSpy.signalArguments[0][0], 42);
    }

    function test_completedTaskHidesFocusButton() {
        const focusButton = findChild(item, "focusButton");
        verify(focusButton);

        item.taskCompleted = true;
        wait(260);
        compare(focusButton.visible, false);
    }
}
```

- [x] **Step 2: 运行确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_task_item_edit.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: FAIL（信号/函数/按钮不存在）。

- [x] **Step 3: 写实现**

`qml/components/TaskItem.qml`：

信号区（`deleteClicked` 之后）加：

```qml
    signal renameSubmitted(int taskId, string newTitle)
    signal editClicked(int taskId)
```

属性区加 `property bool titleEditing: false`。

函数区（`setPointerInside` 之后）加：

```qml
    function beginTitleEdit() {
        root.titleEditing = true
        titleEditField.text = root.taskTitle
        titleEditField.forceActiveFocus()
        titleEditField.selectAll()
    }

    function commitTitleEdit() {
        var newTitle = titleEditField.text.trim()
        root.titleEditing = false
        // 空标题或没改动都当作取消：不打接口、不发信号。
        if (newTitle.length === 0 || newTitle === root.taskTitle) {
            return
        }
        root.renameSubmitted(root.taskId, newTitle)
    }

    function cancelTitleEdit() {
        root.titleEditing = false
    }
```

标题 Text（objectName `taskTitleText`）改造：加 `visible: !root.titleEditing` 与双击进入编辑：

```qml
                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    onDoubleTapped: root.beginTitleEdit()
                }
```

标题 Text 之后（同一 ColumnLayout 内）加编辑框：

```qml
            TextField {
                id: titleEditField

                objectName: "taskTitleEditField"
                Layout.fillWidth: true
                visible: root.titleEditing
                font.pixelSize: Theme.fontLg
                color: Theme.inkStrong
                selectByMouse: true

                background: Rectangle {
                    color: Theme.surface
                    border.color: Theme.accent
                    border.width: 1
                    radius: Theme.radiusSm
                }

                Keys.onReturnPressed: root.commitTitleEdit()
                Keys.onEnterPressed: root.commitTitleEdit()
                Keys.onEscapePressed: root.cancelTitleEdit()
                onActiveFocusChanged: {
                    // 失焦等同取消：避免半编辑状态残留在列表里。
                    if (!activeFocus && root.titleEditing) {
                        root.cancelTitleEdit()
                    }
                }
            }
```

"编辑"按钮：`focusButton` 之后、`deleteButton` 之前加（样式复用 deleteButton 的中性风格，仅文字与信号不同）：

```qml
        Button {
            id: editButton

            objectName: "taskEditButton"
            text: "编辑"
            implicitWidth: 56
            implicitHeight: 40
            opacity: root.itemHovered ? 1 : 0
            enabled: root.itemHovered

            Behavior on opacity {
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutQuad
                }
            }

            background: Rectangle {
                radius: Theme.radiusMd
                color: editButton.hovered ? Theme.surfaceSunken : Theme.surface
                border.color: editButton.hovered ? Theme.accent : Theme.border
                border.width: 1
            }

            contentItem: Text {
                text: editButton.text
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }

            onClicked: root.editClicked(root.taskId)
        }
```

`deleteButton` 加同款门控（属性区插入这三行，不动其余样式/动画）：

```qml
            opacity: root.itemHovered ? 1 : 0
            enabled: root.itemHovered

            Behavior on opacity {
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutQuad
                }
            }
```

`focusButton`：加 `visible: !root.visualTaskCompleted`，删除 `ToolTip.visible`/`ToolTip.text` 两行（按钮藏起来后 tooltip 无意义；`enabled`/`text` 绑定保留，既有测试 `test_focusButtonStatesLoadAndCompletedDisablesAction` 断言的是 text/enabled，不受影响）。

- [x] **Step 4: qmllint + 测试确认通过（含既有 TaskItem 回归）**

Run:

```bash
/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/TaskItem.qml
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_task_item_edit.qml 2>/dev/null | grep -E "FAIL|Totals"
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_ui_optimization.qml 2>/dev/null | grep -E "Totals"
```

Expected: lint 无输出；新文件全 PASS 连跑 2 次；`tst_ui_optimization` 保持既有水平（若 `test_taskItemExposesDeleteAction` 或粒子用例出现**新的确定性失败**，检查是否 hover 门控影响了真实点击路径的用例——程序化 `clicked()` 不受影响，坐标点击的用例需要先 `setPointerInside(true)`）。

- [x] **Step 5: 提交**

```bash
git add qml/components/TaskItem.qml tests/qml/tst_task_item_edit.qml
git commit -m "TaskItem 支持行内改标题并将编辑删除按钮 hover 化"
```

---

### Task 3: EditTaskDialog 组件

**Files:**

- Create: `qml/components/EditTaskDialog.qml`
- Modify: `resources/qml.qrc`（注册）
- Create: `tests/qml/tst_edit_task_dialog.qml`

**Interfaces:**

- Consumes: 视图注入 `categoryManagerRef`（提供 `getAllCategories()`）
- Produces:

  - `function openForTask(task)` —— task 为视图 modelData（含 id/title/categoryId/date）
  - 信号 `taskEdited(int taskId, string title, int categoryId, var isoDate)`（isoDate 为 `"yyyy-MM-dd"` 字符串，直接可传 updateTask）
  - `property int dateOffsetSelection`（-1=保留原日期，0/1/2=今天/明天/后天）；`function resultIsoDate()`
  - objectName：`editTitleField`、`editCategoryCombo`、日期 chip `editDateToday`/`editDateTomorrow`/`editDateDayAfter`、原日期文本 `editOriginalDateText`、确认 `editConfirmButton`

- [x] **Step 1: 写失败测试**

新建 `tests/qml/tst_edit_task_dialog.qml`：

```qml
import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    id: testCase
    name: "EditTaskDialog"
    when: windowShown
    width: 700
    height: 500

    QtObject {
        id: categoryManagerMock

        function getAllCategories() {
            return [
                { id: 3, name: "数学", color: "#d4a574" },
                { id: 5, name: "英语", color: "#8b7355" }
            ];
        }
    }

    EditTaskDialog {
        id: dialog
        categoryManagerRef: categoryManagerMock
    }

    SignalSpy {
        id: editedSpy
        target: dialog
        signalName: "taskEdited"
    }

    function init() {
        editedSpy.clear();
        dialog.close();
        wait(20);
    }

    function isoWithOffset(offset) {
        var d = new Date();
        d.setDate(d.getDate() + offset);
        return Qt.formatDate(d, "yyyy-MM-dd");
    }

    function test_openPrefillsFields() {
        dialog.openForTask({ id: 7, title: "高数例题", categoryId: 5, date: isoWithOffset(0) });
        wait(20);

        const titleField = findChild(dialog, "editTitleField");
        verify(titleField);
        compare(titleField.text, "高数例题");

        const combo = findChild(dialog, "editCategoryCombo");
        verify(combo);
        // categoryOptions[0] 是"不设置科目"，英语(id=5) 在索引 2。
        compare(combo.currentIndex, 2);

        // 任务日期是今天 → 今天 chip 预选。
        compare(dialog.dateOffsetSelection, 0);
    }

    function test_offPresetDateKeepsOriginal() {
        dialog.openForTask({ id: 8, title: "旧任务", categoryId: -1, date: "2026-06-30" });
        wait(20);

        compare(dialog.dateOffsetSelection, -1);
        compare(dialog.resultIsoDate(), "2026-06-30");

        const originalText = findChild(dialog, "editOriginalDateText");
        verify(originalText);
        verify(originalText.text.indexOf("2026-06-30") !== -1);
    }

    function test_submitEmitsEditedValues() {
        dialog.openForTask({ id: 9, title: "旧标题", categoryId: -1, date: isoWithOffset(0) });
        wait(20);

        const titleField = findChild(dialog, "editTitleField");
        titleField.text = "  新标题  ";
        const tomorrowChip = findChild(dialog, "editDateTomorrow");
        verify(tomorrowChip);
        tomorrowChip.clicked();
        compare(dialog.dateOffsetSelection, 1);

        dialog.submit();
        compare(editedSpy.count, 1);
        compare(editedSpy.signalArguments[0][0], 9);
        compare(editedSpy.signalArguments[0][1], "新标题");
        compare(editedSpy.signalArguments[0][2], -1);
        compare(editedSpy.signalArguments[0][3], isoWithOffset(1));
    }

    function test_blankTitleBlocksSubmit() {
        dialog.openForTask({ id: 10, title: "有内容", categoryId: -1, date: isoWithOffset(0) });
        wait(20);

        const titleField = findChild(dialog, "editTitleField");
        titleField.text = "   ";
        dialog.submit();

        compare(editedSpy.count, 0);
        verify(dialog.errorText.length > 0);
    }
}
```

- [x] **Step 2: 运行确认失败**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_edit_task_dialog.qml 2>/dev/null | grep -E "FAIL|Totals|error"`
Expected: FAIL（组件不存在 → compile 错误）。

- [x] **Step 3: 写实现**

新建 `qml/components/EditTaskDialog.qml`（结构参照 AddTaskDialog 的 Popup 骨架，字段更少）：

```qml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

// 任务编辑弹窗：标题 + 科目 + 日期快捷项（今天/明天/后天）。
// 日期不命中快捷项时三个 chip 全不选中，保留原日期；这是"编辑不应悄悄改日期"的防线。
Popup {
    id: root

    property var categoryManagerRef: null
    property var categoryOptions: [{ id: -1, name: "不设置科目", color: "" }]
    property int editingTaskId: -1
    property string originalIsoDate: ""
    property int dateOffsetSelection: -1
    property string errorText: ""

    signal taskEdited(int taskId, string title, int categoryId, var isoDate)

    modal: true
    anchors.centerIn: parent
    width: 420
    padding: Theme.space24

    function isoWithOffset(offset) {
        var d = new Date()
        d.setDate(d.getDate() + offset)
        return Qt.formatDate(d, "yyyy-MM-dd")
    }

    function normalizedIso(value) {
        if (value instanceof Date) {
            return Qt.formatDate(value, "yyyy-MM-dd")
        }
        // modelData.date 可能是 Date 也可能是 ISO 字符串（含带时间的变体），只取日期段。
        return String(value || "").substring(0, 10)
    }

    function refreshCategories() {
        var options = [{ id: -1, name: "不设置科目", color: "" }]
        if (root.categoryManagerRef && root.categoryManagerRef.getAllCategories) {
            var actives = root.categoryManagerRef.getAllCategories()
            for (var i = 0; i < actives.length; i++) {
                options.push(actives[i])
            }
        }
        root.categoryOptions = options
    }

    function openForTask(task) {
        root.errorText = ""
        root.editingTaskId = Number(task.id)
        titleField.text = String(task.title || "")
        root.originalIsoDate = root.normalizedIso(task.date)

        root.refreshCategories()
        var targetId = Number(task.categoryId || -1)
        var index = 0
        for (var i = 0; i < root.categoryOptions.length; i++) {
            if (Number(root.categoryOptions[i].id || -1) === targetId) {
                index = i
                break
            }
        }
        categoryCombo.currentIndex = index

        root.dateOffsetSelection = -1
        for (var offset = 0; offset <= 2; offset++) {
            if (root.isoWithOffset(offset) === root.originalIsoDate) {
                root.dateOffsetSelection = offset
                break
            }
        }

        root.open()
        titleField.forceActiveFocus()
    }

    function resultIsoDate() {
        return root.dateOffsetSelection < 0
                ? root.originalIsoDate
                : root.isoWithOffset(root.dateOffsetSelection)
    }

    function submit() {
        var title = titleField.text.trim()
        if (title.length === 0) {
            root.errorText = "任务内容不能为空"
            return
        }
        var categoryId = categoryCombo.currentIndex >= 0
                && categoryCombo.currentIndex < root.categoryOptions.length
                ? Number(root.categoryOptions[categoryCombo.currentIndex].id || -1)
                : -1
        root.taskEdited(root.editingTaskId, title, categoryId, root.resultIsoDate())
        root.close()
    }

    component DateChip: Button {
        id: chip

        property int offset: 0

        checkable: false
        checked: root.dateOffsetSelection === chip.offset
        implicitWidth: 72
        implicitHeight: 34
        onClicked: root.dateOffsetSelection = chip.offset

        background: Rectangle {
            color: chip.checked ? Theme.accent : (chip.hovered ? Theme.surface : Theme.surfaceRaised)
            border.color: chip.checked ? Theme.accentStrong : Theme.border
            border.width: 1
            radius: Theme.radiusMd
        }

        contentItem: Text {
            text: chip.text
            textFormat: Text.PlainText
            color: chip.checked ? Theme.surface : Theme.ink
            font.pixelSize: Theme.fontMd
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    background: Rectangle {
        color: Theme.surface
        border.color: Theme.border
        border.width: 1
        radius: Theme.radiusLg
    }

    Overlay.modal: Rectangle {
        color: "#66000000"
    }

    contentItem: ColumnLayout {
        spacing: Theme.space16

        Text {
            text: "编辑任务"
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontXl
            font.weight: Font.Bold
            color: Theme.inkStrong
        }

        TextField {
            id: titleField

            objectName: "editTitleField"
            Layout.fillWidth: true
            placeholderText: "任务内容"
            font.pixelSize: Theme.fontMd
            color: Theme.inkStrong
            selectByMouse: true

            background: Rectangle {
                color: Theme.surfaceSunken
                border.color: titleField.activeFocus ? Theme.accent : Theme.border
                border.width: 1
                radius: Theme.radiusMd
            }

            Keys.onReturnPressed: root.submit()
            Keys.onEnterPressed: root.submit()
        }

        ComboBox {
            id: categoryCombo

            objectName: "editCategoryCombo"
            Layout.fillWidth: true
            model: root.categoryOptions
            textRole: "name"
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space8

            Text {
                text: "日期"
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
            }

            DateChip {
                objectName: "editDateToday"
                text: "今天"
                offset: 0
            }

            DateChip {
                objectName: "editDateTomorrow"
                text: "明天"
                offset: 1
            }

            DateChip {
                objectName: "editDateDayAfter"
                text: "后天"
                offset: 2
            }

            Text {
                objectName: "editOriginalDateText"
                visible: root.dateOffsetSelection < 0
                text: "保留 " + root.originalIsoDate
                textFormat: Text.PlainText
                color: Theme.inkMuted
                font.pixelSize: Theme.fontSm
            }

            Item {
                Layout.fillWidth: true
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root.errorText.length > 0
            text: root.errorText
            textFormat: Text.PlainText
            color: Theme.danger
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: Theme.space12

            Button {
                id: cancelButton

                text: "取消"
                implicitWidth: 80
                implicitHeight: 36
                onClicked: root.close()

                background: Rectangle {
                    color: cancelButton.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
                    border.color: Theme.border
                    border.width: 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: cancelButton.text
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Button {
                id: confirmButton

                objectName: "editConfirmButton"
                text: "保存"
                implicitWidth: 80
                implicitHeight: 36
                onClicked: root.submit()

                background: Rectangle {
                    color: confirmButton.hovered ? Theme.accentStrong : Theme.accent
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: confirmButton.text
                    textFormat: Text.PlainText
                    color: Theme.surface
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
```

`resources/qml.qrc` 的 components 区加：

```xml
        <file alias="qml/components/EditTaskDialog.qml">../qml/components/EditTaskDialog.qml</file>
```

- [x] **Step 4: qmllint + 测试确认通过**

Run: `/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/components/EditTaskDialog.qml && /Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_edit_task_dialog.qml 2>/dev/null | grep -E "FAIL|Totals"`
Expected: lint 无输出；全部 PASS 连跑 2 次。

- [x] **Step 5: 提交**

```bash
git add qml/components/EditTaskDialog.qml resources/qml.qrc tests/qml/tst_edit_task_dialog.qml
git commit -m "新增任务编辑弹窗组件"
```

---

### Task 4: 视图与 MainWindow 接线（编辑 + 延迟删除撤销）

**Files:**

- Modify: `qml/views/TodayTaskView.qml`
- Modify: `qml/views/WeekPlanView.qml`
- Modify: `qml/MainWindow.qml`
- Test: `tests/qml/tst_focus_start_flow.qml`、`tests/qml/tst_today_rollover.qml`

**Interfaces:**

- Consumes: Task 1 的 Toast action、Task 2 的信号、Task 3 的 EditTaskDialog、第一部分的 `updateTask`
- Produces:

  - 视图信号 `deleteRequested(int taskId, string title)` + `property int pendingDeleteTaskId: -1`（加载时过滤该行）
  - MainWindow：`function requestDeleteTask(taskId, title)`、`commitPendingDelete()`、`cancelPendingDelete()`、`property int pendingDeleteTaskId`、`property int deleteCommitDelayMs: 5000`

- [x] **Step 1: 写失败测试**

`tests/qml/tst_focus_start_flow.qml` 的 taskManager 桩加删除记录（属性区 + 函数替换）：

```qml
        property int deleteTaskCalls: 0
        property int lastDeletedTaskId: -1
```

```qml
        function deleteTask(id) {
            deleteTaskCalls += 1;
            lastDeletedTaskId = id;
            return true;
        }
```

`init()` 里加重置：

```qml
        taskManager.deleteTaskCalls = 0;
        taskManager.lastDeletedTaskId = -1;
        mainWindow.cancelPendingDelete();
```

文件末尾加：

```qml
    function test_deleteIsDeferredAndUndoable() {
        mainWindow.deleteCommitDelayMs = 60;

        mainWindow.requestDeleteTask(21, "误删任务");
        compare(mainWindow.pendingDeleteTaskId, 21);
        compare(taskManager.deleteTaskCalls, 0);

        var toast = findChild(mainWindow, "globalToast");
        verify(toast);
        compare(toast.shown, true);
        compare(toast.actionText, "撤销");

        toast.triggerAction();
        compare(mainWindow.pendingDeleteTaskId, -1);
        wait(120);
        compare(taskManager.deleteTaskCalls, 0); // 撤销后超时也不会删

        mainWindow.deleteCommitDelayMs = 5000;
    }

    function test_deleteCommitsAfterTimeout() {
        mainWindow.deleteCommitDelayMs = 60;

        mainWindow.requestDeleteTask(22, "真删任务");
        tryCompare(taskManager, "deleteTaskCalls", 1, 2000);
        compare(taskManager.lastDeletedTaskId, 22);
        compare(mainWindow.pendingDeleteTaskId, -1);

        mainWindow.deleteCommitDelayMs = 5000;
    }

    function test_secondDeleteCommitsFirstImmediately() {
        mainWindow.deleteCommitDelayMs = 5000;

        mainWindow.requestDeleteTask(23, "第一个");
        mainWindow.requestDeleteTask(24, "第二个");

        compare(taskManager.deleteTaskCalls, 1);
        compare(taskManager.lastDeletedTaskId, 23);
        compare(mainWindow.pendingDeleteTaskId, 24);

        mainWindow.cancelPendingDelete();
    }
```

`tests/qml/tst_today_rollover.qml` 文件末尾加过滤用例：

```qml
    function test_pendingDeleteFiltersRow() {
        taskManager.todayTasksData = [
            { id: 31, title: "留下", completed: false, date: "2026-07-06", categoryId: -1 },
            { id: 32, title: "待删", completed: false, date: "2026-07-06", categoryId: -1 }
        ];
        view.refresh();
        wait(20);
        compare(view.tasks.length, 2);

        view.pendingDeleteTaskId = 32;
        wait(20);
        compare(view.tasks.length, 1);
        compare(Number(view.tasks[0].id), 31);

        view.pendingDeleteTaskId = -1;
        wait(20);
        compare(view.tasks.length, 2);
    }
```

- [x] **Step 2: 运行确认失败**

Run:

```bash
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_start_flow.qml 2>/dev/null | grep -E "FAIL|Totals"
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_today_rollover.qml 2>/dev/null | grep -E "FAIL|Totals"
```

Expected: 新用例 FAIL（`requestDeleteTask`/`pendingDeleteTaskId` 不存在）。

- [x] **Step 3: 写实现**

**`qml/MainWindow.qml`**：属性区加：

```qml
    property int pendingDeleteTaskId: -1
    property string pendingDeleteTitle: ""
    property int deleteCommitDelayMs: 5000
```

函数区（`showToast` 之后）加：

```qml
    function requestDeleteTask(taskId, taskTitle) {
        // 单槽撤销：新删除到来先把上一个真正落库，撤销窗口只保护最近一次。
        root.commitPendingDelete();

        root.pendingDeleteTaskId = taskId;
        root.pendingDeleteTitle = String(taskTitle || "");
        deleteCommitTimer.interval = root.deleteCommitDelayMs;
        deleteCommitTimer.restart();
        root.showToast("已删除「" + root.pendingDeleteTitle + "」", "撤销", function () {
            root.cancelPendingDelete();
        });
    }

    function commitPendingDelete() {
        if (root.pendingDeleteTaskId <= 0) {
            return;
        }
        deleteCommitTimer.stop();
        // 到这里才真正触库；撤销窗口内数据库从未被碰过，专注记录关联零损失。
        taskManager.deleteTask(root.pendingDeleteTaskId);
        root.pendingDeleteTaskId = -1;
        root.pendingDeleteTitle = "";
    }

    function cancelPendingDelete() {
        deleteCommitTimer.stop();
        root.pendingDeleteTaskId = -1;
        root.pendingDeleteTitle = "";
    }
```

根 Item 内（Toast 实例旁）加：

```qml
    Timer {
        id: deleteCommitTimer

        interval: 5000
        onTriggered: root.commitPendingDelete()
    }
```

TodayTaskView 实例加两行 + 删除处理：

```qml
                    pendingDeleteTaskId: root.pendingDeleteTaskId

                    onDeleteRequested: function (taskId, taskTitle) {
                        root.requestDeleteTask(taskId, taskTitle);
                    }
```

WeekPlanView 实例加同样两段。

**`qml/views/TodayTaskView.qml`**：

信号区加 `signal deleteRequested(int taskId, string title)`；属性区加 `property int pendingDeleteTaskId: -1`，以及：

```qml
    onPendingDeleteTaskIdChanged: refresh()
```

`loadTasks()` 里 `root.tasks = taskManager.getTodayTasks();` 改为：

```qml
            var loaded = taskManager.getTodayTasks();
            // 待删除行先从视图消失（乐观 UI）；撤销把 pendingDeleteTaskId 清回 -1 后自动恢复。
            root.tasks = root.pendingDeleteTaskId > 0
                    ? loaded.filter(function (task) {
                          return Number(task.id) !== root.pendingDeleteTaskId;
                      })
                    : loaded;
```

TaskItem delegate 的 `onDeleteClicked` 改为上抛：

```qml
                            onDeleteClicked: function (id, title) {
                                root.deleteRequested(id, title);
                            }
```

delegate 加编辑接线（`onDeleteClicked` 旁）：

```qml
                            onRenameSubmitted: function (id, newTitle) {
                                var originalCategoryId = Number(modelData.categoryId || -1);
                                var originalDate = Qt.formatDate(modelData.date, "yyyy-MM-dd") || String(modelData.date || "").substring(0, 10);
                                if (!taskManager.updateTask(id, newTitle, originalCategoryId, originalDate)) {
                                    root.loadError = "任务更新失败，请重试";
                                }
                            }

                            onEditClicked: function (id) {
                                editTaskDialog.openForTask(modelData);
                            }
```

文件尾部（AddTaskDialog 实例旁）加：

```qml
    EditTaskDialog {
        id: editTaskDialog

        parent: root
        categoryManagerRef: root.categoryManagerRef

        onTaskEdited: function (taskId, title, categoryId, isoDate) {
            if (!taskManager.updateTask(taskId, title, categoryId, isoDate)) {
                root.loadError = "任务更新失败，请重试";
            }
        }
    }
```

**`qml/views/WeekPlanView.qml`**：同构改造——

信号区加 `signal deleteRequested(int taskId, string title)`；属性区加 `property int pendingDeleteTaskId: -1` 与 `onPendingDeleteTaskIdChanged: refresh()`。

`refresh()` 里 `root.weekTasks = taskManager.getWeekTasks(root.isoDate(root.weekStart))` 改为：

```qml
            var loaded = taskManager.getWeekTasks(root.isoDate(root.weekStart))
            root.weekTasks = root.pendingDeleteTaskId > 0
                    ? loaded.filter(function (task) {
                          return Number(task.id) !== root.pendingDeleteTaskId;
                      })
                    : loaded
```

TaskItem delegate（`onDeleteClicked` 处，约 467 行）改为上抛，并在其旁加编辑接线：

```qml
                                    onDeleteClicked: function(id, title) {
                                        root.deleteRequested(id, title)
                                    }

                                    onRenameSubmitted: function(id, newTitle) {
                                        var originalCategoryId = Number(modelData.categoryId || -1)
                                        var originalDate = Qt.formatDate(modelData.date, "yyyy-MM-dd") || String(modelData.date || "").substring(0, 10)
                                        if (!taskManager.updateTask(id, newTitle, originalCategoryId, originalDate)) {
                                            root.loadError = "任务更新失败，请重试"
                                        }
                                    }

                                    onEditClicked: function(id) {
                                        editTaskDialog.openForTask(modelData)
                                    }
```

文件尾部（AddTaskDialog 实例旁）加：

```qml
    EditTaskDialog {
        id: editTaskDialog

        parent: root
        categoryManagerRef: root.categoryManagerRef

        onTaskEdited: function (taskId, title, categoryId, isoDate) {
            if (!taskManager.updateTask(taskId, title, categoryId, isoDate)) {
                root.loadError = "任务更新失败，请重试"
            }
        }
    }
```

- [x] **Step 4: qmllint + 测试确认通过**

Run:

```bash
/Users/zerionlito/Qt/6.9.0/macos/bin/qmllint qml/MainWindow.qml qml/views/TodayTaskView.qml qml/views/WeekPlanView.qml
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_focus_start_flow.qml 2>/dev/null | grep -E "FAIL|Totals"
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_today_rollover.qml 2>/dev/null | grep -E "FAIL|Totals"
/Users/zerionlito/Qt/6.9.0/macos/bin/qmltestrunner -input tests/qml/tst_ui_optimization.qml 2>/dev/null | grep -E "Totals"
```

Expected: lint 无输出；前两个文件全 PASS 连跑 2 次；`tst_ui_optimization` 维持既有水平（其今日页桩的 `deleteTask` 直调路径已改为上抛信号，若有用例断言"点删除后 taskManager.deleteTask 被调"需改为断言视图发出 `deleteRequested` 信号——用 `SignalSpy { target: view; signalName: "deleteRequested" }`）。

- [x] **Step 5: 全量回归 + 真机冒烟 + 提交**

```bash
cmake --build build && ctest --test-dir build --output-on-failure
open /Applications/番茄Todo.app
```

人工核对：双击标题改字回车生效；hover 出现编辑/删除；编辑弹窗改科目/推到明天生效；删除后 Toast 撤销可救回、不撤销 5 秒后消失；昨天造一条未完成任务重启后横幅结转（与第一部分联动）。

```bash
git add qml/MainWindow.qml qml/views/TodayTaskView.qml qml/views/WeekPlanView.qml tests/qml/tst_focus_start_flow.qml tests/qml/tst_today_rollover.qml
git commit -m "接线任务编辑与延迟删除撤销"
```
