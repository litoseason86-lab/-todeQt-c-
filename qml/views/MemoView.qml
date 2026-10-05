pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../components"
import ".."
import "MemoFormat.js" as MemoFormat

// 草稿与最后一次读取的数据库版本分开：同步刷新不得盖掉尚未保存的输入。
FocusScope {
    id: root
    property var memoServiceRef: null
    property var categoryManagerRef: null
    property var textLayoutRef: null
    property bool pageActive: true
    property int filterCategoryId: -1
    property int selectedId: -1
    property bool drafting: false
    // 新建前选中的那条：什么都没写的草稿被丢弃时回到这里。
    property int draftReturnId: -1
    property bool remoteDeleted: false
    // 被另一台删掉的那条原来在列表里的位置；用户放弃本机修改后选这个位置上的相邻一条。
    property int deletedNeighborIndex: 0
    // 正在把一条备忘装进编辑框。装载期间编辑框发出的文字变化都不是用户编辑，见正文的 onTextChanged。
    property bool loadingEditor: false
    property string editorTitle: ""
    property string editorBody: ""
    property int editorCategoryId: 0
    property string baselineTitle: ""
    property string baselineBody: ""
    property int baselineCategoryId: 0
    property string updatedAt: ""
    property string errorMessage: ""
    property var allMemos: []
    property var categories: []
    property var capsules: []
    // 已有的分类：写过备忘的科目，按科目管理里的顺序。正在编辑的这条所在的科目也算——
    // 用「新建分类」开的第一条还没保存时，那一科还没有备忘。右键改分类只在这些里面选。
    readonly property var memoCategoryOptions: root.categoryOptions(true)
    // 还没写过备忘的科目：「新建分类」从这里挑。
    readonly property var unusedCategoryOptions: root.categoryOptions(false)
    property bool saving: false
    property bool reading: false
    property string readFailure: ""
    property bool touchUi: Qt.platform.os === "ios"
    property var inputMethodRef: Qt.inputMethod
    readonly property real floatingKeyboardInset: {
        if (!root.touchUi || !root.inputMethodRef || !root.inputMethodRef.visible || !bodyInput.activeFocus)
            return 0;
        var keyboard = root.inputMethodRef.keyboardRectangle;
        var window = root.Window.window;
        if (!window || keyboard.width <= 0 || keyboard.height <= 0)
            return 0;
        // Qt for iOS 已为停靠键盘挪动根视图，不能再重复缩短。浮动键盘不走那条原生路径。
        if (keyboard.y + keyboard.height >= window.height - 1)
            return 0;
        var start = bodyScroll.mapToItem(null, 0, 0);
        if (keyboard.x + keyboard.width <= start.x || keyboard.x >= start.x + bodyScroll.width)
            return 0;
        var top = titleInput.mapToItem(null, 0, titleInput.height).y + Theme.space12;
        var bottom = paper.mapToItem(null, 0, paper.height - Theme.space16).y;
        return Math.min(Math.max(0, bottom - keyboard.y + Theme.space16), Math.max(0, bottom - top - 80));
    }
    readonly property bool dirty: editorTitle !== baselineTitle || editorBody !== baselineBody || editorCategoryId !== baselineCategoryId
    readonly property bool hasEditor: drafting || selectedId > 0
    // 一条备忘都没有、也没在新建：框里什么都不摆，不留一个孤零零的「全部」和分隔线，也不放提示文字（用户要求页面不放说明性文字）。
    readonly property bool libraryEmpty: allMemos.length === 0 && !drafting
    // 列表里第一个分组的科目。组头上方的 16 间距只放在组与组之间，第一个组头贴着列表顶。
    property string firstGroupKey: ""
    // 列表焦点是鼠标或触屏点出来的。键盘（Tab 进来、方向键移动）选择时才给选中行画焦点环，
    // Qt 6.10 的 Item 没有 focusReason，只能自己记。焦点离开列表就清掉。
    property bool listFocusFromPointer: false
    readonly property bool listVisualFocus: memoList.activeFocus && !listFocusFromPointer
    // 编辑卡内边距：定稿是 24；iPad 竖屏且侧栏展开时卡片很窄，退到 16 给正文留宽度。
    readonly property int paperPadding: paper.width >= 380 ? Theme.space24 : Theme.space16
    // 标题、正文输入框的内边距。焦点环画在框边上，离文字留 4；框再用同样大小的负边距伸出去，
    // 文字仍和科目按钮左对齐。改这个数要连同负边距一起看。
    readonly property int inputInset: 6
    readonly property int capsuleMaxWidth: Theme.fontSm * 7 + Theme.space16
    readonly property int titleLimit: memoServiceRef ? memoServiceRef.maxTitleLength : 60
    readonly property int bodyLimit: memoServiceRef ? memoServiceRef.maxBodyLength : 10000
    property date displayNow: new Date()
    property int draggingId: -1
    property int dragCategoryId: 0
    property int dropTargetId: -1
    property int touchArmedId: -1
    // 长按之后手指有没有拖动过：拖过是排序，没拖就松手是改分类（和 Mac 右键一样）。
    property bool touchDragMoved: false
    // 长按的位置（窗口坐标）：没拖就松手时，改分类的弹层在这里弹出。
    property point touchArmedPoint: Qt.point(0, 0)
    property real dragSceneX: 0
    property real dragSceneY: 0
    readonly property int pendingDeleteId: deleteConfirm.pendingId

    function ensureBodyCursorVisible() {
        if (!bodyInput || !bodyInput.activeFocus || bodyScroll.height <= 0)
            return;
        var cursor = bodyInput.cursorRectangle;
        if (cursor.y < bodyScroll.contentY)
            bodyScroll.contentY = cursor.y;
        else if (cursor.y + cursor.height > bodyScroll.contentY + bodyScroll.height)
            bodyScroll.contentY = Math.max(0, cursor.y + cursor.height - bodyScroll.height);
    }
    function category(id) {
        for (var entry of root.categories)
            if (Number(entry.id) === id)
                return entry;
        return {
            id: 0,
            name: qsTr("未分类"),
            color: ""
        };
    }
    function memo(id) {
        for (var entry of root.allMemos)
            if (Number(entry.id) === id)
                return entry;
        return null;
    }
    function idsForCategory(id) {
        return root.allMemos.filter(function (entry) {
            return Number(entry.categoryId) === id;
        }).map(function (entry) {
            return Number(entry.id);
        });
    }
    function groupCount(id) {
        return root.idsForCategory(Number(id)).length;
    }
    // inUse 为真：写过备忘的科目，加上正在编辑的这条所在的科目；为假：其余的科目。
    function categoryOptions(inUse) {
        return root.categories.filter(function (entry) {
            var id = Number(entry.id);
            return (id === root.editorCategoryId || root.idsForCategory(id).length > 0) === inUse;
        }).map(function (entry) {
            return {
                id: Number(entry.id),
                name: String(entry.name),
                color: String(entry.color || "")
            };
        });
    }
    function readEditor(entry) {
        root.loadingEditor = true;
        root.editorTitle = String(entry.title);
        root.editorBody = String(entry.body);
        // 编辑框会把不间断空格等字符规范成普通字符。模型跟编辑框里实际的文字对齐，基准值也取这份：
        // 否则两边一直对不上，之后一开始打拼音（文字没变也会发 textChanged）就被当成修改写回数据库。
        root.editorBody = bodyInput.text;
        root.loadingEditor = false;
        root.editorCategoryId = Number(entry.categoryId);
        root.baselineTitle = root.editorTitle;
        root.baselineBody = root.editorBody;
        root.baselineCategoryId = root.editorCategoryId;
        root.updatedAt = entry.updatedAt;
        root.remoteDeleted = false;
        root.errorMessage = "";
    }
    function clearEditor() {
        root.selectedId = -1;
        root.drafting = false;
        root.draftReturnId = -1;
        root.readEditor({
            title: "",
            body: "",
            categoryId: 0,
            updatedAt: ""
        });
    }
    function rebuildRows() {
        rows.clear();
        for (var entry of root.allMemos) {
            if (root.filterCategoryId >= 0 && Number(entry.categoryId) !== root.filterCategoryId)
                continue;
            rows.append({
                memoId: Number(entry.id),
                memoTitle: String(entry.displayTitle),
                memoPreview: String(entry.preview),
                categoryId: Number(entry.categoryId),
                categoryColor: String(entry.categoryColor || ""),
                groupKey: String(entry.categoryId),
                updatedAt: String(entry.updatedAt)
            });
        }
        root.firstGroupKey = rows.count > 0 ? rows.get(0).groupKey : "";
    }
    function reload() {
        if (root.saving || !root.memoServiceRef)
            return;
        // 远端刷新会销毁列表委托。先取消拖动，不能拿过期的完整列表覆盖新顺序。
        if (root.draggingId >= 0)
            root.finishDrag(true);
        var oldIndex = 0;
        var oldGlobalIndex = root.allMemos.findIndex(function (entry) {
            return Number(entry.id) === root.selectedId;
        });
        for (var i = 0; i < rows.count; ++i)
            if (rows.get(i).memoId === root.selectedId)
                oldIndex = i;
        // 每分钟一次的定时器在页面不可见时停着；回到页面或保存后重读时先对一次表，
        // 「今天」「昨天」按现在算，不沿用离开那会儿的时间。
        root.displayNow = new Date();
        var previousFailure = root.readFailure;
        root.readFailure = "";
        root.reading = true;
        var values = root.memoServiceRef.listMemos(-1);
        // 科目和备忘录算同一次读取，任何一个失败都保留上一次读到的内容。科目读失败时服务返回空列表，
        // 不能拿它当「科目都被删了」：备忘会全按未分类分组，草稿也会被改成未分类（见下面对草稿的处理）。
        var categoryValues = [];
        if (root.readFailure.length === 0 && root.categoryManagerRef && typeof root.categoryManagerRef.getAllCategories === "function")
            categoryValues = root.categoryManagerRef.getAllCategories();
        root.reading = false;
        if (root.readFailure.length > 0)
            return;
        // 上一次读取失败的提示，这次读到了就收起。草稿和改了还没存的备忘不会重新装进编辑框（装载时才清提示），
        // 不在这里清，提示会一直留到下一次保存。
        if (previousFailure.length > 0 && root.errorMessage === previousFailure)
            root.errorMessage = "";
        root.allMemos = values;
        root.categories = categoryValues;
        // 删除确认框、改分类弹层针对的那条已经不在了（另一台删掉了它）：没有东西可删、可改，收起。
        if (deleteConfirm.pendingId > 0 && !root.memo(deleteConfirm.pendingId))
            root.cancelDelete();
        if (moveCategoryPopup.visible && !root.memo(moveCategoryPopup.targetId))
            moveCategoryPopup.close();
        var choices = [
            {
                id: -1,
                name: qsTr("全部")
            }
        ];
        for (var cat of root.categories) {
            if (root.idsForCategory(Number(cat.id)).length > 0)
                choices.push({
                    id: Number(cat.id),
                    name: cat.name
                });
        }
        if (root.idsForCategory(0).length > 0)
            choices.push({
                id: 0,
                name: qsTr("未分类")
            });
        root.capsules = choices;
        // 最后一条被删除或移走后，该科目的胶囊消失；不能留一个再也点不到的筛选状态。
        if (!choices.some(function (choice) {
            return choice.id === root.filterCategoryId;
        })) {
            root.filterCategoryId = -1;
            oldIndex = Math.max(0, oldGlobalIndex);
        }
        root.rebuildRows();
        if (root.drafting) {
            // 改成未分类后重新排一次自动保存：上一次可能正是因为科目不存在没存成。
            if (root.dropMissingEditorCategory())
                root.edited();
            return;
        }
        var current = root.memo(root.selectedId);
        if (current) {
            if (!root.dirty)
                root.readEditor(current);
        } else if (root.dirty) {
            root.remoteDeleted = true;
            root.deletedNeighborIndex = oldIndex;
            root.errorMessage = qsTr("这条备忘录已在另一台设备删除。编辑中的内容还在这里，可以另存为新备忘，或放弃修改。");
            // 另一台可能连它的科目一起删了；「另存为新备忘」要存得下。
            root.dropMissingEditorCategory();
        } else if (rows.count > 0) {
            root.selectedId = rows.get(Math.min(oldIndex, rows.count - 1)).memoId;
            root.readEditor(root.memo(root.selectedId));
        } else {
            root.clearEditor();
        }
    }
    // 编辑区里还没进数据库的内容（草稿，或另一台已经删掉的那条）所在的科目被另一台删掉了：改成未分类，文字原样保留。
    // 已存的备忘不用管，数据库删科目时会把它们的科目置空，重读时跟着变成未分类；这里照同样的结果处理。
    // 不改的话，保存一直带着不存在的科目编号被服务拒绝；换备忘、新建都要先保存，用户就被卡住，
    // 而这些内容不在列表里（右键改不了分类）、编辑区的分类又是只读的。改了返回 true。
    function dropMissingEditorCategory() {
        if (root.editorCategoryId === 0 || root.categories.some(function (entry) {
            return Number(entry.id) === root.editorCategoryId;
        }))
            return false;
        root.editorCategoryId = 0;
        root.baselineCategoryId = 0;
        return true;
    }
    // 切换备忘、切页、进后台、退出时调用：这些操作会打断输入，先把输入法正在组合的文字提交进编辑框，
    // 免得还没选字的候选内容丢掉，再保存。
    function saveNow() {
        if (root.inputMethodRef)
            root.inputMethodRef.commit();
        return root.writeEdits();
    }
    // 停止输入一秒后的自动保存只存已经上屏的文字，不提交输入法的组合：
    // 在 Mac 和 iPad 上 commit() 会把还没选字的拼音原样写进框里，候选窗也随之关掉。
    function writeEdits() {
        saveTimer.stop();
        if (!root.hasEditor || !root.dirty)
            return true;
        if (root.drafting && root.editorTitle.trim().length === 0 && root.editorBody.trim().length === 0)
            return true;
        var excess = MemoFormat.characterCount(root.editorBody) - root.bodyLimit;
        if (excess > 0) {
            root.errorMessage = qsTr("正文超出 %1 字，没有保存。").arg(excess);
            return false;
        }
        if (root.remoteDeleted || !root.memoServiceRef)
            return false;
        var changes = {};
        if (root.editorTitle !== root.baselineTitle)
            changes.title = root.editorTitle;
        if (root.editorBody !== root.baselineBody)
            changes.body = root.editorBody;
        if (root.editorCategoryId !== root.baselineCategoryId)
            changes.categoryId = root.editorCategoryId;
        root.errorMessage = "";
        // 新建的和换了科目的都排到那一科最后，保存后要把它滚进列表可视区。
        var moved = root.drafting || changes.categoryId !== undefined;
        root.saving = true;
        var ok;
        if (root.drafting) {
            var id = root.memoServiceRef.createMemo(root.editorTitle, root.editorBody, root.editorCategoryId);
            ok = id > 0;
            if (ok) {
                root.selectedId = id;
                root.drafting = false;
                // 删除确认框开着的时候草稿被存下了（停止输入一秒的自动保存、切到后台都会存）：
                // 确认框改记它存下的这一条。编号 0 只表示「还没进数据库的草稿」，存下以后就不是了。
                if (deleteConfirm.pendingId === 0)
                    deleteConfirm.pendingId = id;
            }
        } else {
            ok = root.memoServiceRef.updateMemo(root.selectedId, changes);
        }
        root.saving = false;
        if (!ok) {
            if (root.errorMessage.length === 0)
                root.errorMessage = qsTr("保存失败，编辑内容仍保留在这里。");
            return false;
        }
        root.baselineTitle = root.editorTitle;
        root.baselineBody = root.editorBody;
        root.baselineCategoryId = root.editorCategoryId;
        root.reload();
        if (moved)
            root.revealSelected();
        return true;
    }
    function revealSelected() {
        for (var i = 0; i < rows.count; ++i) {
            if (rows.get(i).memoId === root.selectedId) {
                // 列表刚整体重建过，先让它把增删排完，否则按旧布局算位置。
                memoList.forceLayout();
                memoList.positionViewAtIndex(i, ListView.Contain);
                // 第一次定位时，这一行所在科目的组头可能还没建出来；组头建出来后行会被推下去一截，
                // 底边落到可视区外。再定位一次，这时组头已经算在内。
                memoList.positionViewAtIndex(i, ListView.Contain);
                return;
            }
        }
    }
    function saveDeletedAsNew() {
        if (!root.remoteDeleted)
            return;
        root.drafting = true;
        root.selectedId = -1;
        root.remoteDeleted = false;
        root.baselineTitle = "";
        root.baselineBody = "";
        root.baselineCategoryId = root.editorCategoryId;
        root.saveNow();
    }
    // 用户明确放弃被另一台删掉的那条的本机修改：不写库，选原来位置上的相邻一条；列表空了就回到空状态。
    function discardDeleted() {
        if (!root.remoteDeleted)
            return;
        saveTimer.stop();
        var index = root.deletedNeighborIndex;
        root.clearEditor();
        if (rows.count > 0) {
            root.selectedId = rows.get(Math.min(index, rows.count - 1)).memoId;
            root.readEditor(root.memo(root.selectedId));
        }
    }
    // 开一条新草稿。categoryId 给了（「新建分类」挑好的科目）就放在那一科，没给就跟着当前筛选。
    function startDraft(categoryId) {
        if (!root.saveNow())
            return;
        // 连续点「新建」时，空草稿不会被保存，回去的目标仍是最初选中的那条。
        var back = root.drafting ? root.draftReturnId : root.selectedId;
        var target = categoryId === undefined ? Math.max(0, root.filterCategoryId) : Number(categoryId);
        // 正筛着别的科目时回到「全部」：新分类的第一条存下来以后，列表里要看得到它。
        if (root.filterCategoryId >= 0 && root.filterCategoryId !== target) {
            root.filterCategoryId = -1;
            root.rebuildRows();
        }
        root.clearEditor();
        root.drafting = true;
        root.draftReturnId = back;
        root.editorCategoryId = target;
        root.baselineCategoryId = target;
        // 点「新建」后直接能打标题；焦点环只给键盘 Tab 用，这里只要闪烁的光标。
        titleInput.forceActiveFocus(Qt.OtherFocusReason);
    }
    // 「新建 → 新建分类」：从还没写过备忘的科目里挑一个，一个都不剩就直接新建科目；挑好或建好后在那一科开一条草稿。
    function addCategory() {
        if (root.unusedCategoryOptions.length === 0)
            categoryPrompt.openPrompt();
        else
            subjectPicker.open();
    }
    // 改一条备忘的分类（列表里右键、iPad 长按后松手、键盘 Shift+F10）：先选中它（切走前照常保存当前这条），
    // 再在指针处弹出已有的分类。只能在已有的分类之间换，新分类从右上角「新建」建。
    // byKeyboard：键盘打开时弹层先不让悬停改高亮，见 ChoicePopup.openedByKeyboard。
    function requestMoveCategory(id, sceneX, sceneY, byKeyboard) {
        root.selectMemo(id);
        if (root.selectedId !== id || root.drafting)
            return;
        var p = root.mapFromItem(null, sceneX, sceneY);
        moveCategoryPopup.x = p.x;
        moveCategoryPopup.y = p.y;
        moveCategoryPopup.targetId = id;
        moveCategoryPopup.openedByKeyboard = byKeyboard === true;
        moveCategoryPopup.open();
    }
    // 键盘入口：在选中行的左下方弹出。
    function moveSelectedFromKeyboard() {
        for (var i = 0; i < rows.count; ++i) {
            if (rows.get(i).memoId !== root.selectedId)
                continue;
            var item = memoList.itemAtIndex(i);
            if (!item)
                return;
            var p = item.mapToItem(null, Theme.space16, item.height);
            root.requestMoveCategory(root.selectedId, p.x, p.y, true);
            return;
        }
    }
    // 标题里按回车：到正文开头接着写，标题不变。在按键这一步接住、不交给标题框：
    // 单行输入框收到回车会收起 iPad 软键盘，跳到正文又得再弹起来。
    // 输入法还在组合拼音时回车归输入法（Mac 拼音按回车是把字母原样上屏），不跳。
    function continueInBody(event) {
        if (titleInput.inputMethodComposing) {
            event.accepted = false;
            return;
        }
        event.accepted = true;
        bodyInput.cursorPosition = 0;
        bodyInput.forceActiveFocus(Qt.OtherFocusReason);
        root.ensureBodyCursorVisible();
    }
    function selectMemo(id) {
        if (id === root.selectedId && !root.drafting)
            return;
        if (!root.saveNow())
            return;
        var entry = root.memo(id);
        if (!entry)
            return;
        root.drafting = false;
        root.selectedId = id;
        root.readEditor(entry);
    }
    function selectFilter(id) {
        if (!root.saveNow())
            return;
        root.filterCategoryId = id;
        root.clearEditor();
        root.reload();
    }
    function stepSelection(delta) {
        var index = -1;
        for (var i = 0; i < rows.count; ++i)
            if (rows.get(i).memoId === root.selectedId)
                index = i;
        var next = Math.max(0, Math.min(rows.count - 1, index + delta));
        if (next >= 0 && rows.count > 0) {
            root.selectMemo(rows.get(next).memoId);
            memoList.positionViewAtIndex(next, ListView.Contain);
        }
    }
    function edited() {
        if (root.pageActive)
            saveTimer.restart();
    }
    function chooseCategory(id) {
        root.editorCategoryId = id;
        root.edited();
    }
    // 丢掉还没进数据库的草稿：只清界面，回到新建前选中的那条；那条已经不在了就按列表重新选。
    function discardDraft() {
        saveTimer.stop();
        var back = root.memo(root.draftReturnId);
        root.clearEditor();
        if (back) {
            root.selectedId = Number(back.id);
            root.readEditor(back);
        } else {
            root.reload();
        }
    }
    // 点「删除」一律先确认，新建了还没写字的草稿也一样（确认后只丢草稿，回到新建前那条）。
    function requestDelete() {
        // 草稿还没进数据库，编号先记 0；确认框开着时它被自动保存的话，writeEdits 会换成存下的编号。
        deleteConfirm.pendingId = root.drafting ? 0 : root.selectedId;
        // 确认框里写出要删的是哪一条：标题，没有标题就用正文第一行，和列表里显示的一致。
        var title = root.editorTitle.trim();
        deleteConfirm.pendingTitle = title.length > 0 ? title : root.editorBody.split("\n")[0].trim();
        deleteConfirm.open();
    }
    function cancelDelete() {
        deleteConfirm.pendingId = -1;
        deleteConfirm.close();
    }
    function confirmDelete() {
        var id = deleteConfirm.pendingId;
        root.cancelDelete();
        if (id === 0 && root.drafting) {
            root.discardDraft();
            return;
        }
        // 只删确认框记下的那一条，不拿当前选中的补：确认框开着的时候，同步可能已经删掉了要删的那条、
        // 改选了相邻的另一条，这时删选中的就删错了。
        if (id <= 0)
            return;
        // 用户明确确认删除时才舍弃当前草稿；失败仍保留输入。
        root.saving = true;
        var ok = root.memoServiceRef && root.memoServiceRef.deleteMemo(id);
        root.saving = false;
        if (ok) {
            root.clearEditor();
            root.reload();
        }
    }
    function beginDrag(id) {
        if (!root.saveNow())
            return false;
        var entry = root.memo(id);
        if (!entry)
            return false;
        root.draggingId = id;
        root.dragCategoryId = Number(entry.categoryId);
        root.dropTargetId = id;
        return true;
    }
    function setDropTarget(id) {
        var entry = root.memo(id);
        // “全部”中邻组也是可见行，但不是合法落点；越界时取消当前落点。
        root.dropTargetId = entry && Number(entry.categoryId) === root.dragCategoryId ? id : -1;
    }
    function updateDrag(sceneX, sceneY) {
        root.dragSceneX = sceneX;
        root.dragSceneY = sceneY;
        var local = memoList.mapFromItem(null, sceneX, sceneY);
        var index = memoList.indexAt(1, memoList.contentY + local.y);
        root.setDropTarget(index >= 0 ? rows.get(index).memoId : -1);
    }
    function finishDrag(cancelled) {
        var id = root.draggingId;
        var targetId = root.dropTargetId;
        var ids = root.idsForCategory(root.dragCategoryId);
        root.draggingId = -1;
        root.dropTargetId = -1;
        root.touchArmedId = -1;
        if (cancelled || id < 0 || targetId < 0 || targetId === id)
            return;
        var from = ids.indexOf(id);
        var to = ids.indexOf(targetId);
        if (from < 0 || to < 0)
            return;
        ids.splice(from, 1);
        ids.splice(to, 0, id);
        root.memoServiceRef.reorderMemos(root.dragCategoryId, ids);
    }

    onPageActiveChanged: {
        if (root.pageActive)
            root.reload();
        else {
            root.finishDrag(true);
            root.saveNow();
        }
    }
    Component.onCompleted: {
        if (root.pageActive)
            root.reload();
    }
    Timer {
        interval: 40
        repeat: true
        running: root.draggingId >= 0
        onTriggered: {
            var point = memoList.mapFromItem(null, root.dragSceneX, root.dragSceneY);
            var step = point.y < 40 ? -10 : point.y > memoList.height - 40 ? 10 : 0;
            if (step === 0)
                return;
            memoList.contentY = Math.max(0, Math.min(Math.max(0, memoList.contentHeight - memoList.height), memoList.contentY + step));
            root.updateDrag(root.dragSceneX, root.dragSceneY);
        }
    }
    Timer {
        id: saveTimer
        interval: 1000
        onTriggered: root.writeEdits()
    }
    Timer {
        interval: 60000
        running: root.pageActive
        repeat: true
        onTriggered: root.displayNow = new Date()
    }
    Connections {
        target: root.memoServiceRef
        function onMemosChanged() {
            if (root.pageActive)
                root.reload();
        }
        function onOperationFailed(message) {
            if (root.reading)
                root.readFailure = message;
            if (root.pageActive || root.saving)
                root.errorMessage = message;
        }
    }
    Connections {
        target: root.categoryManagerRef
        ignoreUnknownSignals: true
        function onCategoriesChanged() {
            if (root.pageActive)
                root.reload();
        }
        // 只认 reload() 读科目时的失败。科目管理等别处的科目操作失败也走这个信号，和这一页无关。
        function onOperationFailed(message) {
            if (!root.reading)
                return;
            root.readFailure = message;
            if (root.pageActive)
                root.errorMessage = message;
        }
    }
    Connections {
        target: Application
        function onStateChanged() {
            if (Application.state !== Qt.ApplicationActive)
                root.saveNow();
        }
    }
    ListModel {
        id: rows
    }

    RowLayout {
        id: header
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
            margins: Theme.space24
        }
        Text {
            text: qsTr("备忘录")
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontXxl
            font.bold: true
            color: Theme.ink
        }
        Item {
            Layout.fillWidth: true
        }
        PageActionButton {
            id: newButton
            implicitHeight: root.touchUi ? 44 : Theme.controlHeightMd
            objectName: "memoNewButton"
            text: qsTr("新建")
            glyph: "plus"
            primary: true
            // 点开是一个小菜单：新建备忘录，或新建分类。菜单（或从它打开的挑科目）开着时再点就收起。
            onClicked: {
                if (newMenu.visible || subjectPicker.visible) {
                    newMenu.close();
                    subjectPicker.close();
                } else {
                    newMenu.open();
                }
            }
        }
    }
    GlassPanel {
        id: panel
        anchors {
            top: header.bottom
            topMargin: Theme.space16
            left: parent.left
            right: parent.right
            bottom: parent.bottom
            leftMargin: Theme.space24
            rightMargin: Theme.space24
            bottomMargin: Theme.space24
        }
    }
    // 内容是玻璃效果的兄弟，避免把文字一起采样，也让离屏关闭 layer 后仍能截正式页面。
    Item {
        id: content
        anchors.fill: panel
        anchors.margins: Theme.space16
        Item {
            id: leftPane
            visible: !root.libraryEmpty
            width: 256
            anchors {
                left: parent.left
                top: parent.top
                bottom: parent.bottom
            }
            Flow {
                id: filters
                objectName: "memoFilters"
                width: parent.width
                spacing: Theme.space8
                Repeater {
                    model: root.capsules
                    delegate: Button {
                        id: capsule
                        required property var modelData
                        objectName: "memoFilter" + modelData.id
                        readonly property bool selected: root.filterCategoryId === Number(modelData.id)
                        width: Math.min(root.capsuleMaxWidth, label.implicitWidth)
                        height: root.touchUi ? 44 : 26
                        padding: 0
                        leftPadding: 0
                        rightPadding: 0
                        focusPolicy: Qt.StrongFocus
                        // 触屏没有悬停；Mac 上显式打开，不跟随样式提示（离屏测试里样式提示是关的）。
                        hoverEnabled: !root.touchUi
                        Accessible.name: modelData.name
                        // 与仪表盘筛选胶囊同一套：选中实心淡焦糖、不描边、字重加一级；没选中的只留描边，悬停时一层淡高光。
                        background: Rectangle {
                            objectName: "memoFilterBackground"
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width
                            height: 26
                            radius: 13
                            color: capsule.selected ? Theme.accentFill : (capsule.hovered ? Theme.glassHover : Theme.glassHoverIdle)
                            border.width: capsule.visualFocus ? 2 : (capsule.selected ? 0 : 1)
                            border.color: capsule.visualFocus ? Theme.focusRing : Theme.borderSubtle
                            Behavior on color {
                                ColorAnimation {
                                    duration: Theme.reduceMotion ? 0 : 120
                                    easing.type: Easing.OutQuad
                                }
                            }
                        }
                        contentItem: Text {
                            id: label
                            objectName: "memoFilterLabel"
                            text: capsule.modelData.name
                            textFormat: Text.PlainText
                            font.pixelSize: Theme.fontSm
                            font.weight: capsule.selected ? Font.Medium : Font.Normal
                            color: capsule.selected ? Theme.accentFillInk : Theme.inkSoft
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                            leftPadding: Theme.space8
                            rightPadding: Theme.space8
                        }
                        onClicked: root.selectFilter(Number(modelData.id))
                        HoverHandler {
                            cursorShape: Qt.PointingHandCursor
                        }
                        // 名字被省略时才提示完整科目名；「全部」「数学」这种完整显示的再弹一遍是多余的。
                        ThemedToolTip {
                            objectName: "memoFilterToolTip"
                            visible: label.truncated && (capsule.hovered || capsule.visualFocus)
                            text: capsule.modelData.name
                        }
                    }
                }
            }
            ListView {
                id: memoList
                objectName: "memoList"
                Accessible.role: Accessible.List
                Accessible.name: qsTr("备忘录列表")
                anchors {
                    top: filters.bottom
                    topMargin: Theme.space16
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                }
                clip: true
                model: rows
                boundsBehavior: Flickable.StopAtBounds
                interactive: root.draggingId < 0
                spacing: Theme.space4
                // 分组字段保持稳定，单科时卸载组头。避免切回“全部”时一边改变分组字段、一边重建列表。
                // 最后一条科目备忘被远端删除的回归用例已验证这条切换路径。
                section.property: "groupKey"
                section.criteria: ViewSection.FullString
                section.delegate: Loader {
                    id: groupLoader
                    required property string section
                    // 第一个组头贴着列表顶；后面的组头上方留 12，加上列表的行距 4，组与组之间正好空 16（定稿）。
                    readonly property bool leading: groupLoader.section === root.firstGroupKey
                    width: memoList.width
                    // Loader 的隐式高度跟随装进来的组头；卸载（选了单科）时为 0。
                    height: active ? implicitHeight : 0
                    active: root.filterCategoryId < 0
                    sourceComponent: Item {
                        implicitHeight: (groupLoader.leading ? 0 : Theme.space12) + groupRow.implicitHeight + Theme.space8
                        // 组头写成「科目 · 条数」：名字按自身宽度排、条数紧跟其后，多出来的宽度留在行尾。
                        // 名字太长放不下时只压缩名字（省略号），条数始终完整。文字比列表行往里缩 8，与定稿一致。
                        RowLayout {
                            id: groupRow
                            objectName: "memoGroup" + groupLoader.section
                            x: Theme.space8
                            y: groupLoader.leading ? 0 : Theme.space12
                            width: parent.width - Theme.space8 * 2
                            spacing: 0
                            Text {
                                id: groupName
                                objectName: "memoGroupName"
                                Layout.fillWidth: true
                                // 上限向上取整：布局分给它的是整数宽度，字宽带小数时（系统界面字体常见）
                                // 正好等于自然宽度也会被省略，「数学」就成了「数…」。
                                Layout.maximumWidth: Math.ceil(groupName.implicitWidth)
                                text: root.category(Number(groupLoader.section)).name
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontSm
                                font.bold: true
                                color: Theme.inkSoft
                                elide: Text.ElideRight
                            }
                            Text {
                                objectName: "memoGroupCount"
                                text: " · " + root.groupCount(groupLoader.section)
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontSm
                                font.bold: true
                                color: Theme.inkSoft
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                        }
                    }
                }
                // 键盘可以 Tab 进列表、用上下键换备忘；这时选中行画焦点环（见 listVisualFocus）。
                activeFocusOnTab: true
                onActiveFocusChanged: {
                    if (!activeFocus)
                        root.listFocusFromPointer = false;
                }
                Keys.onUpPressed: {
                    root.listFocusFromPointer = false;
                    root.stepSelection(-1);
                }
                Keys.onDownPressed: {
                    root.listFocusFromPointer = false;
                    root.stepSelection(1);
                }
                // 键盘改分类：Shift+F10 或菜单键，在选中行下方弹出（和右键同一个弹层）。
                Keys.onPressed: function (event) {
                    if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
                        event.accepted = true;
                        root.listFocusFromPointer = false;
                        root.moveSelectedFromKeyboard();
                    }
                }
                ScrollBar.vertical: PageScrollBar {
                    parent: leftPane
                    x: leftPane.width + 4
                    y: memoList.y
                    height: memoList.height
                    scrollAreaVisible: root.pageActive
                }
                delegate: Control {
                    id: row
                    required property int memoId
                    required property string memoTitle
                    required property string memoPreview
                    required property int categoryId
                    required property string categoryColor
                    required property string updatedAt
                    required property int index
                    objectName: "memoRow" + memoId
                    Accessible.role: Accessible.ListItem
                    Accessible.name: memoTitle
                    readonly property bool selected: root.selectedId === memoId && !root.drafting
                    width: memoList.width
                    // 行高随内容：上下各留 12，标题行与摘要之间 4，两行在行内上下居中（定稿）。
                    // 写死行高会让多出来的高度被布局摊进两行之间，标题和摘要被拉开。
                    height: implicitHeight
                    padding: Theme.space12
                    hoverEnabled: !root.touchUi
                    // 拖动中的这一行变淡，看得出「正在挪的是哪一条」。
                    opacity: root.draggingId === row.memoId ? 0.55 : 1
                    // 选中、悬停、键盘焦点与设置页左侧导航同一套：淡焦糖底 + 深字，悬停一层淡高光，键盘选中时加焦点环。
                    background: Rectangle {
                        objectName: "memoRowBackground"
                        radius: Theme.radiusMd
                        color: row.selected ? Theme.accentFill : (row.hovered ? Theme.glassHover : Theme.glassHoverIdle)
                        border.width: row.selected && root.listVisualFocus ? 2 : 0
                        border.color: Theme.focusRing
                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.reduceMotion ? 0 : 120
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                    contentItem: ColumnLayout {
                        spacing: Theme.space4
                        RowLayout {
                            objectName: "memoRowHeading"
                            Layout.fillWidth: true
                            spacing: Theme.space8
                            Rectangle {
                                objectName: "memoRowDot"
                                implicitWidth: 8
                                implicitHeight: 8
                                radius: 4
                                color: row.categoryColor.length > 0 ? row.categoryColor : Qt.rgba(1, 1, 1, 0)
                            }
                            Text {
                                objectName: "memoRowTitle"
                                Layout.fillWidth: true
                                text: row.memoTitle
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontMd
                                font.weight: row.selected ? Font.Medium : Font.Normal
                                color: row.selected ? Theme.accentFillInk : Theme.ink
                                elide: Text.ElideRight
                            }
                            Text {
                                objectName: "memoRowTime"
                                text: MemoFormat.formatUpdatedAt(row.updatedAt, root.displayNow)
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontXs
                                color: row.selected ? Theme.accentFillInk : Theme.inkSoft
                            }
                        }
                        Text {
                            objectName: "memoRowPreview"
                            Layout.fillWidth: true
                            Layout.leftMargin: 16
                            text: row.memoPreview
                            textFormat: Text.PlainText
                            font.pixelSize: Theme.fontSm
                            color: row.selected ? Theme.accentFillInk : Theme.inkSoft
                            elide: Text.ElideRight
                        }
                    }
                    TapHandler {
                        onTapped: {
                            // 先记「焦点来自点选」，再拿焦点：点选不画焦点环。
                            root.listFocusFromPointer = true;
                            root.selectMemo(row.memoId);
                            memoList.forceActiveFocus(Qt.MouseFocusReason);
                        }
                    }
                    // 右键：改这一条的分类（见 requestMoveCategory）。
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onTapped: function (eventPoint, button) {
                            root.listFocusFromPointer = true;
                            var p = row.mapToItem(null, eventPoint.position.x, eventPoint.position.y);
                            root.requestMoveCategory(row.memoId, p.x, p.y);
                        }
                    }
                    TapHandler {
                        acceptedDevices: PointerDevice.TouchScreen
                        onLongPressed: {
                            if (!root.beginDrag(row.memoId))
                                return;
                            touchDrag.cancelled = false;
                            root.touchDragMoved = false;
                            root.touchArmedId = row.memoId;
                            var p = row.mapToItem(null, point.position.x, point.position.y);
                            root.touchArmedPoint = p;
                            root.updateDrag(p.x, p.y);
                        }
                        onPressedChanged: {
                            if (pressed)
                                return;
                            var id = row.memoId;
                            Qt.callLater(function () {
                                if (!root || root.touchArmedId !== id || (touchDrag && touchDrag.active))
                                    return;
                                // 长按后拖过：照常结束排序。长按后没拖就松手：和 Mac 上右键一样，弹出改分类。
                                if (root.touchDragMoved) {
                                    root.finishDrag(touchDrag ? touchDrag.cancelled : true);
                                    return;
                                }
                                root.finishDrag(true);
                                root.requestMoveCategory(id, root.touchArmedPoint.x, root.touchArmedPoint.y);
                            });
                        }
                    }
                    DragHandler {
                        id: mouseDrag
                        target: null
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        acceptedButtons: Qt.LeftButton
                        dragThreshold: 6
                        property bool cancelled: false
                        onCanceled: cancelled = true
                        onActiveChanged: {
                            if (active) {
                                cancelled = false;
                                root.beginDrag(row.memoId);
                            } else {
                                var id = row.memoId;
                                // 取消信号可能稍后才到；回调执行时委托也可能已经被同步刷新销毁。
                                Qt.callLater(function () {
                                    if (root && root.draggingId === id)
                                        root.finishDrag(mouseDrag ? mouseDrag.cancelled : true);
                                });
                            }
                        }
                        onCentroidChanged: {
                            if (!active)
                                return;
                            var p = row.mapToItem(null, centroid.position.x, centroid.position.y);
                            root.updateDrag(p.x, p.y);
                        }
                    }
                    DragHandler {
                        id: touchDrag
                        target: null
                        acceptedDevices: PointerDevice.TouchScreen
                        // 始终跟踪触点，长按前不夺取滚动手势。中途启用处理器会错过按下事件。
                        dragThreshold: root.touchArmedId === row.memoId ? 0 : 32767
                        property bool cancelled: false
                        onCanceled: cancelled = true
                        onActiveChanged: {
                            if (active) {
                                cancelled = false;
                                root.touchDragMoved = true;
                                var p = row.mapToItem(null, centroid.position.x, centroid.position.y);
                                root.updateDrag(p.x, p.y);
                            } else {
                                var id = row.memoId;
                                Qt.callLater(function () {
                                    if (root && root.draggingId === id)
                                        root.finishDrag(touchDrag ? touchDrag.cancelled : true);
                                });
                            }
                        }
                        onCentroidChanged: {
                            if (!active)
                                return;
                            var p = row.mapToItem(null, centroid.position.x, centroid.position.y);
                            root.updateDrag(p.x, p.y);
                        }
                    }
                    // 落点线：淡焦糖底色上看不清，用实色 accent；左右收进 8，不顶到圆角外。
                    Rectangle {
                        objectName: "memoDropIndicator" + row.memoId
                        visible: root.draggingId >= 0 && root.dropTargetId === row.memoId
                        x: Theme.space8
                        width: parent.width - Theme.space8 * 2
                        height: 2
                        radius: 1
                        y: root.idsForCategory(row.categoryId).indexOf(root.draggingId) < root.idsForCategory(row.categoryId).indexOf(row.memoId) ? parent.height - height : 0
                        color: Theme.accent
                        z: 5
                    }
                }
            }
        }
        Rectangle {
            id: divider
            visible: !root.libraryEmpty
            anchors {
                left: leftPane.right
                leftMargin: Theme.space16
                top: parent.top
                bottom: parent.bottom
            }
            width: 1
            color: Theme.borderSubtle
        }
        Rectangle {
            id: paper
            objectName: "memoPaper"
            anchors {
                left: divider.right
                leftMargin: Theme.space16
                right: parent.right
                top: parent.top
                bottom: parent.bottom
            }
            color: Theme.surfaceRaised
            border.color: Theme.border
            border.width: 1
            radius: Theme.radiusLg
            visible: root.hasEditor
            ColumnLayout {
                id: editorColumn
                anchors.fill: parent
                anchors.margins: root.paperPadding
                anchors.bottomMargin: root.paperPadding + root.floatingKeyboardInset
                spacing: Theme.space12
                // 保存失败、另一台删除等情况的提示条。
                ErrorBanner {
                    objectName: "memoErrorBanner"
                    messageName: "memoError"
                    Layout.fillWidth: true
                    visible: root.errorMessage.length > 0
                    message: root.errorMessage
                    touchUi: root.touchUi
                }
                // 另一台删掉了正在编辑的这条：两个出口都要用户明确选，不会悄悄复活记录，也不会悄悄丢字。
                RowLayout {
                    visible: root.remoteDeleted
                    spacing: Theme.space8
                    PageActionButton {
                        objectName: "memoRecoverDeleted"
                        text: qsTr("另存为新备忘")
                        implicitHeight: root.touchUi ? 44 : Theme.controlHeightMd
                        onClicked: root.saveDeletedAsNew()
                    }
                    PageActionButton {
                        objectName: "memoDiscardDeleted"
                        text: qsTr("放弃修改")
                        implicitHeight: root.touchUi ? 44 : Theme.controlHeightMd
                        onClicked: root.discardDeleted()
                    }
                }
                // 竖屏仍保留两栏；编辑卡窄时只把卡内工具分成两行，避免更新时间和按钮挤掉分类名。
                Item {
                    Layout.fillWidth: true
                    implicitHeight: narrow ? toolHeight * 2 : toolHeight
                    readonly property int toolHeight: root.touchUi ? 44 : 36
                    readonly property bool narrow: width < categoryTag.implicitWidth + actions.implicitWidth + Theme.space8
                    // 这条备忘所在的分类，只显示、不能点：改分类在左边列表里右键这一条（iPad 长按后松手）。
                    // 按名字宽度显示，最宽 220（定稿），更长就在 220 内省略。宽度直接赋值、不经过布局取整，
                    // 放得下的名字不会因为字宽带小数被省略（见组头的同类问题）。
                    Item {
                        id: categoryTag
                        objectName: "memoCategoryTag"
                        readonly property bool hasCategory: root.editorCategoryId !== 0
                        // 圆点 8 加间距 8；没有分类时不留圆点的位置，「未分类」直接靠左。
                        readonly property int textOffset: hasCategory ? 8 + Theme.space8 : 0
                        implicitWidth: Math.min(220, textOffset + categoryLabel.implicitWidth)
                        width: Math.min(implicitWidth, parent.width)
                        height: parent.toolHeight
                        Accessible.role: Accessible.StaticText
                        Accessible.name: qsTr("分类：%1").arg(categoryLabel.text)
                        Rectangle {
                            visible: categoryTag.hasCategory
                            anchors.verticalCenter: parent.verticalCenter
                            width: 8
                            height: 8
                            radius: 4
                            color: root.category(root.editorCategoryId).color || Qt.rgba(1, 1, 1, 0)
                        }
                        Text {
                            id: categoryLabel
                            objectName: "memoCategoryLabel"
                            x: categoryTag.textOffset
                            width: categoryTag.width - x
                            anchors.verticalCenter: parent.verticalCenter
                            text: categoryTag.hasCategory ? root.category(root.editorCategoryId).name : qsTr("未分类")
                            textFormat: Text.PlainText
                            font.pixelSize: Theme.fontSm
                            color: Theme.inkSoft
                            elide: Text.ElideRight
                        }
                    }
                    RowLayout {
                        id: actions
                        anchors.right: parent.right
                        // 在工具行里上下居中，和左边科目按钮的中线对齐。
                        y: (parent.narrow ? parent.toolHeight : 0) + Math.round((parent.toolHeight - height) / 2)
                        spacing: Theme.space8
                        Text {
                            text: root.updatedAt.length > 0 ? MemoFormat.formatUpdatedAt(root.updatedAt, root.displayNow) + qsTr(" 更新") : ""
                            textFormat: Text.PlainText
                            font.pixelSize: Theme.fontXs
                            color: Theme.inkSoft
                        }
                        PageActionButton {
                            implicitHeight: root.touchUi ? 44 : Theme.controlHeightMd
                            objectName: "memoDeleteButton"
                            // 另一台已经删掉这条时，出口只有「另存为新备忘」和「放弃修改」；
                            // 再点删除只会报「已不存在」，还把上面的说明盖掉。
                            visible: !root.remoteDeleted
                            text: qsTr("删除")
                            onClicked: root.requestDelete()
                        }
                    }
                }
                TextField {
                    id: titleInput
                    objectName: "memoTitleInput"
                    // TextField/TextArea 不继承 Control，补齐与 Control 相同的键盘焦点判据。
                    readonly property bool visualFocus: activeFocus && (focusReason === Qt.TabFocusReason || focusReason === Qt.BacktabFocusReason || focusReason === Qt.ShortcutFocusReason)
                    Layout.fillWidth: true
                    // 输入框有 inputInset 的内边距（焦点环画在边上）。左右各伸出同样的距离，文字就和上面的科目按钮左边对齐（定稿），
                    // 焦点环落在纸面内边距里，不压字。上下同理，标题和正文之间的距离与定稿一致。
                    Layout.leftMargin: -root.inputInset
                    Layout.rightMargin: -root.inputInset
                    Layout.topMargin: Theme.space8 - root.inputInset
                    Layout.bottomMargin: -root.inputInset
                    Accessible.name: qsTr("备忘录标题")
                    text: root.editorTitle
                    placeholderText: qsTr("标题")
                    placeholderTextColor: Theme.inkSoft
                    color: Theme.inputInk
                    palette.text: Theme.inputInk
                    font.pixelSize: Theme.fontXl
                    font.bold: true
                    // Basic 样式的左内边距默认是 padding + 4，显式写死，文字才和上面的科目按钮对齐。
                    padding: root.inputInset
                    leftPadding: root.inputInset
                    // UTF-16 最大长度留给表情；真正的 60 字边界按服务一致的字符数限制。
                    maximumLength: root.titleLimit * 2
                    // 回车接着到正文开头写（见 continueInBody）；iPad 软键盘上的回车键显示成「下一项」。
                    EnterKey.type: Qt.EnterKeyNext
                    Keys.onReturnPressed: function (event) {
                        root.continueInBody(event);
                    }
                    Keys.onEnterPressed: function (event) {
                        root.continueInBody(event);
                    }
                    background: Rectangle {
                        color: Qt.rgba(1, 1, 1, 0)
                        radius: Theme.radiusSm
                        border.width: titleInput.visualFocus ? 2 : 0
                        border.color: Theme.focusRing
                    }
                    onTextEdited: {
                        if (MemoFormat.characterCount(text) > root.titleLimit) {
                            var end = MemoFormat.firstCharacters(text, root.titleLimit).length;
                            titleInput.remove(end, text.length);
                        }
                        root.editorTitle = text;
                        root.edited();
                    }
                }
                Flickable {
                    id: bodyScroll
                    onHeightChanged: root.ensureBodyCursorVisible()
                    objectName: "memoBodyScroll"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    // 与标题同理：伸出正文框的内边距，正文文字和科目按钮、标题左对齐；上方也抵掉。
                    Layout.leftMargin: -root.inputInset
                    Layout.rightMargin: -root.inputInset
                    Layout.topMargin: -root.inputInset
                    contentWidth: width
                    contentHeight: Math.max(height, bodyInput.contentHeight + Theme.space16)
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    TextArea.flickable: TextArea {
                        id: bodyInput
                        objectName: "memoBodyInput"
                        readonly property bool visualFocus: activeFocus && (focusReason === Qt.TabFocusReason || focusReason === Qt.BacktabFocusReason || focusReason === Qt.ShortcutFocusReason)
                        Accessible.name: qsTr("备忘录正文")
                        text: root.editorBody
                        textFormat: TextEdit.PlainText
                        wrapMode: TextEdit.Wrap
                        font.pixelSize: Theme.fontMd
                        color: Theme.inputInk
                        palette.text: Theme.inputInk
                        padding: root.inputInset
                        leftPadding: root.inputInset
                        background: Rectangle {
                            color: Qt.rgba(1, 1, 1, 0)
                            radius: Theme.radiusSm
                            border.width: bodyInput.visualFocus ? 2 : 0
                            border.color: Theme.focusRing
                        }
                        // 不用 textEdited：Qt 6.10 的 TextEdit 只在按键时发它，输入法上屏的文字不发——
                        // iPad 软键盘的每个字、Mac 拼音选字后的中文都走输入法，会被当成没改过。
                        // 改看文字本身，两种情况跳过：
                        // 1. 装载一条备忘时（readEditor）。text 绑定写入新内容的途中，编辑框还会再发信号：
                        //    输入法组合开着时先取消组合，按「旧文字」发一次；不间断空格等字符被规范后又发一次。
                        //    这时把文字写回 editorBody，会把旧备忘的内容写进模型，也会触发绑定循环。
                        // 2. 文字和 editorBody 相同（输入法组合中的拼音、行高排版也会发这个信号，但文字没变）。
                        onTextChanged: {
                            if (root.loadingEditor || text === root.editorBody)
                                return;
                            root.editorBody = text;
                            root.edited();
                        }
                        Component.onCompleted: {
                            if (root.textLayoutRef)
                                root.textLayoutRef.setLineHeight(bodyInput.textDocument, 1.5);
                        }
                    }
                    ScrollBar.vertical: PageScrollBar {
                        id: bodyBar
                        parent: root
                        x: root.width - width
                        // 滚动条挂在页面根上（贴窗口右缘），纵向要和正文区对齐。逐层加上各级的 y：
                        // 错误提示、两行工具栏或键盘避让让正文区移动时，滚动条跟着走。
                        // 不能用 mapToItem，它不随布局变化重新求值，只在创建时算一次。
                        y: content.y + paper.y + editorColumn.y + bodyScroll.y
                        height: bodyScroll.height
                        scrollAreaVisible: root.pageActive && root.hasEditor
                    }
                }
            }
        }
        // 编辑卡不在的时候（第一次读取就失败，或者换筛选后重读失败），卡里那条提示跟着看不见，
        // 页面看起来就像「没有备忘录」。这时把提示放在编辑卡的位置上，读取失败的带「重试」；左栏也不在时从框的左边开始。
        ErrorBanner {
            objectName: "memoPageErrorBanner"
            messageName: "memoPageError"
            visible: !root.hasEditor && root.errorMessage.length > 0
            anchors {
                top: parent.top
                left: root.libraryEmpty ? parent.left : divider.right
                leftMargin: root.libraryEmpty ? 0 : Theme.space16
                right: parent.right
            }
            message: root.errorMessage
            retryable: root.readFailure.length > 0
            touchUi: root.touchUi
            onRetryRequested: root.reload()
        }
    }
    // 改分类的弹层：列表里右键一条备忘（iPad 长按后不拖、直接松手；键盘 Shift+F10）时在指针处弹出。
    // 只列已有的分类（写过备忘的科目）和「未分类」，不在这里新建——新分类从右上角「新建」建。
    ChoicePopup {
        id: moveCategoryPopup
        objectName: "memoMovePopup"
        namePrefix: "memoMove"
        accessibleName: qsTr("更改分类")
        touchUi: root.touchUi
        parent: root
        width: 220
        transformOrigin: Popup.TopLeft
        // 挂在整页上，没有专属的按钮可以再点一次收起：点弹层外面任何地方都收起。
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        currentId: root.editorCategoryId
        options: root.memoCategoryOptions.concat([
            {
                id: 0,
                name: qsTr("未分类"),
                color: ""
            }
        ])
        // 打开时要改的那一条。选中项随时可能被同步换掉（这条被另一台删了，改选相邻的一条），不能拿选中项代替它。
        property int targetId: -1
        // 选完立刻保存：列表马上按新分类重新分组，不等一秒后的自动保存。
        // 选中项已经不是打开时那一条了，就什么都不改。重读时发现这条不在了会收起弹层（见 reload），
        // 这里再挡一道，不依赖「收起」一定发生在「选中」之前。
        onPicked: function (option) {
            if (root.drafting || root.selectedId !== moveCategoryPopup.targetId)
                return;
            root.chooseCategory(option.id);
            root.saveNow();
        }
        // 选了分类就把焦点交给列表，键盘可以接着上下换备忘。Esc、点外面关掉时不用管：
        // Qt 会把焦点还给弹层打开前拿着焦点的控件（测试里覆盖了这两种情况）。
        onFinished: function (option) {
            if (option)
                memoList.forceActiveFocus(Qt.PopupFocusReason);
        }
    }
    // 「新建 → 新建分类」挑科目：还没写过备忘的科目，最后是「新建科目…」（编号 -2 只是标记，不是科目）。
    // 挑好或建好后在那一科开一条草稿。
    ChoicePopup {
        id: subjectPicker
        objectName: "memoSubjectPicker"
        namePrefix: "memoSubject"
        accessibleName: qsTr("选一个科目作为分类")
        touchUi: root.touchUi
        parent: newButton
        x: newButton.width - width
        y: newButton.height + Theme.space4
        width: 220
        transformOrigin: Popup.TopRight
        options: root.unusedCategoryOptions.concat([
            {
                id: -2,
                name: qsTr("新建科目…"),
                color: "",
                action: true
            }
        ])
        onFinished: function (option) {
            if (!option)
                return;
            if (option.id === -2)
                categoryPrompt.openPrompt();
            else
                root.startDraft(option.id);
        }
    }
    // 右上角「新建」的菜单。两项都等菜单收起（finished）再做：「新建分类…」接着要在同一位置打开挑科目的弹层。
    ChoicePopup {
        id: newMenu
        objectName: "memoNewMenu"
        namePrefix: "memoNewMenu"
        accessibleName: qsTr("新建")
        touchUi: root.touchUi
        showLeading: false
        parent: newButton
        x: newButton.width - width
        y: newButton.height + Theme.space4
        width: 180
        transformOrigin: Popup.TopRight
        options: [
            {
                id: "memo",
                name: qsTr("新建备忘录")
            },
            {
                id: "category",
                name: qsTr("新建分类…")
            }
        ]
        onFinished: function (option) {
            if (!option)
                return;
            if (option.id === "memo")
                root.startDraft();
            else
                root.addCategory();
        }
    }
    NewCategoryPrompt {
        id: categoryPrompt
        parent: root
        categoryManagerRef: root.categoryManagerRef
        // 只从「新建 → 新建分类」打开：建好的科目开一条草稿，写下内容后成为新分类。
        onCreated: function (categoryId, name) {
            root.reload();
            root.startDraft(categoryId);
        }
    }
    Popup {
        id: deleteConfirm
        objectName: "memoDeleteConfirm"
        property int pendingId: -1
        property string pendingTitle: ""
        parent: root
        anchors.centerIn: parent
        width: Math.min(360, root.width - Theme.space24 * 2)
        padding: Theme.space24
        modal: true
        // 弹窗要拿到焦点 Esc 才生效；焦点先落在「取消」上，回车、空格都不会误删。
        // 用弹窗自己的焦点理由，鼠标打开时不画焦点环，按 Tab 才出现。
        focus: true
        closePolicy: Popup.CloseOnEscape
        onOpened: deleteCancelButton.forceActiveFocus(Qt.PopupFocusReason)
        onAboutToHide: pendingId = -1
        Overlay.modal: Rectangle {
            color: Theme.dialogScrim
        }
        background: Rectangle {
            color: Theme.surface
            radius: Theme.radiusLg
            border.color: Theme.border
            border.width: 1
        }
        contentItem: ColumnLayout {
            spacing: Theme.space12
            Text {
                Layout.fillWidth: true
                text: qsTr("删除这条备忘录？")
                textFormat: Text.PlainText
                color: Theme.inkStrong
                font.pixelSize: Theme.fontLg
                font.bold: true
            }
            // 和知识缺口的删除确认一样写出是哪一条；还没写字的草稿没有可写的，这一行不占位置。
            Text {
                objectName: "memoDeleteConfirmText"
                Layout.fillWidth: true
                visible: text.length > 0
                text: deleteConfirm.pendingTitle
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
            RowLayout {
                Layout.fillWidth: true
                Item {
                    Layout.fillWidth: true
                }
                PageActionButton {
                    id: deleteCancelButton
                    implicitHeight: root.touchUi ? 44 : Theme.controlHeightMd
                    objectName: "memoDeleteCancel"
                    text: qsTr("取消")
                    onClicked: root.cancelDelete()
                }
                PageActionButton {
                    implicitHeight: root.touchUi ? 44 : Theme.controlHeightMd
                    objectName: "memoDeleteConfirmButton"
                    text: qsTr("删除")
                    primary: true
                    onClicked: root.confirmDelete()
                }
            }
        }
    }
}
