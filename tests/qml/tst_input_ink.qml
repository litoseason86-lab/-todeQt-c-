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
