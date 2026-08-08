import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml/components"
import "../../qml/components/settings"
import "../../qml"

// 输入框字色。Qt Quick Controls 的 TextField 不从我们的令牌取正文/占位/选区颜色，
// 而是从 palette 取，Basic 风格的默认 palette.text 写死 #353637——既不跟随本应用主题，
// 也不跟随 macOS 外观。夜间主题下它压在 #332c22 的输入框上对比度只有 1.14:1，
// 用户打进去的字等于看不见（2026-08-09 在「添加新任务」上报）。
//
// 这个文件守两件事：每个带输入框的根节点都接管了 palette；接管后的实际字色在
// 明暗两套主题下都达到可读门槛。
TestCase {
    id: testCase
    name: "InputInk"
    when: windowShown
    width: 600
    height: 500

    QtObject {
        id: categoryManagerMock

        function getAllCategories() {
            return [{ id: 1, name: "数学", color: "#d4a574" }]
        }
    }

    Component { id: addComponent; AddTaskDialog {} }
    Component { id: editComponent; EditTaskDialog {} }
    Component { id: categoryComponent; CategoryDialog {} }
    Component { id: routineComponent; RoutineDialog {} }
    Component { id: countdownComponent; CountdownDialog {} }
    Component { id: exportComponent; ExportDialog {} }
    Component { id: goalFormComponent; GoalFormDialog {} }
    Component { id: taskItemComponent; TaskItem { width: 400 } }
    Component { id: settingsGeneralComponent; SettingsGeneralPage {} }

    // 相对亮度 → WCAG 对比度。用来把「看得清」变成一个可以判定的数。
    function relativeLuminance(color) {
        function channel(value) {
            return value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
    }

    function contrastRatio(a, b) {
        var la = relativeLuminance(a)
        var lb = relativeLuminance(b)
        var hi = Math.max(la, lb)
        var lo = Math.min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    function rootsUnderTest() {
        return [
            { name: "AddTaskDialog", comp: addComponent },
            { name: "EditTaskDialog", comp: editComponent },
            { name: "CategoryDialog", comp: categoryComponent },
            { name: "RoutineDialog", comp: routineComponent },
            { name: "CountdownDialog", comp: countdownComponent },
            { name: "ExportDialog", comp: exportComponent },
            { name: "GoalFormDialog", comp: goalFormComponent },
            { name: "TaskItem", comp: taskItemComponent },
            { name: "SettingsGeneralPage", comp: settingsGeneralComponent }
        ]
    }

    function cleanup() {
        Theme.activeThemeId = "warm"
    }

    function test_every_input_owning_root_takes_over_the_palette_data() {
        return rootsUnderTest()
    }

    function test_every_input_owning_root_takes_over_the_palette(row) {
        var item = createTemporaryObject(row.comp, testCase)
        verify(item, row.name + " 没能实例化")

        // 不接管的话这里会是 Basic 风格写死的 #353637，与主题无关。
        compare(String(item.palette.text), String(Theme.inputInk), row.name + " 的正文字色")
        compare(String(item.palette.placeholderText), String(Theme.inputPlaceholderInk),
                row.name + " 的占位字色")
        compare(String(item.palette.highlight), String(Theme.inputSelection),
                row.name + " 的选区底色")
        compare(String(item.palette.highlightedText), String(Theme.inputSelectedInk),
                row.name + " 的选中字色")
        compare(String(item.palette.window), String(Theme.inputPopupSurface),
                row.name + " 的下拉面板底色")
        compare(String(item.palette.mid), String(Theme.inputPopupBorder),
                row.name + " 的下拉面板边框")
        compare(String(item.palette.light), String(Theme.inputPopupHighlight),
                row.name + " 的下拉高亮行底色")
        compare(String(item.palette.midlight), String(Theme.inputPopupHighlight),
                row.name + " 的下拉按下行底色")
        compare(String(item.palette.base), String(Theme.inputControlSurface),
                row.name + " 的默认输入框底色")
        compare(String(item.palette.button), String(Theme.inputControlSurface),
                row.name + " 的闭合下拉框底色")
        compare(String(item.palette.buttonText), String(Theme.inputControlInk),
                row.name + " 的闭合下拉框文字色")
    }

    function test_palette_follows_the_theme_data() {
        return [
            { tag: "夜间", themeId: "starry" },
            { tag: "日间", themeId: "warm" }
        ]
    }

    function test_palette_follows_the_theme(row) {
        Theme.activeThemeId = row.themeId
        var dialog = createTemporaryObject(addComponent, testCase)
        verify(dialog)
        dialog.open()
        wait(50)

        var field = findChild(dialog, "titleField")
        verify(field)

        // 关键回归点：字色必须跟着主题翻转。写死的默认值在这两轮里是同一个数，
        // 所以「两套主题下取到的字色不同」本身就能证明接管生效了。
        compare(String(field.color), String(Theme.inkStrong))
        compare(String(field.placeholderTextColor), String(Theme.inkMuted))

        var background = findChild(dialog, "titleFieldBackground")
        verify(background)
        // 正文按 WCAG AA 正文门槛 4.5:1，占位按 UI 组件门槛 3:1。
        var textContrast = contrastRatio(field.color, background.color)
        verify(textContrast >= 4.5,
               row.tag + "输入文字对比度只有 " + textContrast.toFixed(2) + ":1")
        var placeholderContrast = contrastRatio(field.placeholderTextColor, background.color)
        verify(placeholderContrast >= 3.0,
               row.tag + "占位文字对比度只有 " + placeholderContrast.toFixed(2) + ":1")

        dialog.close()
    }

    function test_dropdown_panel_is_readable_data() {
        return [
            { tag: "夜间", themeId: "starry" },
            { tag: "日间", themeId: "warm" }
        ]
    }

    function test_dropdown_panel_is_readable(row) {
        Theme.activeThemeId = row.themeId
        var dialog = createTemporaryObject(addComponent, testCase,
                                           { categoryManagerRef: categoryManagerMock })
        verify(dialog)
        dialog.open()
        wait(50)

        var combo = findChild(dialog, "categoryComboBox")
        verify(combo)
        combo.popup.open()
        wait(80)

        // 这就是上报的那一处：面板底走 palette.window，不接管就是白的，
        // 而选项文字是跟着主题的米白 —— 夜间主题下白底米白字，看不见。
        var panel = combo.popup.background.color
        var itemContrast = contrastRatio(Theme.ink, panel)
        verify(itemContrast >= 4.5,
               row.tag + "下拉选项对比度只有 " + itemContrast.toFixed(2) + ":1")

        // 高亮行换了底色，同样要能读。highlightedText 同时服务选区和高亮行，
        // 所以这条一旦为了「让选区更醒目」被单独调开，另一处必然发暗。
        var highlightContrast = contrastRatio(Theme.inputSelectedInk, Theme.inputPopupHighlight)
        verify(highlightContrast >= 4.5,
               row.tag + "下拉高亮行对比度只有 " + highlightContrast.toFixed(2) + ":1")
        var selectionContrast = contrastRatio(Theme.inputSelectedInk, Theme.inputSelection)
        verify(selectionContrast >= 4.5,
               row.tag + "文本选区对比度只有 " + selectionContrast.toFixed(2) + ":1")

        // 高亮行必须能从面板底里认出来，否则「当前选中哪一行」看不出。
        var highlightSeparation = contrastRatio(Theme.inputPopupHighlight, panel)
        verify(highlightSeparation >= 1.2,
               row.tag + "高亮行与面板底几乎相同（" + highlightSeparation.toFixed(2) + "）")

        // 闭合状态下拉框显示的文字走 palette.buttonText，默认深灰，夜间同样发暗。
        var closedInk = contrastRatio(Theme.inputControlInk, Theme.inputControlSurface)
        verify(closedInk >= 4.5,
               row.tag + "闭合下拉框文字对比度只有 " + closedInk.toFixed(2) + ":1")
        // 展开时 Basic 把下拉框自身的底换成 palette.mid（同一个值还兼任面板边框），
        // 也就是说边框色调深了会顺带让展开态的文字发暗，这里一并守住。
        var expandedInk = contrastRatio(Theme.inputControlInk, Theme.inputPopupBorder)
        verify(expandedInk >= 4.5,
               row.tag + "展开态下拉框文字对比度只有 " + expandedInk.toFixed(2) + ":1")

        // 面板必须和它压着的对话框面板分得开，否则下拉展开时看不出边界。
        var panelSeparation = contrastRatio(panel, Theme.glassDialog)
        verify(panelSeparation >= 1.05,
               row.tag + "下拉面板与对话框底色几乎相同（" + panelSeparation.toFixed(3) + "）")

        combo.popup.close()
        dialog.close()
    }

    function test_duration_fields_stay_readable_in_the_dark_theme() {
        Theme.activeThemeId = "starry"
        var dialog = createTemporaryObject(addComponent, testCase)
        verify(dialog)
        dialog.open()
        wait(50)

        // 预计用时的两个框自己写死了 Theme.inkStrong，不依赖 palette；
        // 这条断言保证它们在夜间主题下同样达标，别因为「有显式色」就免检。
        var hour = findChild(dialog, "addEstimateHourField")
        verify(hour)
        var contrast = contrastRatio(hour.color, Theme.surfaceSunken)
        verify(contrast >= 4.5, "预计用时输入框对比度只有 " + contrast.toFixed(2) + ":1")

        dialog.close()
    }
}
