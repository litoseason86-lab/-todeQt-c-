// 画廊 delegate 引用外层 root，按项目惯例显式绑定组件作用域（EditTaskDialog 先例）。
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import ".."

// 设置弹窗：把低频偏好和管理入口集中收纳，侧栏只保留高频导航。
// 主题即点即切即持久化（写 appSettingsRef.backgroundTheme），不设确认按钮。
Popup {
    id: root

    property var appSettingsRef: null
    signal routineRequested
    signal categoryRequested
    signal exportRequested

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: parent ? Math.min(560, Math.max(420, parent.width - 96)) : 560
    height: Math.min(contentColumn.implicitHeight,
                     parent ? parent.height - Theme.space32 * 2 : contentColumn.implicitHeight)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    function selectTheme(themeId) {
        // 缺 appSettings（测试/降级）时画廊只展示不写入，与全应用守卫模式一致。
        if (root.appSettingsRef) {
            root.appSettingsRef.backgroundTheme = themeId
        }
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 0.94
                to: 1.0
                duration: 220
                easing.type: Easing.OutCubic
            }

            OpacityAnimator {
                from: 0
                to: 1
                duration: 220
                easing.type: Easing.OutQuad
            }
        }
    }

    exit: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 1.0
                to: 0.94
                duration: 220
                easing.type: Easing.InQuad
            }

            OpacityAnimator {
                from: 1
                to: 0
                duration: 220
                easing.type: Easing.InQuad
            }
        }
    }

    Overlay.modal: Rectangle {
        objectName: "settingsOverlay"
        // 比默认 40% 再深一档：设置内容多，遮罩加深让背景后退、弹窗聚焦、玻璃后不再透出杂字。
        color: "#8c000000"
        opacity: root.opened ? 1 : 0

        Behavior on opacity {
            OpacityAnimator {
                duration: 180
                easing.type: Easing.InOutQuad
            }
        }
    }

    background: Rectangle {
        id: panel
        objectName: "settingsDialogPanel"

        implicitWidth: root.width
        implicitHeight: contentColumn.implicitHeight
        color: Theme.glassDialog
        border.color: Theme.glassBorder
        border.width: 1
        radius: Theme.radiusLg
        layer.enabled: true
        layer.effect: MultiEffect {
            autoPaddingEnabled: true
            shadowEnabled: true
            shadowColor: Theme.shadow
            shadowOpacity: 0.12
            shadowBlur: 0.20
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 4
        }
    }

    contentItem: ScrollView {
        id: settingsScroll

        topPadding: Theme.space8
        bottomPadding: Theme.space8
        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        // 主题化竖向滚动条：弹窗小窗体下只滚内容，不把整窗撑出屏幕。
        ScrollBar.vertical: ScrollBar {
            id: settingsScrollBar
            policy: ScrollBar.AsNeeded
            width: 8

            contentItem: Rectangle {
                implicitWidth: 4
                radius: Theme.radiusSm
                color: settingsScrollBar.pressed || settingsScrollBar.hovered ? Theme.accent : Theme.border
            }

            background: Rectangle {
                color: "transparent"
            }
        }

        ColumnLayout {
            id: contentColumn

            width: settingsScroll.availableWidth
            spacing: Theme.space8

            Text {
                Layout.leftMargin: Theme.space24
                Layout.topMargin: Theme.space16
                text: "设置"
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontXl
                font.weight: Font.Bold
            }

            Text {
                Layout.leftMargin: Theme.space24
                Layout.topMargin: Theme.space8
                text: "背景主题"
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                font.weight: Font.Bold
            }

            GridLayout {
                Layout.leftMargin: Theme.space24
                Layout.rightMargin: Theme.space24
                Layout.alignment: Qt.AlignHCenter
                columns: 3
                rowSpacing: Theme.space12
                columnSpacing: Theme.space16

                Repeater {
                    id: themeRepeater
                    objectName: "settingsThemeRepeater"

                    model: Theme.backgroundThemes

                    delegate: Column {
                        id: themeCell

                        required property var modelData

                        objectName: "settingsThemeCell-" + themeCell.modelData.id
                        // 选中态直接绑设置属性（函数调用不具备响应性，这里必须是属性链）。
                        readonly property bool selected: root.appSettingsRef
                            ? root.appSettingsRef.backgroundTheme === themeCell.modelData.id
                            : themeCell.modelData.id === "warmPaper"

                        Layout.preferredWidth: 160
                        spacing: Theme.space4

                        Rectangle {
                            id: thumbFrame
                            objectName: "settingsThemeThumb-" + themeCell.modelData.id

                            width: 160
                            height: 72
                            radius: Theme.radiusMd
                            clip: true
                            color: themeCell.selected ? Theme.accentSoft : Qt.rgba(1, 1, 1, 0)
                            border.color: themeCell.selected ? Theme.accent : Theme.border
                            border.width: themeCell.selected ? 2 : 1

                            BackgroundWallpaper {
                                // 缩略图与壁纸层同组件同定义：画廊所见即所得。
                                anchors.fill: parent
                                anchors.margins: 3
                                themeId: themeCell.modelData.id
                            }

                            Rectangle {
                                // 迷你磨砂条：让用户换主题前预感玻璃面板的观感。
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.leftMargin: 10
                                anchors.rightMargin: 10
                                anchors.bottomMargin: 8
                                height: 16
                                radius: Theme.radiusSm
                                color: Theme.glassCard
                                border.color: Theme.glassBorder
                                border.width: 1
                            }

                            Rectangle {
                                anchors.top: parent.top
                                anchors.right: parent.right
                                anchors.margins: 4
                                width: 16
                                height: 16
                                radius: 8
                                color: Theme.accent
                                visible: themeCell.selected

                                Text {
                                    anchors.centerIn: parent
                                    text: "✓"
                                    textFormat: Text.PlainText
                                    color: Theme.surface
                                    font.pixelSize: 10
                                    font.weight: Font.Bold
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.selectTheme(themeCell.modelData.id)
                            }
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: themeCell.modelData.name
                            textFormat: Text.PlainText
                            color: themeCell.selected ? Theme.ink : Theme.inkSoft
                            font.pixelSize: Theme.fontSm
                        }
                    }
                }
            }

            Text {
                Layout.leftMargin: Theme.space24
                Layout.topMargin: Theme.space12
                text: "偏好"
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                font.weight: Font.Bold
            }

            SectionGroup {
                objectName: "settingsPreferenceGroup"

                PreferenceSwitchRow {
                    label: "提示音"
                    caption: "阶段完成时播放"
                    switchName: "settingsSoundSwitch"
                    checkedValue: root.appSettingsRef ? root.appSettingsRef.soundEnabled : true
                    onToggledTo: function (value) {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.soundEnabled = value
                        }
                    }
                }

                RowDivider {
                    objectName: "settingsPreferenceDivider"
                }

                PreferenceSwitchRow {
                    label: "减少动效"
                    caption: "关闭循环与切换动画"
                    switchName: "settingsReduceMotionSwitch"
                    checkedValue: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
                    onToggledTo: function (value) {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.reduceMotion = value
                        }
                    }
                }

                RowDivider {
                    objectName: "settingsPreferenceDividerSlimClock"
                }

                PreferenceSwitchRow {
                    label: "纤细计时字体"
                    caption: "更秀气的表盘数字；关闭则用更清晰的中黑"
                    switchName: "settingsSlimClockFontSwitch"
                    checkedValue: root.appSettingsRef ? root.appSettingsRef.slimClockFont : true
                    onToggledTo: function (value) {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.slimClockFont = value
                        }
                    }
                }

                RowDivider {
                    objectName: "settingsPreferenceDividerDayStart"
                }

                Rectangle {
                    objectName: "settingsDayStartRow"
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.space12
                    Layout.rightMargin: Theme.space12
                    implicitHeight: 64
                    color: "transparent"

                    Column {
                        anchors.left: parent.left
                        anchors.right: dayStartStepper.left
                        anchors.leftMargin: Theme.space12
                        anchors.rightMargin: Theme.space12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        Text {
                            text: "每日起始时间"
                            textFormat: Text.PlainText
                            color: Theme.ink
                            font.pixelSize: Theme.fontMd
                        }

                        Text {
                            text: "凌晨此点前算前一天（4 = 凌晨4点）"
                            textFormat: Text.PlainText
                            color: Theme.inkMuted
                            font.pixelSize: Theme.fontSm
                        }
                    }

                    DurationStepper {
                        id: dayStartStepper

                        anchors.right: parent.right
                        anchors.rightMargin: Theme.space12
                        anchors.verticalCenter: parent.verticalCenter
                        from: 0
                        to: 6
                        value: root.appSettingsRef ? root.appSettingsRef.dayStartHour : 4
                        namePrefix: "settingsDayStart"
                        onAdjusted: function (newValue) {
                            // 测试或降级环境缺少设置对象时只展示默认值，不写入任何外部状态。
                            if (root.appSettingsRef) {
                                root.appSettingsRef.dayStartHour = newValue
                            }
                        }
                    }
                }
            }

            Text {
                Layout.leftMargin: Theme.space24
                Layout.topMargin: Theme.space12
                text: "管理"
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                font.weight: Font.Bold
            }

            SectionGroup {
                objectName: "settingsManageGroup"

                ManageEntryRow {
                    label: "每日例行"
                    rowName: "settingsManageRoutine"
                    onActivated: {
                        root.close()
                        root.routineRequested()
                    }
                }

                RowDivider {
                    objectName: "settingsManageDividerRoutineCategory"
                }

                ManageEntryRow {
                    label: "科目管理"
                    rowName: "settingsManageCategory"
                    onActivated: {
                        root.close()
                        root.categoryRequested()
                    }
                }

                RowDivider {
                    objectName: "settingsManageDividerCategoryExport"
                }

                ManageEntryRow {
                    label: "数据导出"
                    rowName: "settingsManageExport"
                    onActivated: {
                        root.close()
                        root.exportRequested()
                    }
                }
            }

            Button {
                id: closeButton
                objectName: "settingsCloseButton"

                Layout.alignment: Qt.AlignRight
                Layout.rightMargin: Theme.space24
                Layout.topMargin: Theme.space8
                Layout.bottomMargin: Theme.space24
                text: "关闭"
                implicitWidth: 96
                implicitHeight: 40

                onClicked: root.close()

                background: Rectangle {
                    color: closeButton.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
                    border.color: Theme.border
                    border.width: 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: closeButton.text
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    // 分段组卡：偏好/管理各自的行收进一张不透明浅色卡，内容不再直接坐在半透玻璃上，
    // 天生清晰；圆角 + clip 让内部行的 hover 高亮贴合卡角。
    component SectionGroup: Rectangle {
        default property alias content: groupColumn.data

        Layout.fillWidth: true
        Layout.leftMargin: Theme.space24
        Layout.rightMargin: Theme.space24
        implicitHeight: groupColumn.implicitHeight
        color: Theme.surfaceRaised
        border.color: Theme.borderSubtle
        border.width: 1
        radius: Theme.radiusMd
        clip: true

        ColumnLayout {
            id: groupColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: 0
        }
    }

    // 组卡内行间分隔线：细、缩进，替代大留白做分隔。
    component RowDivider: Rectangle {
        Layout.fillWidth: true
        Layout.leftMargin: Theme.space12
        Layout.rightMargin: Theme.space12
        Layout.preferredHeight: 1
        color: Theme.borderSubtle
    }

    // 偏好开关行：左标签 + 副说明，右暖纸自绘 Switch；行内边距由组卡负责整体缩进。
    component PreferenceSwitchRow: Rectangle {
        id: prefRow

        property string label: ""
        property string caption: ""
        property string switchName: ""
        property bool checkedValue: false
        signal toggledTo(bool value)

        objectName: prefRow.switchName + "Row"
        Layout.fillWidth: true
        Layout.leftMargin: Theme.space12
        Layout.rightMargin: Theme.space12
        implicitHeight: 64
        color: preferenceHover.hovered ? Theme.surfaceSunken : "transparent"

        function togglePreference() {
            prefRow.toggledTo(!prefRow.checkedValue)
        }

        Column {
            anchors.left: parent.left
            anchors.right: prefSwitch.left
            anchors.leftMargin: Theme.space12
            anchors.rightMargin: Theme.space12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                text: prefRow.label
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontMd
            }

            Text {
                objectName: prefRow.switchName + "Caption"
                visible: prefRow.caption.length > 0
                text: prefRow.caption
                textFormat: Text.PlainText
                color: Theme.inkMuted
                font.pixelSize: Theme.fontXs
            }
        }

        Switch {
            id: prefSwitch
            objectName: prefRow.switchName

            anchors.right: parent.right
            anchors.rightMargin: Theme.space12
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: 40
            implicitHeight: 22
            checked: prefRow.checkedValue
            onToggled: prefRow.toggledTo(checked)

            indicator: Rectangle {
                objectName: prefRow.switchName + "Track"
                implicitWidth: 40
                implicitHeight: 22
                radius: 11
                color: prefSwitch.checked ? Theme.accent : Theme.surfaceSunken
                border.color: Theme.border
                border.width: 1

                Rectangle {
                    objectName: prefRow.switchName + "Thumb"
                    x: prefSwitch.checked ? parent.width - width - 2 : 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 18
                    height: 18
                    radius: 9
                    color: Theme.surface

                    Behavior on x {
                        NumberAnimation {
                            duration: 120
                            easing.type: Easing.OutQuad
                        }
                    }
                }
            }

            contentItem: Item {}
        }

        HoverHandler {
            id: preferenceHover
        }

        TapHandler {
            // 偏好项应按整行理解：用户点标签、副说明或开关区域都切换同一个设置。
            // 这里不依赖 Switch 自身很小的命中范围，避免桌面鼠标点击文字时“看似点了但无效”。
            onTapped: prefRow.togglePreference()
        }
    }

    // 管理入口行：整行可点，右侧箭头只表达“进入下一层”，弹窗本身负责发信号。
    // 缩进由外层组卡负责；本行只做整行 hover 高亮（被组卡 clip 贴合圆角）。
    component ManageEntryRow: Rectangle {
        id: manageRow

        property string label: ""
        property string rowName: ""
        signal activated

        objectName: manageRow.rowName
        Layout.fillWidth: true
        implicitHeight: 40
        color: manageHover.hovered ? Theme.surfaceSunken : "transparent"

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.space12
            anchors.rightMargin: Theme.space12

            Text {
                Layout.fillWidth: true
                text: manageRow.label
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontMd
            }

            Text {
                text: "›"
                textFormat: Text.PlainText
                color: Theme.inkMuted
                font.pixelSize: Theme.fontLg
            }
        }

        HoverHandler {
            id: manageHover
        }

        TapHandler {
            onTapped: manageRow.activated()
        }
    }
}
