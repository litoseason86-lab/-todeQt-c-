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
    property bool remoteDeleted: false
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
        root.editorTitle = String(entry.title);
        root.editorBody = String(entry.body);
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
            root.errorMessage = qsTr("这条备忘录已在另一台设备删除。编辑中的内容仍保留在这里。");
        } else if (rows.count > 0) {
            root.selectedId = rows.get(Math.min(oldIndex, rows.count - 1)).memoId;
            root.readEditor(root.memo(root.selectedId));
        } else {
            root.clearEditor();
        }
    }
    function saveNow() {
        // 先提交输入法正在组合的文字，切页/退出不能丢掉还没进入 text 的候选内容。
        // 静态检查器将 Qt.inputMethod 推断为 QObject，运行时实际是有 commit 的 QInputMethod。
        // qmllint disable missing-property
        Qt.inputMethod.commit();
        // qmllint enable missing-property
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
        return true;
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
    function startDraft() {
        if (!root.saveNow())
            return;
        root.clearEditor();
        root.drafting = true;
        root.editorCategoryId = Math.max(0, root.filterCategoryId);
        root.baselineCategoryId = root.editorCategoryId;
        titleInput.forceActiveFocus(Qt.TabFocusReason);
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
    function requestDelete() {
        if (root.drafting) {
            root.clearEditor();
            return;
        }
        deleteConfirm.pendingId = root.selectedId;
        deleteConfirm.open();
    }
    function cancelDelete() {
        deleteConfirm.pendingId = -1;
        deleteConfirm.close();
    }
    function confirmDelete() {
        var id = deleteConfirm.pendingId;
        root.cancelDelete();
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
        onTriggered: root.saveNow()
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
                        Accessible.name: modelData.name
                        ToolTip.visible: hovered || visualFocus
                        ToolTip.text: modelData.name
                        ToolTip.delay: 500
                        background: Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width
                            height: 26
                            radius: 13
                            color: capsule.selected ? Theme.accentFill : Qt.rgba(1, 1, 1, 0)
                            border.width: capsule.visualFocus ? 2 : 1
                            border.color: capsule.visualFocus ? Theme.focusRing : Theme.borderSubtle
                        }
                        contentItem: Text {
                            id: label
                            text: capsule.modelData.name
                            textFormat: Text.PlainText
                            font.pixelSize: Theme.fontSm
                            color: capsule.selected ? Theme.accentFillInk : Theme.inkSoft
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                            leftPadding: Theme.space8
                            rightPadding: Theme.space8
                        }
                        onClicked: root.selectFilter(Number(modelData.id))
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
                    width: memoList.width
                    height: active ? 30 : 0
                    active: root.filterCategoryId < 0
                    sourceComponent: RowLayout {
                        objectName: "memoGroup" + groupLoader.section
                        spacing: 0
                        Text {
                            objectName: "memoGroupName"
                            Layout.fillWidth: true
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
                    }
                }
                Keys.onUpPressed: root.stepSelection(-1)
                Keys.onDownPressed: root.stepSelection(1)
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
                    height: 66
                    padding: Theme.space8
                    background: Rectangle {
                        objectName: "memoRowBackground"
                        radius: Theme.radiusMd
                        color: row.selected ? Theme.accentFill : Qt.rgba(1, 1, 1, 0)
                    }
                    contentItem: ColumnLayout {
                        spacing: Theme.space4
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space8
                            Rectangle {
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
                    Rectangle {
                        objectName: "memoDropIndicator" + row.memoId
                        visible: root.draggingId >= 0 && root.dropTargetId === row.memoId
                        width: parent.width
                        height: 2
                        y: root.idsForCategory(row.categoryId).indexOf(root.draggingId) < root.idsForCategory(row.categoryId).indexOf(row.memoId) ? parent.height - height : 0
                        color: Theme.accentFill
                        z: 5
                    }
                }
            }
        }
        Rectangle {
            id: divider
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
                anchors.margins: Theme.space16
                anchors.bottomMargin: Theme.space16 + root.floatingKeyboardInset
                spacing: Theme.space12
                Text {
                    objectName: "memoError"
                    Layout.fillWidth: true
                    visible: root.errorMessage.length > 0
                    text: root.errorMessage
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: Theme.danger
                    font.pixelSize: Theme.fontSm
                }
                PageActionButton {
                    objectName: "memoRecoverDeleted"
                    visible: root.remoteDeleted
                    text: qsTr("另存为新备忘")
                    implicitHeight: root.touchUi ? 44 : Theme.controlHeightMd
                    onClicked: root.saveDeletedAsNew()
                }
                // 竖屏仍保留两栏；编辑卡窄时只把卡内工具分成两行，避免按钮挤掉科目名。
                Item {
                    Layout.fillWidth: true
                    implicitHeight: narrow ? toolHeight * 2 : toolHeight
                    readonly property int toolHeight: root.touchUi ? 44 : 36
                    readonly property bool narrow: width < 220 + actions.implicitWidth + Theme.space8
                    Button {
                        id: categoryChoice
                        objectName: "memoCategoryButton"
                        width: Math.min(220, Math.max(80, parent.width - (parent.narrow ? 0 : actions.implicitWidth + Theme.space8)))
                        height: root.touchUi ? 44 : 36
                        padding: 0
                        Accessible.name: root.category(root.editorCategoryId).name
                        onClicked: categoryMenu.open()
                        background: Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width
                            height: 28
                            radius: 14
                            color: Theme.surfaceSunken
                            border.color: categoryChoice.visualFocus ? Theme.focusRing : Theme.border
                            border.width: categoryChoice.visualFocus ? 2 : 1
                        }
                        contentItem: RowLayout {
                            spacing: Theme.space8
                            Rectangle {
                                Layout.leftMargin: Theme.space8
                                implicitWidth: 8
                                implicitHeight: 8
                                radius: 4
                                color: root.category(root.editorCategoryId).color || Qt.rgba(1, 1, 1, 0)
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root.editorCategoryId === 0 ? qsTr("不选科目") : root.category(root.editorCategoryId).name
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontSm
                                color: Theme.ink
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.rightMargin: Theme.space8
                                text: "▾"
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontSm
                                color: Theme.inkSoft
                            }
                        }
                        Menu {
                            id: categoryMenu
                            y: categoryChoice.height
                            Instantiator {
                                model: root.categories
                                delegate: MenuItem {
                                    required property var modelData
                                    implicitHeight: root.touchUi ? 44 : 36
                                    text: modelData.name
                                    onTriggered: root.chooseCategory(Number(modelData.id))
                                }
                                onObjectAdded: function (index, object) {
                                    categoryMenu.insertItem(index, object);
                                }
                                onObjectRemoved: function (index, object) {
                                    categoryMenu.removeItem(object);
                                }
                            }
                            MenuItem {
                                implicitHeight: root.touchUi ? 44 : 36
                                text: qsTr("不选科目")
                                onTriggered: root.chooseCategory(0)
                            }
                            MenuSeparator {}
                            MenuItem {
                                implicitHeight: root.touchUi ? 44 : 36
                                text: qsTr("新建科目…")
                                onTriggered: categoryPrompt.openPrompt()
                            }
                        }
                    }
                    RowLayout {
                        id: actions
                        anchors.right: parent.right
                        y: parent.narrow ? parent.toolHeight : 0
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
                    Accessible.name: qsTr("备忘录标题")
                    text: root.editorTitle
                    placeholderText: qsTr("标题")
                    placeholderTextColor: Theme.inkSoft
                    color: Theme.inputInk
                    palette.text: Theme.inputInk
                    font.pixelSize: Theme.fontXl
                    font.bold: true
                    padding: Theme.space4
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
                        padding: Theme.space4
                        background: Rectangle {
                            color: Qt.rgba(1, 1, 1, 0)
                            radius: Theme.radiusSm
                            border.width: bodyInput.visualFocus ? 2 : 0
                            border.color: Theme.focusRing
                        }
                        onTextEdited: {
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
                        y: bodyScroll.mapToItem(root, 0, 0).y
                        height: bodyScroll.height
                        scrollAreaVisible: root.pageActive && root.hasEditor
                    }
                }
            }
        }
        Text {
            anchors.centerIn: paper
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
        closePolicy: Popup.CloseOnEscape
        onAboutToHide: pendingId = -1
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
