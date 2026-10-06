import QtQuick

// 替身保留完整记录和调用参数；测试可以明确区分“改了模型”和“真的请求写库”。
QtObject {
    id: root
    readonly property int maxTitleLength: 60
    readonly property int maxBodyLength: 10000
    property var records: []
    property var creates: []
    property var updates: []
    property var deletes: []
    property var reorders: []
    // 写库调用的先后顺序（"update:编号"、"create"）：creates、updates 各记各的，看不出谁先谁后。
    property var calls: []
    property bool failSave: false
    // 为真时读取列表失败：和真实服务一样，在读取函数内部同步发出失败信号，再返回空列表。
    property bool failList: false
    // 读取、保存失败时报的原因。真实服务遇到数据库未打开时两者是同一句话，用例要能设成相同的文字。
    readonly property string defaultListFailure: "读取备忘录列表失败：数据库不可用"
    readonly property string defaultSaveFailure: "磁盘不可写"
    property string listFailureMessage: defaultListFailure
    property string saveFailureMessage: defaultSaveFailure
    signal memosChanged
    signal operationFailed(string message)
    function reset(values) {
        records = JSON.parse(JSON.stringify(values));
        creates = [];
        updates = [];
        deletes = [];
        reorders = [];
        calls = [];
        failSave = false;
        failList = false;
        listFailureMessage = defaultListFailure;
        saveFailureMessage = defaultSaveFailure;
    }
    function listMemos(categoryId) {
        if (failList) {
            operationFailed(listFailureMessage);
            return [];
        }
        return records.filter(function (r) {
            return categoryId < 0 || r.categoryId === categoryId;
        });
    }
    // 界面用的读取：成败放在返回值里，和真实服务一样不发失败信号。
    function readMemos() {
        if (failList)
            return {
                ok: false,
                memos: [],
                error: listFailureMessage
            };
        return {
            ok: true,
            memos: records.slice()
        };
    }
    function getMemo(id) {
        return records.find(function (r) {
            return r.id === id;
        }) || ({});
    }
    function createMemo(title, body, categoryId) {
        calls = calls.concat(["create"]);
        creates = creates.concat([
            {
                title: title,
                body: body,
                categoryId: categoryId
            }
        ]);
        if (failSave) {
            operationFailed(saveFailureMessage);
            return -1;
        }
        var id = 100 + creates.length;
        records = records.concat([makeRecord(id, title, body, categoryId)]);
        memosChanged();
        return id;
    }
    function updateMemo(id, changes) {
        calls = calls.concat(["update:" + id]);
        updates = updates.concat([
            {
                id: id,
                changes: JSON.parse(JSON.stringify(changes))
            }
        ]);
        if (failSave) {
            operationFailed(saveFailureMessage);
            return false;
        }
        var next = records.slice();
        for (var i = 0; i < next.length; ++i) {
            if (next[i].id !== id)
                continue;
            next[i] = Object.assign({}, next[i], changes);
            next[i].displayTitle = next[i].title || next[i].body.split("\n")[0];
            next[i].preview = next[i].body.split("\n")[0];
        }
        records = next;
        memosChanged();
        return true;
    }
    function deleteMemo(id) {
        deletes = deletes.concat([id]);
        records = records.filter(function (r) {
            return r.id !== id;
        });
        memosChanged();
        return true;
    }
    function reorderMemos(categoryId, ids) {
        reorders = reorders.concat([
            {
                categoryId: categoryId,
                ids: ids.slice()
            }
        ]);
        var others = records.filter(function (r) {
            return r.categoryId !== categoryId;
        });
        var moved = ids.map(function (id) {
            return root.getMemo(id);
        });
        records = moved.concat(others);
        memosChanged();
        return true;
    }
    function makeRecord(id, title, body, categoryId) {
        return {
            id: id,
            title: title,
            body: body,
            displayTitle: title || body.split("\n")[0],
            preview: body.split("\n")[0],
            categoryId: categoryId,
            categoryName: categoryId === 1 ? "高等数学与概率统计特别长的科目名称" : categoryId === 2 ? "物理" : "",
            categoryColor: categoryId === 0 ? "" : "#98753c",
            sortOrder: id,
            createdAt: "2026-10-02T04:00:00.000Z",
            updatedAt: "2026-10-02T04:51:46.728Z"
        };
    }
}
