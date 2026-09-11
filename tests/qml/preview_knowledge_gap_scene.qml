import QtQuick
import "../../qml/views"
import "../../qml"

// 离屏布局预览场景（非测试用例，qmltestrunner 不扫描 preview_ 前缀）：
// 用与测试相同的桩渲染知识缺口页，grabToImage 落盘后人工核对布局。
Rectangle {
    id: scene

    width: 1200
    height: 860
    color: "#dfe8e2"

    property bool emptyMode: false

    readonly property var sampleGaps: [
        { id: 1, title: "线代第 3 章相似对角化的条件没搞懂", detail: "教材第 87 页那道例题",
          categoryId: 1, categoryName: "数学", categoryColor: "#d4a574",
          sourceTaskId: 3, sourceTaskTitle: "复习线代第 3 章", priority: 2, status: 1,
          dueDate: "2026-09-01", scheduled: true, overdue: true, overdueDays: 10, dueToday: false,
          resolution: "", linkedTaskId: 0, linkedTaskCompleted: false, linkedTaskTitle: "" },
        { id: 2, title: "英语长难句里的插入语怎么断", detail: "", categoryId: 2,
          categoryName: "英语", categoryColor: "#8fae8b", sourceTaskId: 0, sourceTaskTitle: "",
          priority: 1, status: 1, dueDate: "2026-09-11", scheduled: true, overdue: false,
          overdueDays: 0, dueToday: true, resolution: "", linkedTaskId: 8,
          linkedTaskCompleted: true, linkedTaskTitle: "英语阅读" },
        { id: 3, title: "政治史纲的时间线总是记混", detail: "", categoryId: 0, categoryName: "",
          categoryColor: "", sourceTaskId: 0, sourceTaskTitle: "", priority: 0, status: 1,
          dueDate: "2026-09-20", scheduled: true, overdue: false, overdueDays: 0, dueToday: false,
          resolution: "", linkedTaskId: 0, linkedTaskCompleted: false, linkedTaskTitle: "" },
        { id: 4, title: "还没想好什么时候看的那个数据结构问题", detail: "", categoryId: 3,
          categoryName: "专业课", categoryColor: "#c98f8f", sourceTaskId: 0, sourceTaskTitle: "",
          priority: 2, status: 0, dueDate: "", scheduled: false, overdue: false, overdueDays: 0,
          dueToday: false, resolution: "", linkedTaskId: 0, linkedTaskCompleted: false,
          linkedTaskTitle: "" }
    ]

    QtObject {
        id: appSettings

        property int dayStartHour: 4
    }

    QtObject {
        id: categoryManager

        function getAllCategories() {
            return [{ id: 1, name: "数学", color: "#d4a574" }]
        }
    }

    QtObject {
        id: logicalDayService

        signal changed
    }

    QtObject {
        id: knowledgeGapService

        signal gapsChanged()
        signal operationFailed(string message)

        readonly property int maxTitleLength: 100

        function listGaps(statusFilter, categoryId, searchText, limit) {
            return scene.emptyMode ? [] : scene.sampleGaps
        }
        function convertToTask(id, date) { return 1 }
        function resolveGap(id, resolution) { return true }
        function reopenGap(id) { return true }
        function deleteGap(id) { return true }
        function getReminderSummary() {
            return { valid: true, dueToday: 1, overdue: 1, unscheduled: 1,
                     openTotal: 4, oldestOverdueDays: 10 }
        }
    }

    KnowledgeGapView {
        id: view

        anchors.fill: parent
        knowledgeGapServiceRef: knowledgeGapService
        categoryManagerRef: categoryManager
        logicalDayServiceRef: logicalDayService
        settingsRef: appSettings
        pageActive: true
    }

    function dumpGeometry(item, depth) {
        if (!item) {
            return
        }
        if (item.objectName && item.objectName.length > 0) {
            console.log("GEO", item.objectName,
                        "x=" + Math.round(item.x), "y=" + Math.round(item.y),
                        "w=" + Math.round(item.width), "h=" + Math.round(item.height),
                        "implW=" + Math.round(item.implicitWidth || 0),
                        "implH=" + Math.round(item.implicitHeight || 0))
        }
        for (var i = 0; i < item.children.length; i++) {
            scene.dumpGeometry(item.children[i], depth + 1)
        }
    }

    Timer {
        interval: 700
        running: true
        onTriggered: {
            scene.dumpGeometry(view, 0)
            scene.grabToImage(function (result) {
                result.saveToFile("/tmp/preview_gap_list.png")
                scene.emptyMode = true
                view.reload()
                emptyShot.start()
            })
        }
    }

    Timer {
        id: emptyShot

        interval: 400
        onTriggered: {
            scene.grabToImage(function (result) {
                result.saveToFile("/tmp/preview_gap_empty.png")
                Qt.quit()
            })
        }
    }
}
