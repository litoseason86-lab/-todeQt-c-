pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../.."

FocusScope {
    id: root

    objectName: "settingsAppearancePage"
    property var appSettingsRef: null
    property bool compact: false

    // 侧栏顺序的呈现名。这张表只回答「这个 id 叫什么」；顺序本身来自设置，
    // 出厂顺序的唯一定义处在 AppSettings::defaultSidebarOrder()。
    readonly property var sidebarEntryNames: ({
        "dashboard": "仪表盘",
        "today": "今日任务",
        "todayFocus": "今日专注",
        "focus": "专注计时",
        "schedule": "课表",
        "week": "本周计划",
        "month": "专注历史",
        "stats": "数据统计",
        "countdown": "目标倒计时",
        "goals": "目标",
        "knowledgeGaps": "知识缺口"
    })

    // 替身或旧配置可能给出本页没有名字的 id；直接显示 id 也好过整行空白，
    // 至少能看出是哪一条出了问题。
    // 只判 ref 非空不够：替身和旧版本设置对象都可能缺字段，
    // 直接把 undefined 赋给 bool 属性会留下运行时告警，绑定停在上一次的值。
    // 业务规则要求组件扛得住「ref 存在但缺字段」，这里统一归一化。
    function boolSetting(name, fallback) {
        if (!root.appSettingsRef || root.appSettingsRef[name] === undefined) {
            return fallback
        }
        return Boolean(root.appSettingsRef[name])
    }

    function entryLabel(id) {
        var name = root.sidebarEntryNames[id]
        return name === undefined ? String(id) : name
    }

    readonly property var sidebarOrder: root.appSettingsRef && root.appSettingsRef.sidebarOrder
                                        ? root.appSettingsRef.sidebarOrder : []

    // 由服务层判定，QML 不再抄一份默认顺序。替身缺这个属性时按「非默认」处理：
    // 让「恢复默认」点得动、由服务层兜底，比给一个永远灰着又说不清为什么的按钮好。
    readonly property bool orderIsDefault: Boolean(root.appSettingsRef
                                                   && root.appSettingsRef.sidebarOrderIsDefault)

    // 整份新顺序一次性提交，不做「和相邻项交换」那种就地改写：
    // sidebarOrder 是从设置读出来的副本，改它不会回写，只会让界面和存储悄悄分家。
    function moveEntry(from, to) {
        var order = root.sidebarOrder.slice()
        if (from < 0 || from >= order.length || to < 0 || to >= order.length || from === to) {
            return
        }
        var moved = order.splice(from, 1)[0]
        order.splice(to, 0, moved)
        if (root.appSettingsRef) {
            root.appSettingsRef.sidebarOrder = order
        }
    }

    implicitHeight: contentColumn.implicitHeight

    ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space24

        SettingsSection {
            title: "背景主题"
            description: "选择背景时会立即预览并保存。深色主题会同步提高文字与控件对比度。"
            card: false

            GridLayout {
                Layout.fillWidth: true
                columns: root.compact ? 2 : 3
                columnSpacing: Theme.space8
                rowSpacing: Theme.space8

                Repeater {
                    id: themeRepeater

                    objectName: "settingsThemeRepeater"
                    model: Theme.themes

                    delegate: SettingsThemeChoice {
                        required property var modelData

                        Layout.fillWidth: true
                        appSettingsRef: root.appSettingsRef
                        themeId: modelData.id
                        themeName: modelData.name
                    }
                }
            }
        }

        SettingsSection {
            title: "显示"

            SettingsRow {
                label: "减少动效"
                caption: "关闭弹窗、开关与页面切换中的非必要动画"
                iconName: "spark"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsReduceMotionSwitch"
                    text: "减少动效"
                    persistedChecked: root.boolSetting("reduceMotion", false)
                    reduceMotion: persistedChecked
                    onChangeRequested: enabled => {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.reduceMotion = enabled
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            SettingsRow {
                label: "纤细计时字体"
                caption: "专注页使用更轻的数字字重"
                iconText: "Aa"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsSlimClockFontSwitch"
                    text: "纤细计时字体"
                    persistedChecked: root.boolSetting("slimClockFont", true)
                    reduceMotion: root.boolSetting("reduceMotion", false)
                    onChangeRequested: enabled => {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.slimClockFont = enabled
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            SettingsRow {
                label: "减少透明度"
                caption: "关闭毛玻璃，改用不透明面板，更清晰也更省电"
                iconName: "layers"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsReduceTransparencySwitch"
                    text: "减少透明度"
                    persistedChecked: root.boolSetting("reduceTransparency", false)
                    reduceMotion: root.boolSetting("reduceMotion", false)
                    onChangeRequested: enabled => {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.reduceTransparency = enabled
                        }
                    }
                }
            }
        }

        SettingsSection {
            title: "侧栏顺序"
            description: "调整左侧入口的排列。「设置」固定在底部，不参与排序。"
            card: false

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.space4

                Repeater {
                    objectName: "settingsSidebarOrderRepeater"
                    model: root.sidebarOrder

                    Rectangle {
                        id: orderRow
                        required property string modelData
                        required property int index

                        objectName: "settingsSidebarOrderRow-" + orderRow.modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: Theme.controlHeightLg
                        radius: Theme.radiusMd
                        color: Theme.surfaceRaised
                        border.color: Theme.border
                        border.width: 1

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.space12
                            anchors.rightMargin: Theme.space8
                            spacing: Theme.space8

                            Text {
                                Layout.fillWidth: true
                                text: root.entryLabel(orderRow.modelData)
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontMd
                                color: Theme.ink
                                elide: Text.ElideRight
                            }

                            // 上下移动而不是拖拽：这份列表只有十来项，拖拽要额外处理
                            // 按住、越界、松手回弹一整套状态，而且键盘用户完全用不了。
                            MoveButton {
                                objectName: "settingsSidebarMoveUp-" + orderRow.modelData
                                text: "↑"
                                accessibleName: "上移 " + root.entryLabel(orderRow.modelData)
                                enabled: orderRow.index > 0
                                onClicked: root.moveEntry(orderRow.index, orderRow.index - 1)
                            }

                            MoveButton {
                                objectName: "settingsSidebarMoveDown-" + orderRow.modelData
                                text: "↓"
                                accessibleName: "下移 " + root.entryLabel(orderRow.modelData)
                                enabled: orderRow.index < root.sidebarOrder.length - 1
                                onClicked: root.moveEntry(orderRow.index, orderRow.index + 1)
                            }
                        }
                    }
                }

                Button {
                    id: resetOrderButton
                    objectName: "settingsSidebarOrderResetButton"

                    Layout.topMargin: Theme.space8
                    Layout.alignment: Qt.AlignRight
                    implicitHeight: Theme.controlHeightMd
                    implicitWidth: 124
                    text: "恢复默认顺序"
                    enabled: !root.orderIsDefault
                    onClicked: {
                        if (root.appSettingsRef
                                && typeof root.appSettingsRef.resetSidebarOrder === "function") {
                            root.appSettingsRef.resetSidebarOrder()
                        }
                    }

                    background: Rectangle {
                        radius: Theme.radiusMd
                        color: resetOrderButton.down ? Theme.surfaceSunken
                                                     : (resetOrderButton.hovered ? Theme.glassHover
                                                                                 : Theme.controlSurface)
                        border.color: Theme.border
                        border.width: 1
                        opacity: resetOrderButton.enabled ? 1 : 0.5
                    }

                    contentItem: Text {
                        text: resetOrderButton.text
                        textFormat: Text.PlainText
                        color: Theme.controlInk
                        font.pixelSize: Theme.fontMd
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }

    component MoveButton: Button {
        id: moveButton

        property string accessibleName: ""

        implicitWidth: 32
        implicitHeight: Theme.controlHeightSm
        Accessible.role: Accessible.Button
        Accessible.name: moveButton.accessibleName
        Accessible.onPressAction: moveButton.clicked()

        background: Rectangle {
            radius: Theme.radiusSm
            color: moveButton.down ? Theme.surfaceSunken
                                   : (moveButton.hovered ? Theme.glassHover : Theme.controlSurface)
            border.color: Theme.border
            border.width: 1
            opacity: moveButton.enabled ? 1 : 0.4
        }

        contentItem: Text {
            text: moveButton.text
            textFormat: Text.PlainText
            color: Theme.controlInk
            font.pixelSize: Theme.fontMd
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }
}
