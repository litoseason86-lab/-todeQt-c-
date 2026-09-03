import QtQuick
import QtTest
import "../../qml/components"

// 课程块的纵向排版必须永远「要么整行画、要么不画」。
//
// 半行字看起来像渲染坏了，比信息缺失更糟，而它只在特定块高才出现：
// 一节 60 分钟的课在 0.9 px/分 下正好是 54px，是最常见也最容易踩到的一档。
// 属性断言看不见这个问题（每个 Text 自身都是「正常」的），
// 截图走查也只覆盖当时那几个块高，所以这里按高度逐档扫。
TestCase {
    id: testCase
    name: "ScheduleBlockFit"
    when: windowShown
    width: 400
    height: 900
    visible: true

    // 24 是网格给极短条目保底的最小可点高度，136 是跨两节的长块。
    // 中间几档对应 30/45/60/75/90/100/120 分钟的课。
    readonly property var heights: [24, 27, 30, 40, 46, 54, 63, 72, 81, 90, 99, 108, 136]

    Column {
        id: bench

        Repeater {
            model: testCase.heights

            ScheduleEntryBlock {
                required property var modelData

                objectName: "fitBlock-" + modelData
                // 900 宽窗口七列平分后的真实列宽，也是版式压力最大的一档。
                width: 107
                height: modelData
                title: "信息系统分析与设计"
                location: "A1教学楼A1514 程蓓蓓"
                startMinutes: 840
                endMinutes: 940
                weekStart: 1
                weekEnd: 8
                weekParity: 1
                semesterWeeks: 16
            }
        }
    }

    // 块内那一列里第 index 个文字行（0=课程名 1=地点 2=附注）。
    // 断言要落在真正被画出来的东西上，而不是驱动它的属性——
    // 断属性的话，「属性算对了但没人用它」这种改动会安静地通过。
    function lineOf(block, index) {
        for (var i = 0; i < block.children.length; ++i) {
            var child = block.children[i]
            if (child instanceof Column) {
                return child.children[index]
            }
        }
        return null
    }

    function contentBottomOf(block) {
        // 块内的文字都装在唯一那个 Column 里；取所有可见行的最大底边。
        for (var i = 0; i < block.children.length; ++i) {
            var child = block.children[i]
            if (child instanceof Column) {
                var bottom = 0
                for (var j = 0; j < child.children.length; ++j) {
                    var line = child.children[j]
                    if (line.visible) {
                        bottom = Math.max(bottom, child.y + line.y + line.implicitHeight)
                    }
                }
                return bottom
            }
        }
        return -1
    }

    function test_noLineIsEverClipped() {
        wait(150)
        for (var i = 0; i < testCase.heights.length; ++i) {
            var h = testCase.heights[i]
            var block = findChild(bench, "fitBlock-" + h)
            verify(block !== null, "找不到高度 " + h + " 的块")
            var bottom = testCase.contentBottomOf(block)
            verify(bottom > 0, "高度 " + h + " 的块一行都没画")
            verify(bottom <= h,
                   "高度 " + h + " 的块内容溢出 " + (bottom - h).toFixed(1)
                   + "px，末行会被裁成半个字")
        }
    }

    function test_shortBlockKeepsLocationRatherThanASecondTitleLine() {
        wait(150)
        // 54px（一节 60 分钟的课）只排得下两行。标题占满两行会把地点整行挤出预算，
        // 这一格于是只剩课程名，回答不了「我该去哪」——
        // 「课程名 + 地点」这一对才是它的答案，标题占满不是。
        var block = findChild(bench, "fitBlock-54")
        verify(block !== null)
        var title = testCase.lineOf(block, 0)
        var location = testCase.lineOf(block, 1)
        verify(title !== null && location !== null)
        compare(title.lineCount, 1, "54px 的块必须把第二行让给地点")
        verify(location.visible, "54px 的块必须画出地点")
        compare(location.text, "A1教学楼A1514 程蓓蓓")

        // 高一档（90px，一节 100 分钟的课）就该把第二行还给标题，地点也能排两行。
        var taller = findChild(bench, "fitBlock-90")
        verify(taller !== null)
        compare(testCase.lineOf(taller, 0).lineCount, 2)
        compare(testCase.lineOf(taller, 1).lineCount, 2)
    }

    // 每一档块高都必须画得出地点。裁切守卫可以让一行「不画」来避免半个字，
    // 但如果它把地点也一并挡掉，问题只是从「看起来坏了」变成「信息没了」。
    function test_locationIsNeverSilentlyDropped() {
        wait(150)
        for (var i = 0; i < testCase.heights.length; ++i) {
            var h = testCase.heights[i]
            var block = findChild(bench, "fitBlock-" + h)
            var location = testCase.lineOf(block, 1)
            verify(location !== null)
            // compact（<46px）是明确的取舍：那么矮只留课程名，块内放不下第二行。
            if (h >= 46) {
                verify(location.visible, "高度 " + h + " 的块把地点整行丢掉了")
            }
        }
    }

    // 角标贴右下角、删除按钮贴右上角，正常块高下互不遮挡；
    // 但块矮到 24px（网格给极短条目保底的最小可点高度）时两者会叠在一起，
    // 悬停时删除按钮会压在角标上，看起来像一个粘住的脏印子。
    function test_parityBadgeStepsAsideInVeryShortBlocks() {
        wait(150)
        var shortBlock = findChild(bench, "fitBlock-24")
        verify(shortBlock !== null)
        verify(shortBlock.compact, "24px 的块应处于 compact 态")
        var chip = findChild(shortBlock, "scheduleParityChip")
        verify(chip !== null, "找不到单双周角标")
        verify(!chip.visible, "矮块里角标必须让位，否则会和删除按钮叠在一起")

        // 正常高度下它必须在——这是单双周唯一的视觉载体。
        var normal = findChild(bench, "fitBlock-90")
        verify(findChild(normal, "scheduleParityChip").visible)
    }

    function test_parityBadgeSurvivesEveryWidthAndIsAnnounced() {
        wait(150)
        // 单双周在界面上只剩一个视觉角标，读屏用户必须能从名称里拿到它，
        // 否则「这门课只在单周上」就成了不知道就会跑错教室的信息。
        var block = findChild(bench, "fitBlock-90")
        verify(block !== null)
        compare(block.parityBadge, "单周")
        verify(String(block.Accessible.name).indexOf("单周") >= 0,
               "无障碍名称必须念出单双周，实际：" + block.Accessible.name)
    }
}
