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
    property bool failSave: false
    // 为真时读取列表失败：和真实服务一样，在读取函数内部同步发出失败信号，再返回空列表。
    property bool failList: false
    signal memosChanged
    signal operationFailed(string message)
    function reset(values) {
        records = JSON.parse(JSON.stringify(values));
        creates = [];
        updates = [];
        deletes = [];
        reorders = [];
        failSave = false;
        failList = false;
    }
    function listMemos(categoryId) {
        if (failList) {
            operationFailed("读取备忘录列表失败：数据库不可用");
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
                error: "读取备忘录列表失败：数据库不可用"
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
        creates = creates.concat([
            {
                title: title,
                body: body,
                categoryId: categoryId
            }
        ]);
        if (failSave) {
            operationFailed("磁盘不可写");
            return -1;
        }
        var id = 100 + creates.length;
        records = records.concat([makeRecord(id, title, body, categoryId)]);
        memosChanged();
        return id;
    }
    function updateMemo(id, changes) {
        updates = updates.concat([
            {
                id: id,
                changes: JSON.parse(JSON.stringify(changes))
            }
        ]);
        if (failSave) {
            operationFailed("磁盘不可写");
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
