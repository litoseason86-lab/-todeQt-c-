import QtQuick
import "../../qml/views"
import "../../qml"

// 离屏布局预览场景（非测试用例，qmltestrunner 不扫描）：
// 用与测试相同的桩渲染今日任务页，grabToImage 落盘后人工核对布局。
Rectangle {
    id: scene

    width: 1200
    height: 860
    color: "#dfe8e2"

    QtObject {
        id: taskManager

        signal tasksChanged

        function getTodayTasks() {
            return [
                { id: 1, title: "单词", completed: false, categoryText: "英语" },
                { id: 2, title: "操作系统", completed: false, categoryText: "专业课" }
            ]
        }
        function getOverdueUncompletedTasks() { return [] }
        function setTaskCompleted(id, completed) { return true }
        function updateTask(id, title, categoryId, date) { return true }
        function moveTasksToToday(ids) { return true }
    }

    QtObject {
        id: statisticsService

        function getTodayStats() {
            return { totalDuration: 5400, completedTasks: 0, totalTasks: 2, completionRate: 0 }
        }
    }

    QtObject {
        id: focusTimer

        signal focusCompleted(int duration)

        property int phase: 0
        property bool hasActiveSession: false
        property int elapsedSeconds: 0
    }

    QtObject {
        id: routineManager

        signal routinesChanged

        function materializeToday() {}
    }

    QtObject {
        id: logicalDayService

        signal changed
    }

    QtObject {
        id: appSettings

        signal dailyFocusGoalChanged

        property int dayStartHour: 4
        property bool reduceMotion: true
        property string rolloverIgnoredDate: ""
        property string focusGoalDate: ""
        property int focusGoalMinutes: 0

        function dailyFocusGoalMinutesForDate(isoDate) {
            return isoDate === focusGoalDate ? focusGoalMinutes : 0
        }
        function setDailyFocusGoal(isoDate, minutes) {
            focusGoalDate = isoDate
            focusGoalMinutes = minutes
            dailyFocusGoalChanged()
            return true
        }
    }

    TodayTaskView {
        id: view

        anchors.fill: parent
        settingsRef: appSettings
    }

    function dumpGeometry(item, depth) {
        if (!item) {
            return
        }
        if (item.objectName && item.objectName.length > 0) {
            console.log("GEO", item.objectName,
                        "x=" + Math.round(item.x), "y=" + Math.round(item.y),
                        "w=" + Math.round(item.width), "h=" + Math.round(item.height),
                        "vis=" + item.visible, "implH=" + Math.round(item.implicitHeight || 0))
        }
        for (var i = 0; i < item.children.length; i++) {
            scene.dumpGeometry(item.children[i], depth + 1)
        }
    }

    Timer {
        interval: 600
        running: true
        onTriggered: {
            scene.dumpGeometry(view, 0)
            scene.grabToImage(function (result) {
                result.saveToFile("/tmp/preview_today_unset.png")
                // 第二张：已设置目标 + 走秒中的展示态。
                appSettings.setDailyFocusGoal(view.todayIsoDate(), 240)
                focusTimer.phase = 1
                focusTimer.elapsedSeconds = 300
                secondShot.start()
            })
        }
    }

    Timer {
        id: secondShot

        interval: 400
        onTriggered: {
            scene.grabToImage(function (result) {
                result.saveToFile("/tmp/preview_today_set.png")
                Qt.quit()
            })
        }
    }
}
