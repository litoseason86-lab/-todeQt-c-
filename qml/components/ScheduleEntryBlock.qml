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
    // 块太窄时按优先级砍信息。七列平分一个 900 宽的窗口后每列只有约 110px，
    // 一行装不下的内容会截断成「A1教学楼A151…」这种读不出东西的省略号。
    // 保留顺序是 课程名 > 地点 > 时间：课程名和地点是「现在该去哪上什么」唯一的答案，
    // 时间则已经由块在纵轴上的位置表达了，砍掉不丢信息。
    // 单双周不在这个序列里——它由右下角的角标承载，不占行，因此不参与取舍。
    readonly property bool narrow: root.width < 150

    // —— 块内纵向空间预算 ——
    //
    // 让 Column 自己溢出再被 clip 裁掉是不行的：地点换到第二行之后，
    // 90px 高的块会把最后那行从中间切开，露出半个字——比不画还糟，
    // 因为它看起来像渲染坏了。
    //
    // 按「行高 × 行数」估算过一版，结果算漏了 Column 的行间距、行高系数也偏小，
    // 时间那行照样被切。所以改成读排版后的真实坐标：每一行只在
    // 「它的底边还落在预算之内」时才画。Column 里靠前的行的 y 不受靠后的行影响，
    // 因此这样引用不会形成绑定环。
    readonly property int contentBudget: root.height - content.anchors.topMargin - 4
    // 行高系数 1.7 是量出来的，不是估的：中文字形本身的行盒约为字号的 1.63–1.67 倍
    // （11px 的地点行实测 18.4px）。此前按 1.5 估，每行少算 2px 多，
    // 短块里累积起来就足以把最后一行切掉半个字。向上取整到 1.7 留一点余量。
    readonly property int metaLineHeight: Math.round(Theme.fontXs * 1.7)
    readonly property int titleLineHeight: Math.round((root.narrow ? Theme.fontSm : Theme.fontMd) * 1.7)
    // 标题最多两行——但前提是两行标题之后还留得下一行地点。
    // 只顾着把标题排满两行，会让 54px 的块（一节 60 分钟的课，最常见的一种）
    // 只剩标题、地点被整行挤到预算之外画不出来。
    // 优先级是「课程名 + 地点」这一对，而不是「课程名占满」。
    readonly property int titleMaxLines: root.compact ? 1
        : (root.contentBudget >= root.titleLineHeight * 2 + content.spacing + root.metaLineHeight
           ? 2 : 1)

    // 附注行：时间 + 生效周次范围。单双周不在这里——它在右下角的角标上，
    // 因为窄块里第三行经常放不下，而单双周是唯一「不写出来就会让人以为课表出错」的信息
    // （用户从第 1 周翻到第 2 周会发现课变了却没有任何解释）。
    // 角标不占行高也不占行宽，于是它在任何尺寸下都能保住。
    readonly property string metaText: {
        if (root.narrow) {
            return ""
        }
        var time = ScheduleWeeks.formatMinutes(root.startMinutes) + "–"
                 + ScheduleWeeks.formatMinutes(root.endMinutes)
        // 传 0 只取周次范围，单双周由角标表达，避免同一件事写两遍。
        var range = ScheduleWeeks.weekRangeLabel(root.weekStart, root.weekEnd,
                                                 0, root.semesterWeeks)
        return range.length > 0 ? (time + " · " + range) : time
    }
    readonly property string parityBadge: ScheduleWeeks.parityLabel(root.weekParity)

    signal editRequested(int entryId)
    signal deleteRequested(int entryId, string title)

    radius: Theme.radiusMd
    color: hoverHandler.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
    border.color: hoverHandler.hovered ? Theme.accent : Theme.border
    border.width: 1
    clip: true

    Accessible.role: Accessible.Button
    // 单双周必须念出来。它在界面上只剩一个视觉角标，读屏用户拿不到任何其它线索，
    // 而「这门课只在单周上」正是不知道就会跑错教室的那种信息。
    Accessible.name: root.title + " " + ScheduleWeeks.formatMinutes(root.startMinutes)
                     + " 到 " + ScheduleWeeks.formatMinutes(root.endMinutes)
                     + (root.location.length > 0 ? " 地点 " + root.location : "")
                     + (root.parityBadge.length > 0 ? " " + root.parityBadge : "")
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
        // 3px 的脊在一片米色里几乎看不出是根「脊」。加到 4px，它才真正起到
        // 「一眼分出这是几门不同的课」的作用，也是块与纸面之间的分界。
        width: 4
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
        anchors.leftMargin: 6
        anchors.right: parent.right
        anchors.rightMargin: 5
        anchors.top: parent.top
        anchors.topMargin: root.compact ? 3 : 5
        spacing: 2

        Text {
            id: titleText

            width: parent.width
            text: root.title
            textFormat: Text.PlainText
            // 课程名是这一格里唯一需要一眼认出的东西，靠字重与字色而不是字号称重：
            // 窄列里 13px 会把「Java EE框架技术」断成「…技」+「术」，
            // 一个孤字挂在第二行比小一号难读得多。宽列才升到 13px。
            // 块内因此只有 12/11 或 13/11 两个字号，层级由 DemiBold + inkStrong 承担。
            font.pixelSize: root.narrow ? Theme.fontSm : Theme.fontMd
            font.weight: Font.DemiBold
            color: Theme.inkStrong
            elide: Text.ElideRight
            maximumLineCount: root.titleMaxLines
            wrapMode: Text.Wrap
        }

        Text {
            id: locationText

            width: parent.width
            // 既要判「几行」也要判「画不画」。只判行数的话，标题占满两行之后
            // 地点会整行落在预算之外，被块的 clip 切成半个字。
            //
            // 这里用本行的实际高度而不是上面那个保守的估算值：
            // 估算值按 1.7 倍取，比真实行高多约 3px，46px 的块（刚过 compact 门槛）
            // 会因此被判成「放不下」而整行丢掉地点——守卫本该防的是半个字，
            // 不是把信息也一起挡掉。implicitHeight 不依赖 visible，不会成环。
            //
            // 在当前字号下这条守卫不会真的触发：titleMaxLines 已经保证了标题之后
            // 一定留得下一行地点（变异测试验证过，去掉它没有任何用例转红）。
            // 保留是因为两者依据不同——titleMaxLines 用的是 1.7 这个**估算**系数，
            // 这里用的是排版后的**实际**高度。换字体或改字号时估算会先失准，
            // 那时这条守卫就是「宁可不画，也不出半个字」的最后一道。
            visible: !root.compact && root.location.length > 0
                     && locationText.y + locationText.implicitHeight <= root.contentBudget
            text: root.location
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontXs
            // 「上课在哪」和「上什么课」同等重要，用正文色而不是次要色；
            // 次要色留给时间与周次这类可以扫过去的信息。
            color: Theme.ink
            // 换行而不是省略。一行装不下「A1教学楼A1514 程蓓蓓」，省略号一截，
            // 这一格就再也回答不了「我该去哪」——而块内纵向本来就有富余空间。
            wrapMode: Text.Wrap
            // 第二行只在放得下整行时才要；locationText.y 只取决于标题，不取决于本行行数。
            maximumLineCount: locationText.y + root.metaLineHeight * 2 <= root.contentBudget ? 2 : 1
            elide: Text.ElideRight
        }

        Text {
            id: metaLine

            width: parent.width
            // 底边超出预算就整行不画。半行字看起来像渲染坏了，比没有更糟。
            visible: !root.compact && root.metaText.length > 0
                     && metaLine.y + metaLine.implicitHeight <= root.contentBudget
            text: root.metaText
            textFormat: Text.PlainText
            font.family: Theme.fontFamilyClock
            font.pixelSize: Theme.fontXs
            color: Theme.inkSoft
            elide: Text.ElideRight
        }
    }

    // 单双周角标。放在流式布局之外，因此不占任何行高，也不挤占任何一行的宽度——
    // 这是它能在最窄的块里也活下来的原因。
    //
    // 贴右下角而不是右上角：右上角压着课程名的第一行，为它让出宽度会把
    // 「Java EE框架技术」截成「Java EE…」，而课程名是这一格最不能丢的东西。
    // 右下角对齐的是地点的最后一行，那一行通常只剩教师名这样的短尾巴。
    Rectangle {
        id: parityChip

        objectName: "scheduleParityChip"
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.margins: 3
        width: parityLabel.implicitWidth + 8
        height: parityLabel.implicitHeight + 2
        radius: height / 2
        color: Theme.accentFill
        // 角标在右下、删除按钮在右上，两者互不遮挡，所以不该一悬停就整个消失
        // （那是它还放在右上角时留下的规则）。只有块矮到两者会叠在一起时才让位。
        visible: root.parityBadge.length > 0 && !root.compact

        Text {
            id: parityLabel

            anchors.centerIn: parent
            text: root.parityBadge
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontXs
            color: Theme.accentFillInk
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
    // Delete 与 Backspace 都要接。Keys.onDeletePressed 对应的是 Qt.Key_Delete，
    // 而 Mac 笔记本主键盘上那颗写着 delete 的键发的是 Qt.Key_Backspace
    // （Key_Delete 要按 fn+delete）。只接前者等于本机上根本删不掉，
    // 而上面那句注释还在说「键盘用户可以聚焦后按 Delete」。
    Keys.onDeletePressed: root.deleteRequested(root.entryId, root.title)
    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Backspace) {
            root.deleteRequested(root.entryId, root.title)
            event.accepted = true
        }
    }
}
