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
    // 一条备忘都没有、也没在新建：只在框中间留一行字，不摆一个孤零零的「全部」和分隔线。
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
        root.readFailure = "";
        root.reading = true;
        var values = root.memoServiceRef.listMemos(-1);
        root.reading = false;
        if (root.readFailure.length > 0)
            return;
        root.allMemos = values;
        root.categories = root.categoryManagerRef && typeof root.categoryManagerRef.getAllCategories === "function" ? root.categoryManagerRef.getAllCategories() : [];
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
        if (root.drafting)
            return;
        var current = root.memo(root.selectedId);
        if (current) {
            if (!root.dirty)
                root.readEditor(current);
        } else if (root.dirty) {
            root.remoteDeleted = true;
            root.deletedNeighborIndex = oldIndex;
            root.errorMessage = qsTr("这条备忘录已在另一台设备删除。编辑中的内容还在这里，可以另存为新备忘，或放弃修改。");
        } else if (rows.count > 0) {
            root.selectedId = rows.get(Math.min(oldIndex, rows.count - 1)).memoId;
            root.readEditor(root.memo(root.selectedId));
        } else {
            root.clearEditor();
        }
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
    function startDraft() {
        if (!root.saveNow())
            return;
        // 连续点「新建」时，空草稿不会被保存，回去的目标仍是最初选中的那条。
        var back = root.drafting ? root.draftReturnId : root.selectedId;
        root.clearEditor();
        root.drafting = true;
        root.draftReturnId = back;
        root.editorCategoryId = Math.max(0, root.filterCategoryId);
        root.baselineCategoryId = root.editorCategoryId;
        // 点「新建」后直接能打标题；焦点环只给键盘 Tab 用，这里只要闪烁的光标。
        titleInput.forceActiveFocus(Qt.OtherFocusReason);
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
    function requestDelete() {
        if (root.drafting && root.editorTitle.trim().length === 0 && root.editorBody.trim().length === 0) {
            // 什么都没写的草稿没有内容可丢，直接放弃，不弹确认。
            root.discardDraft();
            return;
        }
        // 写了字的草稿和普通备忘一样先确认。草稿可能还没进数据库，编号先记 0，确认时再看它有没有被自动保存。
        deleteConfirm.pendingId = root.drafting ? 0 : root.selectedId;
        deleteConfirm.open();
    }
    function cancelDelete() {
        deleteConfirm.pendingId = -1;
        deleteConfirm.close();
    }
    function confirmDelete() {
        var id = deleteConfirm.pendingId;
        root.cancelDelete();
        if (id === 0) {
            if (root.drafting) {
                root.discardDraft();
                return;
            }
            // 确认框开着的时候，草稿已经被自动保存成了一条，按普通删除处理。
            id = root.selectedId;
        }
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
            implicitHeight: root.touchUi ? 44 : Theme.controlHeightMd
            objectName: "memoNewButton"
            text: qsTr("新建")
            glyph: "plus"
            primary: true
            onClicked: root.startDraft()
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
                        ToolTip.visible: hovered || visualFocus
                        ToolTip.text: modelData.name
                        ToolTip.delay: 500
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
                                Layout.maximumWidth: groupName.implicitWidth
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
                    TapHandler {
                        acceptedDevices: PointerDevice.TouchScreen
                        onLongPressed: {
                            if (!root.beginDrag(row.memoId))
                                return;
                            touchDrag.cancelled = false;
                            root.touchArmedId = row.memoId;
                            var p = row.mapToItem(null, point.position.x, point.position.y);
                            root.updateDrag(p.x, p.y);
                        }
                        onPressedChanged: {
                            if (pressed)
                                return;
                            var id = row.memoId;
                            Qt.callLater(function () {
                                if (root && root.touchArmedId === id && (!touchDrag || !touchDrag.active))
                                    root.finishDrag(touchDrag ? touchDrag.cancelled : true);
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
                // 保存失败、另一台删除等情况的提示条，和倒计时页的错误横幅同一套：危险色描边加「!」，
                // 不只靠红色表达出错；说明文字用正文色，读得清楚。
                Rectangle {
                    objectName: "memoErrorBanner"
                    Layout.fillWidth: true
                    visible: root.errorMessage.length > 0
                    implicitHeight: errorRow.implicitHeight + Theme.space8 * 2
                    radius: Theme.radiusMd
                    // 底色和倒计时页的错误横幅一样用 surfaceRaised：危险色的「!」压在沉底色上日间只有 4.44:1，不达正文 4.5:1。
                    color: Theme.surfaceRaised
                    border.color: Theme.dangerBorder
                    border.width: 1
                    RowLayout {
                        id: errorRow
                        anchors.fill: parent
                        anchors.leftMargin: Theme.space12
                        anchors.rightMargin: Theme.space12
                        anchors.topMargin: Theme.space8
                        anchors.bottomMargin: Theme.space8
                        spacing: Theme.space8
                        Text {
                            Layout.alignment: Qt.AlignTop
                            text: "!"
                            textFormat: Text.PlainText
                            color: Theme.danger
                            font.pixelSize: Theme.fontMd
                            font.weight: Font.Bold
                            Accessible.ignored: true
                        }
                        Text {
                            objectName: "memoError"
                            Layout.fillWidth: true
                            text: root.errorMessage
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            color: Theme.ink
                            font.pixelSize: Theme.fontSm
                        }
                    }
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
                // 竖屏仍保留两栏；编辑卡窄时只把卡内工具分成两行，避免按钮挤掉科目名。
                Item {
                    Layout.fillWidth: true
                    implicitHeight: narrow ? toolHeight * 2 : toolHeight
                    readonly property int toolHeight: root.touchUi ? 44 : 36
                    // 科目按名字宽度显示，最宽 220（定稿）；名字更长就在 220 内省略。
                    readonly property real chipWidth: Math.min(categoryChoice.implicitWidth, 220)
                    readonly property bool narrow: width < chipWidth + actions.implicitWidth + Theme.space8
                    Button {
                        id: categoryChoice
                        objectName: "memoCategoryButton"
                        width: Math.min(parent.chipWidth, parent.width)
                        height: root.touchUi ? 44 : 36
                        // Basic 样式按钮的横向内边距默认是 padding + 2，也要清零，宽度才和定稿一致。
                        padding: 0
                        horizontalPadding: 0
                        hoverEnabled: !root.touchUi
                        Accessible.name: qsTr("科目：%1").arg(categoryLabel.text)
                        onClicked: categoryPopup.opened ? categoryPopup.close() : categoryPopup.open()
                        // 定稿里的小胶囊：沉底色加描边。悬停、按下或弹层展开时逐级加深，看得出能点。
                        background: Rectangle {
                            objectName: "memoCategoryButtonBackground"
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width
                            height: 28
                            radius: 14
                            color: categoryChoice.down || categoryPopup.opened ? Theme.accentFillStrong : (categoryChoice.hovered ? Theme.accentSoft : Theme.surfaceSunken)
                            border.color: categoryChoice.visualFocus ? Theme.focusRing : Theme.border
                            border.width: categoryChoice.visualFocus ? 2 : 1
                            Behavior on color {
                                ColorAnimation {
                                    duration: Theme.reduceMotion ? 0 : 120
                                    easing.type: Easing.OutQuad
                                }
                            }
                        }
                        contentItem: RowLayout {
                            spacing: Theme.space8
                            // 没选科目时不留空圆点的位置，「不选科目」直接靠左，不显得歪。
                            Rectangle {
                                Layout.leftMargin: Theme.space12
                                visible: root.editorCategoryId !== 0
                                implicitWidth: 8
                                implicitHeight: 8
                                radius: 4
                                color: root.category(root.editorCategoryId).color || Qt.rgba(1, 1, 1, 0)
                            }
                            Text {
                                id: categoryLabel
                                objectName: "memoCategoryLabel"
                                Layout.fillWidth: true
                                Layout.leftMargin: root.editorCategoryId === 0 ? Theme.space12 : 0
                                text: root.editorCategoryId === 0 ? qsTr("不选科目") : root.category(root.editorCategoryId).name
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontSm
                                color: Theme.ink
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.rightMargin: Theme.space12
                                text: "▾"
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontSm
                                color: Theme.ink
                                rotation: categoryPopup.opened ? 180 : 0
                                Behavior on rotation {
                                    NumberAnimation {
                                        duration: Theme.reduceMotion ? 0 : 120
                                        easing.type: Easing.OutQuad
                                    }
                                }
                            }
                        }
                        HoverHandler {
                            cursorShape: Qt.PointingHandCursor
                        }
                    }
                    // 科目弹层：和专注页的任务选择同一套——玻璃底（不能模糊时退回实色）、选中项淡焦糖、悬停一层淡高光；
                    // 打开时停在当前科目，上下键移动、回车或空格选定、Esc 关闭。Qt 自带的 Menu 是写死的白底，夜间很刺眼。
                    Popup {
                        id: categoryPopup
                        objectName: "memoCategoryPopup"
                        // 选项：现有科目（按科目管理里的顺序）、不选科目，最后是新建。编号 -2 只是「新建科目…」的标记，不是科目。
                        readonly property var options: root.categories.map(function (entry) {
                            return {
                                id: Number(entry.id),
                                name: String(entry.name),
                                color: String(entry.color || "")
                            };
                        }).concat([
                            {
                                id: 0,
                                name: qsTr("不选科目"),
                                color: ""
                            },
                            {
                                id: -2,
                                name: qsTr("新建科目…"),
                                color: ""
                            }
                        ])
                        // 用方向键移动过才给当前项画焦点环；鼠标点开时只靠淡焦糖底标出当前科目，不再套一圈。
                        property bool keyboardNavigated: false
                        function choose(index) {
                            var option = categoryPopup.options[index];
                            if (!option)
                                return;
                            categoryPopup.close();
                            if (option.id === -2)
                                categoryPrompt.openPrompt();
                            else
                                root.chooseCategory(option.id);
                        }
                        parent: categoryChoice
                        x: 0
                        y: Math.round(categoryChoice.height / 2 + 14 + Theme.space4)
                        width: Math.max(220, categoryChoice.width)
                        margins: Theme.space8
                        padding: Theme.space8
                        modal: false
                        dim: false
                        focus: true
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                        onOpened: {
                            categoryPopup.keyboardNavigated = false;
                            var index = categoryPopup.options.findIndex(function (option) {
                                return option.id === root.editorCategoryId;
                            });
                            categoryList.currentIndex = Math.max(0, index);
                            categoryList.positionViewAtIndex(categoryList.currentIndex, ListView.Contain);
                            categoryList.forceActiveFocus(Qt.PopupFocusReason);
                        }
                        // 关掉后焦点回到科目按钮，键盘用户接着往下走；新建科目的输入框打开时不抢它的焦点。
                        onClosed: {
                            if (!categoryPrompt.opened)
                                categoryChoice.forceActiveFocus(Qt.PopupFocusReason);
                        }
                        background: GlassPanel {
                            objectName: "memoCategoryPopupBackground"
                            radius: Theme.radiusLg
                            color: Theme.glassBlurAllowed ? Theme.glassDialog : Theme.glassSolidCard
                            solidFallback: !Theme.glassBlurAllowed
                            panelShadowEnabled: true
                        }
                        contentItem: ListView {
                            id: categoryList
                            objectName: "memoCategoryList"
                            implicitHeight: Math.min(contentHeight, 320)
                            clip: true
                            model: categoryPopup.options
                            spacing: 2
                            boundsBehavior: Flickable.StopAtBounds
                            keyNavigationEnabled: true
                            Accessible.role: Accessible.List
                            Accessible.name: qsTr("选择科目")
                            Keys.onUpPressed: {
                                categoryPopup.keyboardNavigated = true;
                                categoryList.decrementCurrentIndex();
                            }
                            Keys.onDownPressed: {
                                categoryPopup.keyboardNavigated = true;
                                categoryList.incrementCurrentIndex();
                            }
                            Keys.onReturnPressed: categoryPopup.choose(categoryList.currentIndex)
                            Keys.onEnterPressed: categoryPopup.choose(categoryList.currentIndex)
                            Keys.onSpacePressed: categoryPopup.choose(categoryList.currentIndex)
                            ScrollBar.vertical: PageScrollBar {}
                            delegate: ItemDelegate {
                                id: option
                                required property var modelData
                                required property int index
                                // 「新建科目…」上方有一条分隔线，和科目列表分开。
                                readonly property bool isAction: option.modelData.id === -2
                                readonly property bool current: option.modelData.id === root.editorCategoryId
                                objectName: "memoCategoryOption" + option.modelData.id
                                width: ListView.view.width
                                topInset: option.isAction ? Theme.space8 + 1 : 0
                                topPadding: option.topInset
                                implicitHeight: (root.touchUi ? 44 : Theme.controlHeightMd) + option.topInset
                                leftPadding: Theme.space12
                                rightPadding: Theme.space12
                                hoverEnabled: !root.touchUi
                                Accessible.name: option.modelData.name
                                onClicked: categoryPopup.choose(option.index)
                                background: Rectangle {
                                    radius: Theme.radiusSm
                                    color: option.current ? Theme.accentFill : (option.hovered ? Theme.glassHover : Theme.glassHoverIdle)
                                    border.width: categoryList.activeFocus && categoryPopup.keyboardNavigated && categoryList.currentIndex === option.index ? 2 : 0
                                    border.color: Theme.focusRing
                                    Behavior on color {
                                        ColorAnimation {
                                            duration: Theme.reduceMotion ? 0 : 120
                                            easing.type: Easing.OutQuad
                                        }
                                    }
                                }
                                Rectangle {
                                    visible: option.isAction
                                    x: Theme.space4
                                    y: Math.round(Theme.space8 / 2)
                                    width: option.width - Theme.space4 * 2
                                    height: 1
                                    color: Theme.borderSubtle
                                }
                                contentItem: RowLayout {
                                    spacing: Theme.space8
                                    Item {
                                        implicitWidth: 12
                                        implicitHeight: 12
                                        Rectangle {
                                            visible: !option.isAction
                                            anchors.centerIn: parent
                                            width: 8
                                            height: 8
                                            radius: 4
                                            color: option.modelData.color.length > 0 ? option.modelData.color : Qt.rgba(1, 1, 1, 0)
                                        }
                                        GlyphIcon {
                                            visible: option.isAction
                                            anchors.centerIn: parent
                                            name: "plus"
                                            size: 12
                                            color: Theme.inkSoft
                                            Accessible.ignored: true
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: option.modelData.name
                                        textFormat: Text.PlainText
                                        font.pixelSize: Theme.fontMd
                                        font.weight: option.current ? Font.Medium : Font.Normal
                                        color: option.current ? Theme.accentFillInk : (option.isAction ? Theme.inkSoft : Theme.ink)
                                        elide: Text.ElideRight
                                    }
                                }
                            }
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
                        placeholderText: qsTr("写下现在的进度…")
                        placeholderTextColor: Theme.inkSoft
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
        // 空状态只留一行弱色文字，和知识缺口页同一个取舍：这一页做什么，点进来之前就知道了。
        // 放在整个框的正中；inkSoft 而不是 inkMuted，这一行是正文，要够 4.5:1 的对比度。
        Text {
            objectName: "memoEmptyHint"
            anchors.centerIn: root.libraryEmpty ? parent : paper
            visible: !root.hasEditor
            text: qsTr("还没有备忘录")
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontMd
        }
    }
    NewCategoryPrompt {
        id: categoryPrompt
        parent: root
        categoryManagerRef: root.categoryManagerRef
        onCreated: function (categoryId, name) {
            root.reload();
            root.chooseCategory(categoryId);
        }
    }
    Popup {
        id: deleteConfirm
        objectName: "memoDeleteConfirm"
        property int pendingId: -1
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
            Text {
                Layout.fillWidth: true
                text: qsTr("删除后无法撤销。")
                textFormat: Text.PlainText
                color: Theme.danger
                font.pixelSize: Theme.fontSm
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
