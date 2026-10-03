pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtTest
import "../../qml"
import "../../qml/views"
import "fixtures"

TestCase {
    id: testCase
    name: "MemoView"
    when: windowShown
    visible: true
    width: 816
    height: 768
    property var view: null
    property bool oldReduceMotion: false
    MemoServiceMock {
        id: service
    }
    MemoCategoryMock {
        id: categories
    }
    SignalSpy {
        id: bodyChanges
        signalName: "editorBodyChanged"
    }
    QtObject {
        id: keyboardMock
        property bool visible: false
        property rect keyboardRectangle: Qt.rect(0, 0, 0, 0)
        // 记录页面要求输入法提交组合文字的次数。离屏平台的真输入法 commit() 是空操作，看不出有没有被调用。
        property int commits: 0
        function commit() {
            commits += 1;
        }
    }
    Component {
        id: viewComponent
        MemoView {
            width: testCase.width
            height: testCase.height
            memoServiceRef: service
            categoryManagerRef: categories
            // qmllint disable unqualified
            textLayoutRef: typeof memoTextLayout === "undefined" ? null : memoTextLayout
            // qmllint enable unqualified
        }
    }
    function fixture() {
        return [service.makeRecord(11, "数学进度", "第八讲做完\n第二行不在预览里", 1), service.makeRecord(12, "第二条", "积分练习", 1), service.makeRecord(21, "物理进度", "力学第一章", 2), service.makeRecord(31, "", "没有科目的记录", 0)];
    }
    function initTestCase() {
        oldReduceMotion = Theme.reduceMotion;
        Theme.reduceMotion = true;
    }
    function cleanupTestCase() {
        Theme.reduceMotion = oldReduceMotion;
    }
    function init() {
        // 和 ctest 的失败规则一致：出现绑定循环就算失败。直接跑单个用例、做变异验证时也照样拦住。
        failOnWarning(/Binding loop/);
        keyboardMock.visible = false;
        keyboardMock.keyboardRectangle = Qt.rect(0, 0, 0, 0);
        keyboardMock.commits = 0;
        service.reset(fixture());
        categories.records = [
            {
                id: 1,
                name: "高等数学与概率统计特别长的科目名称",
                color: "#98753c"
            },
            {
                id: 2,
                name: "物理",
                color: "#a35f44"
            },
            {
                id: 3,
                name: "还没有备忘的科目",
                color: "#467c7c"
            }
        ];
        view = createTemporaryObject(viewComponent, testCase);
        verify(view);
        tryCompare(view, "selectedId", 11, 3000);
        tryVerify(function () {
            return findChild(view, "memoRow11") !== null;
        }, 3000);
    }
    function child(name) {
        var result = findChild(view, name);
        verify(result !== null, name);
        return result;
    }
    function typeBody(text) {
        var input = child("memoBodyInput");
        input.selectAll();
        input.remove(0, input.length);
        // insert 是 TextEdit 原生编辑接口，避免模拟几千次按键。这里不再手动补发 textEdited：
        // 页面必须靠文字本身的变化认出修改，补发信号会掩盖「输入法上屏不发 textEdited」这类缺陷。
        input.insert(0, text);
    }
    // 走真实输入法路径上屏一段文字（iPad 软键盘、Mac 拼音选字都是这条路）。
    function imeCommit(input, text) {
        input.forceActiveFocus(Qt.MouseFocusReason);
        input.cursorPosition = input.length;
        // qmllint disable unqualified
        verify(inputMethodProbe.commit(input, text), "前置：输入法事件送到了这个输入框");
        // qmllint enable unqualified
    }
    function typeTitle(text) {
        var input = child("memoTitleInput");
        input.selectAll();
        input.remove(0, input.length);
        input.insert(0, text);
        input.textEdited();
    }
    // 产品保证：分类只列有内容的科目；未分类仅在确有无科目记录时出现。
    function test_capsulesOnlyForUsedCategories() {
        compare(view.capsules.map(function (c) {
            return c.id;
        }).join(","), "-1,1,2,0");
        verify(findChild(view, "memoFilter3") === null);
        service.records = fixture().filter(function (r) {
            return r.categoryId !== 0;
        });
        service.memosChanged();
        tryVerify(function () {
            return findChild(view, "memoFilter0") === null;
        }, 3000);
    }
    // 产品保证：超长科目名不扩大胶囊，也不推走同一行其它胶囊；组头条数始终留在框内。
    function test_longCategoryGeometryAndCount() {
        var pill = child("memoFilter1");
        var all = child("memoFilter-1");
        var other = child("memoFilter2");
        verify(categories.records[0].name.length > 7);
        verify(pill.width <= view.capsuleMaxWidth);
        compare(pill.Accessible.name, categories.records[0].name);
        compare(pill.ToolTip.text, categories.records[0].name);
        compare(pill.y, all.y);
        var x = other.x, y = other.y;
        categories.records = [
            {
                id: 1,
                name: "高等数学与概率统计特别长的科目名称再增加十个字",
                color: "#98753c"
            },
            categories.records[1], categories.records[2]];
        categories.categoriesChanged();
        tryCompare(child("memoFilter2"), "x", x, 3000);
        compare(child("memoFilter2").y, y);
        var group = child("memoGroup1");
        var name = findChild(group, "memoGroupName");
        var count = findChild(group, "memoGroupCount");
        verify(name.truncated);
        compare(count.text, " · 2");
        verify(count.x + count.width <= group.width + 0.1);
    }
    // 产品保证：短科目名和“全部”完整显示，不能为满足限宽把正常文字也挤成省略号。
    function test_shortCapsuleTextIsNotElided() {
        var all = child("memoFilter-1");
        var other = child("memoFilter2");
        compare(all.contentItem.truncated, false);
        compare(other.contentItem.truncated, false);
    }
    // 产品保证：分类放不下时换行；单科列表不带组头。
    function test_flowWrapAndSingleCategorySections() {
        categories.records = categories.records.concat([
            {
                id: 4,
                name: "化学与实验进度",
                color: "#98753c"
            },
            {
                id: 5,
                name: "英语阅读与写作",
                color: "#98753c"
            }
        ]);
        service.records = service.records.concat([service.makeRecord(41, "化学", "", 4), service.makeRecord(51, "英语", "", 5)]);
        service.memosChanged();
        tryVerify(function () {
            return findChild(view, "memoFilter5") !== null;
        }, 3000);
        var pills = [child("memoFilter-1"), child("memoFilter1"), child("memoFilter2"), child("memoFilter4"), child("memoFilter5"), child("memoFilter0")];
        verify(pills.reduce(function (sum, pill) {
            return sum + pill.width + Theme.space8;
        }, 0) > 256, "前置：胶囊实际总宽超出左栏");
        tryVerify(function () {
            return child("memoFilter0").y > child("memoFilter-1").y;
        }, 3000);
        view.selectFilter(1);
        tryCompare(child("memoList"), "count", 2, 3000);
        tryVerify(function () {
            return findChild(view, "memoGroup1") === null;
        }, 3000);
    }
    // 产品保证：选中行沿用导航配色；列表的上下键改变所选备忘，不改变排序。
    function test_selectionTokensAndKeyboard() {
        var row = child("memoRow11");
        compare(findChild(row, "memoRowBackground").color, Theme.accentFill);
        compare(findChild(row, "memoRowTitle").color, Theme.accentFillInk);
        compare(findChild(row, "memoRowPreview").color, Theme.accentFillInk);
        compare(findChild(row, "memoRowTime").color, Theme.accentFillInk);
        var list = child("memoList");
        list.forceActiveFocus();
        keyClick(Qt.Key_Down);
        tryCompare(view, "selectedId", 12, 3000);
        keyClick(Qt.Key_Up);
        tryCompare(view, "selectedId", 11, 3000);
        compare(service.reorders.length, 0);
    }
    // 产品保证：空草稿切走不写库；首次有内容才建一行，后续编辑只更新该行。
    function test_emptyDraftAndCreateOnce() {
        view.startDraft();
        verify(view.drafting);
        view.selectMemo(11);
        compare(service.creates.length, 0);
        view.selectFilter(2);
        view.startDraft();
        compare(view.editorCategoryId, 2);
        typeBody("新进度");
        view.saveNow();
        compare(service.creates.length, 1);
        compare(service.creates[0].categoryId, 2);
        verify(view.selectedId > 0);
        typeTitle("补标题");
        view.saveNow();
        compare(service.creates.length, 1);
        compare(Object.keys(service.updates[0].changes).join(","), "title");
    }
    // 产品保证：全部和未分类中新建均不预选科目。
    function test_draftDefaultCategory() {
        for (var id of [-1, 0]) {
            view.selectFilter(id);
            view.startDraft();
            compare(view.editorCategoryId, 0);
            typeBody("未分类新备忘" + id);
            view.saveNow();
            compare(service.creates[service.creates.length - 1].categoryId, 0);
        }
    }
    // 产品保证：停止输入一秒、换备忘和离开页面都保存，且只发实际改过的字段。
    function test_autosaveTimingsAndChangedFields() {
        typeBody("停止输入的版本");
        compare(service.updates.length, 0);
        tryCompare(service, "updates", [
            {
                id: 11,
                changes: {
                    body: "停止输入的版本"
                }
            }
        ], 4000);
        typeTitle("切换前的新标题");
        view.selectMemo(12);
        compare(service.updates.length, 2);
        compare(Object.keys(service.updates[1].changes).join(","), "title");
        typeBody("离开页面的版本");
        view.pageActive = false;
        compare(service.updates.length, 3);
        compare(service.updates[2].id, 12);
    }
    // 产品保证：正文超限不截断、不发写入请求，并明确提示多出的字数。
    function test_bodyOverLimitRemainsInEditor() {
        var text = "甲".repeat(service.maxBodyLength + 37);
        verify(text.length > service.maxBodyLength);
        typeBody(text);
        compare(view.saveNow(), false);
        compare(service.updates.length, 0);
        compare(child("memoBodyInput").text, text);
        verify(child("memoError").text.indexOf("37") >= 0);
    }
    // 产品保证：标题限制与服务一致，60 个表情也可以完整输入。
    function test_titleUnicodeLimit() {
        typeTitle("🙂".repeat(61));
        compare(Array.from(child("memoTitleInput").text).length, 60);
        view.saveNow();
        compare(Array.from(service.updates[0].changes.title).length, 60);
    }
    // 产品保证：保存失败不会丢输入，错误原因留在编辑区。
    function test_failedSaveKeepsContent() {
        service.failSave = true;
        typeBody("还没能保存的文字");
        compare(view.saveNow(), false);
        compare(child("memoBodyInput").text, "还没能保存的文字");
        compare(child("memoError").text, "磁盘不可写");
        verify(view.dirty);
        view.selectMemo(12);
        compare(view.selectedId, 11);
    }
    // 产品保证：远端更新会刷新干净编辑框；有本机修改时保留输入和所选编号。
    function test_remoteRefreshProtectsDirtyEditor() {
        var values = fixture();
        values[0].body = "远端第一版";
        service.records = values;
        service.memosChanged();
        tryCompare(view, "editorBody", "远端第一版", 3000);
        typeBody("本机未保存的第二版");
        verify(view.dirty);
        values = fixture();
        values[0].body = "远端第二版";
        service.records = values;
        service.memosChanged();
        compare(view.editorBody, "本机未保存的第二版");
        compare(child("memoBodyInput").text, "本机未保存的第二版");
        compare(view.selectedId, 11);
    }
    // 产品保证：科目最后一条备忘被远端删除时，消失的筛选不能让页面卡在一个不可选的科目。
    function test_removedLastCategoryResetsFilterAndKeepsNeighbor() {
        view.selectFilter(2);
        compare(view.selectedId, 21);
        compare(view.idsForCategory(2).length, 1);
        service.records = service.records.filter(function (entry) {
            return entry.id !== 21;
        });
        service.memosChanged();
        tryCompare(view, "filterCategoryId", -1, 3000);
        compare(view.selectedId, 31);
        tryVerify(function () {
            return findChild(view, "memoFilter2") === null;
        }, 3000);
        compare(child("memoFilter-1").selected, true);
    }
    // 产品保证：远端删当前记录，干净时选相邻项；有草稿时保住草稿并说明删除。
    function test_remoteDeleteCleanAndDirty() {
        service.records = fixture().filter(function (r) {
            return r.id !== 11;
        });
        service.memosChanged();
        tryCompare(view, "selectedId", 12, 3000);
        typeBody("被删之前尚未保存的文字");
        verify(view.dirty);
        service.records = service.records.filter(function (r) {
            return r.id !== 12;
        });
        service.memosChanged();
        compare(view.selectedId, 12);
        compare(view.editorBody, "被删之前尚未保存的文字");
        verify(view.remoteDeleted);
        verify(view.errorMessage.indexOf("另一台设备删除") >= 0);
        compare(view.saveNow(), false);
        compare(service.updates.length, 0);
    }
    // 产品保证：删除必须先确认；取消不动数据，确认只删所选条目。
    function test_deleteRequiresConfirmation() {
        mouseClick(child("memoDeleteButton"));
        tryCompare(view, "pendingDeleteId", 11, 3000);
        compare(service.deletes.length, 0);
        mouseClick(child("memoDeleteCancel"));
        compare(service.deletes.length, 0);
        view.requestDelete();
        tryVerify(function () {
            return child("memoDeleteConfirm").opened;
        }, 3000);
        mouseClick(child("memoDeleteConfirmButton"));
        tryCompare(service, "deletes", [11], 3000);
    }
    // 产品保证：拖动期间模型不改，松手以同科完整列表重排；跨科目不能落下。
    function test_dragFullListAndRejectOtherCategory() {
        service.records = service.records.concat([service.makeRecord(13, "同科第三条", "", 1)]);
        service.memosChanged();
        var list = child("memoList");
        compare(view.idsForCategory(1).length, 3);
        verify(service.records[0].categoryId !== service.records[2].categoryId);
        view.beginDrag(11);
        view.setDropTarget(21);
        view.finishDrag(false);
        compare(service.reorders.length, 0);
        view.beginDrag(11);
        view.setDropTarget(12);
        compare(list.model.get(0).memoId, 11);
        compare(service.reorders.length, 0);
        view.finishDrag(false);
        compare(service.reorders.length, 1);
        compare(service.reorders[0].categoryId, 1);
        compare(service.reorders[0].ids.join(","), "12,11,13");
    }
    // 产品保证：拖动中收到远端刷新时取消本机拖动，不提交过期顺序，也不能把列表卡在不可滚动状态。
    function test_remoteRefreshCancelsNativeDrag() {
        var row = child("memoRow11");
        var p = row.mapToItem(view, 70, row.height / 2);
        mousePress(view, p.x, p.y, Qt.LeftButton);
        mouseMove(view, p.x, p.y + 25, 20, Qt.LeftButton);
        tryCompare(view, "draggingId", 11, 3000);
        var records = fixture();
        records[0].body = "远端更新后的正文";
        service.records = records;
        service.memosChanged();
        mouseRelease(view, p.x, p.y + 25, Qt.LeftButton);
        tryCompare(view, "draggingId", -1, 3000);
        compare(service.reorders.length, 0);
        compare(child("memoList").interactive, true);
        compare(view.selectedId, 11);
        compare(view.editorBody, "远端更新后的正文");
    }
    // 产品保证：Mac 按住行直接拖的真实事件也会触发完整列表重排。
    function test_mouseDragUsesProductionHandler() {
        var row = child("memoRow11"), target = child("memoRow12");
        var p = target.mapToItem(row, 60, target.height / 2);
        mousePress(row, 60, row.height / 2, Qt.LeftButton);
        for (var i = 1; i <= 8; ++i)
            mouseMove(row, 60, row.height / 2 + (p.y - row.height / 2) * i / 8, 20, Qt.LeftButton);
        mouseRelease(row, 60, p.y, Qt.LeftButton);
        tryVerify(function () {
            return service.reorders.length === 1;
        }, 3000);
        compare(service.reorders[0].ids.join(","), "12,11");
    }
    // 产品保证：触屏普通滑动只滚列表；长按后才允许排序，且拖动期间列表不自行滑动。
    function test_touchScrollAndLongPressDrag() {
        var many = [];
        for (var i = 0; i < 20; ++i)
            many.push(service.makeRecord(200 + i, "长列表" + i, "正文", 1));
        service.records = many;
        service.memosChanged();
        var list = child("memoList");
        tryVerify(function () {
            return list.contentHeight > list.height;
        }, 3000);
        var touch = touchEvent(list);
        touch.press(0, list, 80, 300).commit();
        for (var j = 0; j < 6; ++j) {
            touch.move(0, list, 80, 300 - (j + 1) * 30).commit();
            wait(20);
        }
        touch.release(0, list, 80, 120).commit();
        tryVerify(function () {
            return list.contentY > 0;
        }, 3000);
        compare(service.reorders.length, 0);
        list.cancelFlick();
        list.contentY = 0;
        tryVerify(function () {
            return findChild(view, "memoRow200") !== null;
        }, 3000);
        var row = child("memoRow200");
        var second = child("memoRow201");
        touch = touchEvent(row);
        touch.press(0, row, 80, row.height / 2).commit();
        tryCompare(view, "touchArmedId", 200, 3000);
        compare(list.interactive, false);
        var p = second.mapToItem(row, 80, second.height / 2);
        touch.move(0, row, 80, p.y).commit();
        touch.release(0, row, 80, p.y).commit();
        tryCompare(view, "draggingId", -1, 3000);
        tryVerify(function () {
            return service.reorders.length === 1;
        }, 3000);
        compare(service.reorders[0].ids.length, 20);
        compare(service.reorders[0].ids[0], 201);
    }
    // 产品保证：远端删除后保留的草稿可由用户明确另存，不能静默复活被删记录。
    function test_deletedDraftCanBeSavedAsNew() {
        typeBody("需要找回的草稿");
        service.records = fixture().filter(function (r) {
            return r.id !== 11;
        });
        service.memosChanged();
        verify(view.remoteDeleted);
        compare(service.creates.length, 0);
        tryVerify(function () {
            return child("memoRecoverDeleted").width > 0;
        }, 3000);
        waitForRendering(view, 3000);
        mouseClick(child("memoRecoverDeleted"));
        tryCompare(service, "creates", [
            {
                title: "数学进度",
                body: "需要找回的草稿",
                categoryId: 1
            }
        ], 3000);
        verify(view.selectedId !== 11);
        compare(view.editorBody, "需要找回的草稿");
    }
    // 产品保证：浮动键盘覆盖正文时为光标留位置；停靠键盘不与 Qt 原生避让重复叠加。
    // 这里只验证传入矩形后的布局规则，iOS 实际键盘矩形和原生视图平移仍需真机验证。
    function test_floatingKeyboardInsetsWithoutDoublingDockedKeyboard() {
        var input = child("memoBodyInput");
        var scroll = child("memoBodyScroll");
        view.touchUi = true;
        view.inputMethodRef = keyboardMock;
        typeBody("一行正文\n".repeat(100));
        input.forceActiveFocus(Qt.TabFocusReason);
        input.cursorPosition = input.length;
        var window = view.Window.window;
        keyboardMock.keyboardRectangle = Qt.rect(0, window.height - 200, window.width, 200);
        keyboardMock.visible = true;
        compare(view.floatingKeyboardInset, 0);
        var x = scroll.mapToItem(null, 0, 0).x;
        keyboardMock.keyboardRectangle = Qt.rect(x, 400, 260, 160);
        tryVerify(function () {
            return view.floatingKeyboardInset > 0;
        }, 3000);
        tryVerify(function () {
            return input.cursorRectangle.y + input.cursorRectangle.height - scroll.contentY <= scroll.height + 1;
        }, 3000);
        keyboardMock.visible = false;
        tryCompare(view, "floatingKeyboardInset", 0, 3000);
    }
    // 产品保证：真正溢出的列表、正文各用外置滚动条，正文贴页面右缘，列表落在左栏与分隔线之间。
    function test_scrollbarsStayOutsideContent() {
        var values = [];
        for (var i = 0; i < 30; ++i)
            values.push(service.makeRecord(11 + i, "备忘" + i, "正文", 1));
        service.records = values;
        service.memosChanged();
        typeBody("很多行正文\n".repeat(200));
        var list = child("memoList");
        var body = child("memoBodyScroll");
        tryVerify(function () {
            return list.contentHeight > list.height && body.contentHeight > body.height;
        }, 3000);
        var listBar = list.ScrollBar.vertical;
        var bodyBar = body.ScrollBar.vertical;
        tryVerify(function () {
            return listBar.size < 1 && bodyBar.size < 1;
        }, 3000);
        var listPoint = listBar.mapToItem(view, 0, 0);
        var panePoint = list.parent.mapToItem(view, 0, 0);
        verify(listPoint.x > panePoint.x + 256);
        verify(listPoint.x + listBar.width < panePoint.x + 256 + Theme.space16);
        var bodyPoint = bodyBar.mapToItem(view, 0, 0);
        compare(bodyPoint.x + bodyBar.width, view.width);
        compare(bodyBar.height, body.height);
    }
    // 产品保证：大量换行不会因排版卡住或丢字；撤销要撤销文字，而不是只撤销行高。
    function test_manyParagraphsAndUndoText() {
        var text = "正文\n".repeat(1000);
        verify(text.length <= service.maxBodyLength);
        typeBody(text);
        var input = child("memoBodyInput");
        compare(input.text, text);
        input.cursorPosition = input.length;
        input.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_X);
        tryVerify(function () {
            return input.text.endsWith("x");
        }, 3000);
        input.undo();
        tryCompare(input, "text", text, 3000);
    }
    // 产品保证：纸面纯文本保留换行，段落行距约为普通字高的 1.5 倍。
    function test_plainTextLineHeightAndFocus() {
        var input = child("memoBodyInput");
        typeBody("第一行\n第二行\n第三行");
        input.forceActiveFocus(Qt.TabFocusReason);
        tryVerify(function () {
            return input.visualFocus;
        }, 3000);
        input.cursorPosition = 0;
        var first = input.cursorRectangle.y, height = input.cursorRectangle.height;
        input.cursorPosition = 4;
        tryVerify(function () {
            return input.cursorRectangle.y > first;
        }, 3000);
        verify(input.cursorRectangle.y - first >= height * 1.4);
        compare(input.textFormat, TextEdit.PlainText);
        compare(input.color, Theme.inputInk);
        compare(input.palette.text, Theme.inputInk);
        compare(input.placeholderTextColor, Theme.inkSoft);
    }
    // 产品保证：用输入法上屏的文字（iPad 软键盘的全部输入、Mac 拼音选字后的中文）和按键一样会保存，切到别的备忘也不丢。
    // 抓住的错误实现：正文只靠 textEdited 判断修改——Qt 6.10 的 TextArea 收到输入法提交时不发这个信号。
    function test_inputMethodTextIsSaved() {
        var body = child("memoBodyInput");
        imeCommit(body, "学习进度");
        compare(body.text, "第八讲做完\n第二行不在预览里学习进度");
        verify(view.dirty);
        view.selectMemo(12);
        compare(service.updates.length, 1);
        compare(service.updates[0].id, 11);
        compare(service.updates[0].changes.body, "第八讲做完\n第二行不在预览里学习进度");
        // 标题框（TextField）同样以输入法提交收字，也必须保存。
        var title = child("memoTitleInput");
        imeCommit(title, "复习");
        view.selectMemo(11);
        compare(service.updates.length, 2);
        compare(service.updates[1].id, 12);
        compare(service.updates[1].changes.title, "第二条复习");
    }
    // 产品保证：拼音还在组合（候选窗开着）时，自动保存照常把已上屏的文字存下，但不打断组合，
    // 不能替用户把拼音原样上屏；只有切换备忘、切页、进后台、退出这类真正打断输入的操作才提交组合。
    // 抓住的错误实现：自动保存定时器调用会先 Qt.inputMethod.commit() 的保存函数（Mac 和 iPad 上会把拼音写进框里）。
    function test_autosaveKeepsCompositionOpen() {
        view.inputMethodRef = keyboardMock;
        var body = child("memoBodyInput");
        imeCommit(body, "复习");
        // qmllint disable unqualified
        verify(inputMethodProbe.compose(body, "jin du"));
        // qmllint enable unqualified
        compare(body.preeditText, "jin du", "前置：下一个词的拼音正在组合");
        compare(service.updates.length, 0, "前置：还没到自动保存");
        tryCompare(service, "updates", [
            {
                id: 11,
                changes: {
                    body: "第八讲做完\n第二行不在预览里复习"
                }
            }
        ], 3000);
        compare(keyboardMock.commits, 0);
        compare(body.preeditText, "jin du");
        view.selectMemo(12);
        compare(keyboardMock.commits, 1);
    }
    // 产品保证：正文滚动条贴在窗口右缘，上下始终和正文区对齐；错误提示出现、正文区下移时，滚动条跟着移动。
    // 抓住的错误实现：用只求值一次的 mapToItem 定位（滚动条停在页面顶部 y=0，盖住页头一侧）。
    function test_bodyScrollbarFollowsEditorLayout() {
        var body = child("memoBodyScroll");
        typeBody("很多行正文\n".repeat(200));
        tryVerify(function () {
            return body.contentHeight > body.height;
        }, 3000);
        var bar = body.ScrollBar.vertical;
        var top = body.mapToItem(view, 0, 0).y;
        verify(top > 100, "前置：正文区在页头和工具栏下面");
        tryCompare(bar, "y", top, 3000);
        compare(bar.height, body.height);
        service.failSave = true;
        verify(!view.saveNow());
        tryVerify(function () {
            return body.mapToItem(view, 0, 0).y > top;
        }, 3000, "前置：错误提示把正文区往下推了");
        tryCompare(bar, "y", body.mapToItem(view, 0, 0).y, 3000);
        compare(bar.height, body.height);
    }
    // 产品保证：新建后什么都没写就点「删除」，草稿直接丢掉，回到新建前选中的那条；列表里有备忘时右侧不会变成「还没有备忘录」。
    // 抓住的错误实现：只清空编辑区、不恢复选中，右侧落到空状态。
    function test_discardEmptyDraftReturnsToPreviousMemo() {
        view.selectMemo(12);
        view.startDraft();
        verify(view.drafting);
        compare(view.selectedId, -1, "前置：草稿状态下没有选中任何一条");
        mouseClick(child("memoDeleteButton"));
        compare(view.drafting, false);
        compare(view.selectedId, 12);
        compare(view.hasEditor, true);
        compare(view.editorTitle, "第二条");
        compare(view.pendingDeleteId, -1, "空草稿不弹确认");
        compare(service.creates.length, 0);
        compare(service.deletes.length, 0);
    }
    // 产品保证：草稿里已经写了字再点「删除」，和普通备忘一样要先确认；取消保住文字，确认后只丢草稿、不写库。
    // 抓住的错误实现：写了字的草稿不经确认就被清掉。
    function test_draftWithTextNeedsConfirmation() {
        view.selectMemo(12);
        view.startDraft();
        typeBody("刚写的一句");
        mouseClick(child("memoDeleteButton"));
        compare(view.pendingDeleteId, 0, "弹出确认，编号 0 表示还没进数据库的草稿");
        view.cancelDelete();
        verify(view.drafting);
        compare(view.editorBody, "刚写的一句");
        view.requestDelete();
        view.confirmDelete();
        compare(view.drafting, false);
        compare(view.selectedId, 12);
        compare(service.creates.length, 0, "前置：整个过程没被自动保存打断");
        compare(service.deletes.length, 0);
    }
    // 产品保证：新建的备忘排在最后，保存后列表自动滚到这一行。
    // 抓住的错误实现：保存新建后只重建列表、不滚动，新行在可视区外，用户找不到刚建的那条。
    function test_newMemoScrollsIntoView() {
        var values = [];
        for (var i = 0; i < 30; ++i)
            values.push(service.makeRecord(300 + i, "备忘" + i, "正文" + i, 1));
        service.records = values;
        service.memosChanged();
        var list = child("memoList");
        tryVerify(function () {
            return list.contentHeight > list.height * 2;
        }, 3000, "前置：列表长到最后一行在可视区外");
        list.positionViewAtBeginning();
        view.startDraft();
        typeBody("新建的一条");
        verify(view.saveNow());
        var row = findChild(view, "memoRow" + view.selectedId);
        verify(row !== null, "新行已在列表里实例化");
        var y = row.mapToItem(list, 0, 0).y;
        verify(y >= 0 && y + row.height <= list.height + 1, "新行在可视区内");
    }
    // 产品保证：组头写成「科目 · 条数」，名字短时条数紧跟在名字后面，不被推到行尾。
    // 抓住的错误实现：名字一栏占满整行，条数被挤到最右边（和定稿不一致）。
    function test_groupCountFollowsShortName() {
        var group = child("memoGroup2");
        var name = findChild(group, "memoGroupName");
        var count = findChild(group, "memoGroupCount");
        verify(name.implicitWidth + count.implicitWidth < group.width / 2, "前置：「物理 · 1」远比组头窄");
        compare(name.truncated, false);
        verify(Math.abs(count.x - (name.x + name.width)) <= 1, "条数紧跟名字");
        verify(count.x + count.width < group.width / 2, "条数没被推到行尾");
    }
    // 产品保证：编辑区左上角的科目按名字宽度显示，最宽 220；名字太长时在 220 内省略。
    // 抓住的错误实现：科目按钮固定占满 220，短名字后面拖一大段空白（和定稿不一致）。
    function test_categoryChipHugsName() {
        var chip = child("memoCategoryButton");
        view.selectMemo(21);
        tryVerify(function () {
            return chip.implicitWidth < 160;
        }, 3000, "前置：「物理」的自然宽度远小于 220");
        compare(chip.width, chip.implicitWidth);
        view.selectMemo(11);
        tryVerify(function () {
            return chip.implicitWidth > 220;
        }, 3000, "前置：超长科目名放不下");
        compare(chip.width, 220);
        verify(findChild(chip, "memoCategoryLabel").truncated);
    }
    // 产品保证：离开备忘录页一段时间再回来，「今天」「昨天」按回来时的时间算，不沿用离开时的时间。
    // 抓住的错误实现：只靠每分钟一次、页面不可见时停走的定时器刷新。
    function test_timeLabelsRefreshOnReturn() {
        var stale = new Date(2020, 0, 1);
        view.pageActive = false;
        // 模拟页面不可见期间时间过去了：定时器停着，记下的时刻还是离开那会儿。
        view.displayNow = stale;
        view.pageActive = true;
        verify(view.displayNow.getTime() > stale.getTime() + 86400000);
    }
    // 产品保证：另一台删掉了正在编辑的备忘时，用户可以明确放弃本机修改，回到原来相邻的一条；之后切换、退出都不再被拦。
    // 抓住的错误实现：唯一出口是「另存为新备忘」，或者放弃时把修改偷偷写回数据库。
    function test_discardChangesOfRemotelyDeletedMemo() {
        typeBody("不想要了的修改");
        service.records = fixture().filter(function (r) {
            return r.id !== 11;
        });
        service.memosChanged();
        verify(view.remoteDeleted, "前置：进入了「另一台已删、本机有修改」的状态");
        compare(view.saveNow(), false, "前置：这个状态下保存会被拦住");
        // 记录已经不在了，「删除」只会报错，这个状态下不给。
        compare(child("memoDeleteButton").visible, false);
        var discard = child("memoDiscardDeleted");
        tryVerify(function () {
            return discard.width > 0;
        }, 3000);
        waitForRendering(view, 3000);
        mouseClick(discard);
        compare(view.remoteDeleted, false);
        compare(view.selectedId, 12);
        compare(view.editorBody, "积分练习");
        compare(service.creates.length, 0);
        compare(service.updates.length, 0);
        compare(view.saveNow(), true);
    }
    // 产品保证：只是打开查看一条备忘、甚至开始打拼音还没选字，都不会改动它。编辑框会把不间断空格显示成普通空格，
    // 这种显示上的差别不能被当成修改写回数据库（否则看一眼就变成「刚刚更新」，还会多出一次同步）。
    // 抓住的错误实现：模型留着数据库原文、编辑框里是规范后的文字，两边对不上；
    // 之后编辑框随便发一次文字变化（例如拼音组合），就被当成修改写回。
    function test_viewingMemoDoesNotRewriteIt() {
        service.records = fixture().concat([service.makeRecord(41, "带空格", "甲 乙", 2)]);
        service.memosChanged();
        view.selectMemo(41);
        var body = child("memoBodyInput");
        compare(body.text, "甲 乙", "前置：编辑框把不间断空格规范成了普通空格");
        compare(view.dirty, false);
        body.forceActiveFocus(Qt.MouseFocusReason);
        // qmllint disable unqualified
        verify(inputMethodProbe.compose(body, "jin"));
        // qmllint enable unqualified
        compare(body.preeditText, "jin", "前置：拼音正在组合，文字本身没变");
        compare(view.dirty, false);
        // 要证明的是「一秒自动保存的窗口里什么都没发生」，只能等过这个窗口。
        wait(1300);
        compare(service.updates.length, 0);
    }
    // 产品保证：拼音还在组合时切到另一条备忘，编辑框直接换成新备忘的内容，旧备忘的文字不会在装载途中写进模型。
    // 抓住的错误实现：装载时不屏蔽编辑框的文字变化——TextEdit 取消组合时先按旧文字发一次 textChanged，
    // 处理函数把旧文字写回 editorBody（绑定循环，模型短暂变回上一条的正文）。
    function test_switchWhileComposingLoadsCleanly() {
        // 离屏平台的真输入法不会提交组合；换成替身，让组合在切换时还开着，复现「取消组合」那一步。
        view.inputMethodRef = keyboardMock;
        var body = child("memoBodyInput");
        body.forceActiveFocus(Qt.MouseFocusReason);
        // qmllint disable unqualified
        verify(inputMethodProbe.compose(body, "jin du"));
        // qmllint enable unqualified
        compare(body.preeditText, "jin du", "前置：切换时组合还开着");
        verify(!view.dirty, "前置：只在组合，没有上屏任何字");
        bodyChanges.target = view;
        bodyChanges.clear();
        view.selectMemo(12);
        compare(view.editorBody, "积分练习");
        compare(body.text, "积分练习");
        compare(bodyChanges.count, 1, "模型只变一次：直接从上一条换成这一条");
        compare(view.dirty, false);
    }
}
