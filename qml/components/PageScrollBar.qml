import QtQuick
import QtQuick.Controls
import ".."

// 页面级竖向滚动条。全应用统一贴在窗口最右缘；仪表盘右侧还有专注面板，
// 那里贴在任务面板右边线外侧（见 DashboardView）。
//
// 样式沿用本周计划、课表、今日专注原先各写一份的细条：8px 宽、4px 滑块，
// 常态用边框色，悬停或拖动转强调色；轨道透明——主内容区是透明的，
// 任何实色轨道都会变成压在壁纸上的一条白带。
//
// 摆放由使用方负责，分两种：
// - 挂在 Flickable / ListView 上、且不指定 parent：Qt 会把它放进那个列表并贴右缘摆好；
// - 挂在 ScrollView 上，或者要摆到滚动区外面（玻璃框外的页边）：
//   在使用处声明它、让它成为框外那个 Item 的子项，再写 x / y / height。
//   ScrollBar 的 parent 不是那个 Flickable 时 Qt 不会替它排版，漏写几何它会缩在左上角。
ScrollBar {
    id: root

    // 滚动条摆在滚动区外面时，滚动区被隐藏（比如切到另一个分段）它不会跟着消失：
    // 它不是滚动区的子项，而隐藏的列表仍在报告内容比视口高。由使用方把列表的可见性接进来。
    property bool scrollAreaVisible: true

    objectName: "pageScrollBar"
    policy: ScrollBar.AsNeeded
    width: 8
    // 换掉 contentItem 之后，Basic 风格「放得下就隐藏」的逻辑也一起没了：
    // 它写在自带滑块的透明度状态里。不补这一行，内容放得下时会画出一整条满高的滑块，
    // 看起来像一条没用的竖线。
    visible: root.scrollAreaVisible
             && (root.policy === ScrollBar.AlwaysOn
                 || (root.policy === ScrollBar.AsNeeded && root.size < 1.0))

    contentItem: Rectangle {
        implicitWidth: 4
        radius: Theme.radiusSm
        color: root.pressed || root.hovered ? Theme.accent : Theme.border
    }

    background: Rectangle {
        objectName: "pageScrollTrack"

        color: "transparent"
    }
}
