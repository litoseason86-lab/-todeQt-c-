pragma ComponentBehavior: Bound

import QtQuick
import ".."
import "../ScheduleWeeks.js" as ScheduleWeeks

// 课表网格里的一块课程。内容区保持清晰不做实时玻璃——
// 项目规则里毛玻璃只留给导航栏、浮动工具栏和弹窗，成片的内容卡必须可读优先。
Rectangle {
    id: root

    property int entryId: -1
    property string title: ""
    property string location: ""
    property int startMinutes: 0
    property int endMinutes: 0
    property int weekStart: 1
    property int weekEnd: 1
    property int weekParity: 0
    property int semesterWeeks: 20
    property string categoryColor: ""
    // 块太矮时（短课或节次行很窄）只留标题，避免文字挤成一团糊掉。
    readonly property bool compact: root.height < 46
    // 块太窄时按优先级砍信息。七列平分一个默认窗口后每列只有约 95px，
    // 四行内容会全部截断成「多媒体55(A1…」这种读不出东西的省略号。
    // 保留顺序是 课程名 > 地点 > 时间 > 周次：
    // 时间已经由块在纵轴上的位置表达了，周次可以在编辑弹窗里看，
    // 而课程名和地点是「现在该去哪上什么」唯一的答案。
    readonly property bool narrow: root.width < 120

    signal editRequested(int entryId)
    signal deleteRequested(int entryId, string title)

    radius: Theme.radiusMd
    color: hoverHandler.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
    border.color: hoverHandler.hovered ? Theme.accent : Theme.border
    border.width: 1
    clip: true

    Accessible.role: Accessible.Button
    Accessible.name: root.title + " " + ScheduleWeeks.formatMinutes(root.startMinutes)
                     + " 到 " + ScheduleWeeks.formatMinutes(root.endMinutes)
                     + (root.location.length > 0 ? " 地点 " + root.location : "")
    activeFocusOnTab: true

    Behavior on color {
        ColorAnimation { duration: Theme.reduceMotion ? 0 : 140; easing.type: Easing.OutQuad }
    }

    Behavior on border.color {
        ColorAnimation { duration: Theme.reduceMotion ? 0 : 140; easing.type: Easing.OutQuad }
    }

    // 左侧科目色条。科目未设置时用强调色兜底，保证每块课都有一条可辨识的色脊，
    // 而不是留一段空白让块看起来像残缺的。
    Rectangle {
        id: colorSpine

        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.margins: 1
        width: 3
        radius: width / 2
        color: root.categoryColor.length > 0 ? root.categoryColor : Theme.accent
    }

    // 键盘焦点环：仅靠颜色变化无法满足可达性，焦点必须始终可见。
    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: "transparent"
        border.color: Theme.focusRing
        border.width: 2
        visible: root.activeFocus
    }

    Column {
        id: content

        anchors.left: colorSpine.right
        anchors.leftMargin: Theme.space8
        anchors.right: parent.right
        anchors.rightMargin: Theme.space4
        anchors.top: parent.top
        anchors.topMargin: root.compact ? 3 : Theme.space4
        spacing: 1

        Text {
            width: parent.width
            text: root.title
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontSm
            font.weight: Font.Medium
            color: Theme.inkStrong
            elide: Text.ElideRight
            maximumLineCount: root.compact ? 1 : 2
            wrapMode: Text.Wrap
        }

        Text {
            width: parent.width
            visible: !root.compact && root.location.length > 0
            text: root.location
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontXs
            color: Theme.inkSoft
            elide: Text.ElideRight
        }

        Text {
            width: parent.width
            visible: !root.compact && !root.narrow
            text: ScheduleWeeks.formatMinutes(root.startMinutes) + "–"
                  + ScheduleWeeks.formatMinutes(root.endMinutes)
            textFormat: Text.PlainText
            font.family: Theme.fontFamilyClock
            font.pixelSize: Theme.fontXs
            color: Theme.inkSoft
            elide: Text.ElideRight
        }

        Text {
            width: parent.width
            // 覆盖整学期且每周都上的课不显示这行，避免每块课都挂一句废话。
            //
            // 窄块退化成只写「单周 / 双周」：周次范围可以去编辑弹窗看，
            // 但单双周不能省——不写的话，用户从第 1 周翻到第 2 周会发现
            // 课变了却没有任何解释，只会以为课表出错了。两个字挤得下。
            readonly property string rangeText: root.narrow
                ? ScheduleWeeks.parityLabel(root.weekParity)
                : ScheduleWeeks.weekRangeLabel(root.weekStart, root.weekEnd,
                                               root.weekParity, root.semesterWeeks)
            visible: !root.compact && rangeText.length > 0
            text: rangeText
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontXs
            color: Theme.accentInk
            elide: Text.ElideRight
        }
    }

    HoverHandler {
        id: hoverHandler
    }

    TapHandler {
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.editRequested(root.entryId)
    }

    // 悬停才出现的删除入口。悬停不是唯一通路：键盘用户可以聚焦后按 Delete，
    // 编辑弹窗里也有删除按钮，符合「悬停只是增强」这条要求。
    Rectangle {
        id: deleteButton

        objectName: "scheduleEntryDelete-" + root.entryId
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 2
        width: 18
        height: 18
        radius: width / 2
        visible: hoverHandler.hovered || deleteHover.hovered
        color: deleteHover.hovered ? Theme.danger : Theme.surfaceSunken
        border.color: deleteHover.hovered ? Theme.danger : Theme.border
        border.width: 1

        Text {
            anchors.centerIn: parent
            text: "×"
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontSm
            color: deleteHover.hovered ? Theme.surface : Theme.inkSoft
        }

        HoverHandler {
            id: deleteHover
        }

        TapHandler {
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: root.deleteRequested(root.entryId, root.title)
        }
    }

    Keys.onReturnPressed: root.editRequested(root.entryId)
    Keys.onEnterPressed: root.editRequested(root.entryId)
    Keys.onDeletePressed: root.deleteRequested(root.entryId, root.title)
}
