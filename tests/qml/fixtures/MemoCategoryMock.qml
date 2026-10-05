import QtQuick

QtObject {
    property var records: [
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
    ]
    // 为真时读取科目失败：和真实服务一样，在读取函数内部同步发出失败信号，再返回空列表。
    property bool failRead: false
    signal categoriesChanged
    signal operationFailed(string message)
    function getAllCategories() {
        if (failRead) {
            operationFailed("科目加载失败: 磁盘 I/O 错误");
            return [];
        }
        return records;
    }
    function getCategories() {
        return records;
    }
    function getActiveCategories() {
        return records;
    }
    function addCategory(name, color) {
        var id = records.length + 1;
        records = records.concat([
            {
                id: id,
                name: name,
                color: color
            }
        ]);
        categoriesChanged();
        return id;
    }
}
