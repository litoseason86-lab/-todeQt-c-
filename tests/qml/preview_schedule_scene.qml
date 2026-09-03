import QtQuick
import "../../qml/views"
import "../../qml"

// 离屏版式预览场景（非测试用例，qmltestrunner 不扫描 preview_ 前缀）：
// 用用户真实的 8 条课表数据、按真实窗口尺寸渲染待办页，落盘后人工核对版式。
// 尺寸取 900×760 逻辑像素——这是用户截图里的实际窗口大小，
// 七列平分后每列只有约 107px，是版式压力最大的那一档；
// 拿 1200 宽做走查会把「地点被截断」这类问题全部藏起来。
Rectangle {
    id: scene

    width: 900
    height: 760
    color: "#cfd9d2"

    QtObject {
        id: appSettings

        property int dayStartHour: 4
        property string semesterStartDate: "2026-08-31"
        property int semesterWeeks: 16
        property string scheduleDisplayMode: "time"
        property bool scheduleShowWeekend: true
    }

    QtObject {
        id: logicalDayService
        signal changed()
    }

    QtObject {
        id: categoryManager
        signal categoriesChanged()
        function getAllCategories() { return [] }
    }

    QtObject {
        id: scheduleService

        signal scheduleChanged()
        signal periodsChanged()
        signal operationFailed(string message)

        readonly property int maxTitleLength: 60
        readonly property int maxLocationLength: 60
        readonly property int maxWeekIndex: 60
        readonly property int maxPeriodCount: 24

        // 与线上库内容一致（含最长的那条地点「A1教学楼A1514 程蓓蓓」）。
        property var allEntries: [
            { id: 1, title: "Java EE框架技术", location: "A1210 孙露露", weekday: 2,
              startMinutes: 480, endMinutes: 580, durationMinutes: 100,
              weekStart: 1, weekEnd: 8, weekParity: 0,
              categoryId: undefined, categoryName: "", categoryColor: "" },
            { id: 2, title: "人工智能", location: "A1208 张梦园", weekday: 2,
              startMinutes: 600, endMinutes: 700, durationMinutes: 100,
              weekStart: 1, weekEnd: 8, weekParity: 0,
              categoryId: undefined, categoryName: "", categoryColor: "" },
            { id: 3, title: "信息系统分析与设计", location: "A1教学楼A1514 程蓓蓓", weekday: 2,
              startMinutes: 840, endMinutes: 940, durationMinutes: 100,
              weekStart: 1, weekEnd: 8, weekParity: 0,
              categoryId: undefined, categoryName: "", categoryColor: "" },
            { id: 4, title: "Android应用开发技术", location: "A1220 朱银龙", weekday: 2,
              startMinutes: 960, endMinutes: 1060, durationMinutes: 100,
              weekStart: 1, weekEnd: 8, weekParity: 0,
              categoryId: undefined, categoryName: "", categoryColor: "" },
            { id: 5, title: "人工智能", location: "实验楼404 张梦园", weekday: 3,
              startMinutes: 960, endMinutes: 1060, durationMinutes: 100,
              weekStart: 1, weekEnd: 8, weekParity: 0,
              categoryId: undefined, categoryName: "", categoryColor: "" },
            { id: 6, title: "Java EE框架技术", location: "图书馆302 孙露露", weekday: 4,
              startMinutes: 600, endMinutes: 700, durationMinutes: 100,
              weekStart: 1, weekEnd: 8, weekParity: 1,
              categoryId: undefined, categoryName: "", categoryColor: "" },
            { id: 8, title: "信息系统分析与设计", location: "图书馆402 程蓓蓓", weekday: 4,
              startMinutes: 960, endMinutes: 1060, durationMinutes: 100,
              weekStart: 1, weekEnd: 8, weekParity: 0,
              categoryId: undefined, categoryName: "", categoryColor: "" }
        ]

        function getEntriesForWeek(weekIndex) {
            return weekIndex < 1 ? [] : scheduleService.allEntries
        }
        function getPeriods() {
            return [
                { index: 1, startMinutes: 480, endMinutes: 525 },
                { index: 2, startMinutes: 535, endMinutes: 580 },
                { index: 3, startMinutes: 600, endMinutes: 645 },
                { index: 4, startMinutes: 655, endMinutes: 700 },
                { index: 5, startMinutes: 840, endMinutes: 885 },
                { index: 6, startMinutes: 895, endMinutes: 940 },
                { index: 7, startMinutes: 960, endMinutes: 1005 },
                { index: 8, startMinutes: 1015, endMinutes: 1060 }
            ]
        }
        function findConflicts() { return [] }
    }

    SchedulePlanView {
        id: view

        anchors.fill: parent
        scheduleServiceRef: scheduleService
        settingsRef: appSettings
        categoryManagerRef: categoryManager
        logicalDayServiceRef: logicalDayService
        logicalNowProvider: function () { return new Date(2026, 8, 3, 10, 0) }
    }

    property string outPrefix: "/tmp/preview_schedule"

    Timer {
        interval: 700
        running: true
        onTriggered: {
            scene.grabToImage(function (result) {
                result.saveToFile(scene.outPrefix + "_time.png")
                appSettings.scheduleDisplayMode = "period"
                view.refresh()
                periodShot.start()
            })
        }
    }

    // 第三张：关掉周末列的五列版。这份课表周六周日一门课都没有，
    // 七列里有两列永远是空的，五列版每列能宽出约 40%。
    Timer {
        id: weekdayShot
        interval: 500
        onTriggered: {
            scene.grabToImage(function (result) {
                result.saveToFile(scene.outPrefix + "_weekday.png")
                // 第四张：夜间主题。改了字色与底色就必须两套主题各看一眼。
                Theme.activeThemeId = "starry"
                appSettings.scheduleShowWeekend = true
                view.refresh()
                darkShot.start()
            })
        }
    }

    Timer {
        id: darkShot
        interval: 500
        onTriggered: {
            scene.color = "#3b3a44"
            scene.grabToImage(function (result) {
                result.saveToFile(scene.outPrefix + "_dark.png")
                Qt.quit()
            })
        }
    }

    Timer {
        id: periodShot
        interval: 500
        onTriggered: {
            scene.grabToImage(function (result) {
                result.saveToFile(scene.outPrefix + "_period.png")
                appSettings.scheduleDisplayMode = "time"
                appSettings.scheduleShowWeekend = false
                view.refresh()
                weekdayShot.start()
            })
        }
    }
}
