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
    signal categoriesChanged
    function getAllCategories() {
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
