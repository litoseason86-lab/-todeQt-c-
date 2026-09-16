pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import ".."
import "../views/MonthGoalFormat.js" as MgFmt

Rectangle {
    id: root

    property var sessions: []
    // 手工补录/修改/删除的入口。宿主不接这些信号时按钮不出现——
    // 组件本身不该假定所有使用者都允许改历史。
    property bool editable: false
    // 宿主页面自己有标题栏时（今日专注页），卡片内的表头就是重复信息，让宿主关掉它。
    property bool headerVisible: true
    signal addRequested()
    signal editRequested(var session)
    signal deleteRequested(var session)
    property int selectedDay: 0
    property int currentMonth: 0
    property int viewWidth: 0
    property var formatDurationFn: (function (s) { return "" })

    objectName: "focusTimelinePanel"

    // 卡片上的小操作：纯文字 + 细描边，不喧宾夺主。
    component TimelineTextButton: Button {
        id: textButton
        property bool danger: false

        // 常态不画描边：一天的记录堆起来就是十几个小方框，比记录本身还抢眼。
        // 破坏性操作也只在指针真正指向它时才转红——平时它不该是页面上最红的东西。
        readonly property bool engaged: textButton.hovered || textButton.down
        readonly property color tint: textButton.danger && textButton.engaged
                                      ? Theme.danger
                                      : (textButton.engaged ? Theme.ink : Theme.inkSoft)

        implicitWidth: Math.max(52, contentLabel.implicitWidth + Theme.space16)
        implicitHeight: Theme.controlHeightSm
        focusPolicy: Qt.StrongFocus
        hoverEnabled: true

        background: Rectangle {
            radius: Theme.radiusSm
            // 起点用同色零透明：黑基 transparent 会让悬停动画插值出一道灰影。
            color: textButton.down ? Theme.surfaceSunken
                                   : (textButton.hovered ? Theme.glassHover : Theme.glassHoverIdle)
            // 按钮要有可见边界，否则一行文字看不出是可点的。
            border.width: textButton.visualFocus ? 2 : 1
            border.color: textButton.visualFocus
                          ? Theme.focusRing
                          : (textButton.danger && textButton.engaged ? Theme.dangerBorder : Theme.border)

            Behavior on color {
                ColorAnimation { duration: Theme.reduceMotion ? 0 : 120 }
            }
        }

        contentItem: Text {
            id: contentLabel
            text: textButton.text
            textFormat: Text.PlainText
            color: textButton.tint
            font.pixelSize: Theme.fontXs
            font.weight: textButton.engaged ? Font.Medium : Font.Normal
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter

            Behavior on color {
                ColorAnimation { duration: Theme.reduceMotion ? 0 : 120 }
            }
        }
    }
    radius: Theme.radiusLg
    color: Theme.glassCard
    border.color: Theme.glassBorder
    border.width: 1
    layer.enabled: true
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: Theme.shadow
        shadowOpacity: 0.08
        shadowBlur: 0.14
        shadowHorizontalOffset: 0
        shadowVerticalOffset: 2
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space16
        spacing: Theme.space12

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space12
            visible: root.headerVisible

            Text {
                objectName: "focusTimelineTitle"
                Layout.fillWidth: true
                text: root.currentMonth + "月" + root.selectedDay + "日 专注记录"
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontLg
                font.weight: Font.Bold
                color: Theme.ink
            }

            Text {
                text: root.sessions.length + "次记录"
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontMd
                color: Theme.inkSoft
            }

            TimelineTextButton {
                objectName: "focusSessionAddButton"
                visible: root.editable
                text: qsTr("补录")
                implicitHeight: Theme.controlHeightSm
                onClicked: root.addRequested()
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.sessions.length === 0
        }

        ScrollView {
            id: timelineScrollView
            objectName: "focusTimelineScrollView"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.sessions.length > 0
            clip: true
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical: ScrollBar {
                id: timelineVerticalScrollBar
                policy: ScrollBar.AsNeeded
                width: 8

                contentItem: Rectangle {
                    implicitWidth: 4
                    radius: Theme.radiusSm
                    color: timelineVerticalScrollBar.pressed || timelineVerticalScrollBar.hovered ? Theme.accent : Theme.border
                }

                background: Rectangle {
                    objectName: "monthTimelineScrollTrack"

                    color: "transparent"
                }
            }

            Column {
                id: timelineColumn
                width: Math.max(1, timelineScrollView.availableWidth)
                spacing: Theme.space12

                Repeater {
                    model: root.sessions

                    delegate: Item {
                        id: sessionRow

                        // delegate 显式声明消费的模型角色（pragma ComponentBehavior: Bound）。
                        required property var modelData
                        required property int index
                        readonly property bool isRest: Boolean(sessionRow.modelData.isRest)

                        width: timelineColumn.width
                        height: sessionCard.height

                        Rectangle {
                            visible: sessionRow.index < root.sessions.length - 1
                            x: 7
                            y: 28
                            width: 2
                            height: Math.max(0, parent.height - y)
                            radius: Theme.radiusSm
                            color: Theme.border
                        }

                        Rectangle {
                            width: 10
                            height: 10
                            x: 3
                            y: 18
                            radius: 5
                            color: sessionRow.isRest ? Theme.inkSoft : Theme.accent
                            border.color: Theme.surface
                            border.width: 2
                            z: 2
                        }

                        Rectangle {
                            id: sessionCard
                            objectName: "focusSessionCard-" + sessionRow.index
                            x: 24
                            width: Math.max(1, parent.width - x)
                            height: 76
                            radius: Theme.radiusMd
                            color: Theme.surfaceRaised
                            border.color: Theme.border
                            border.width: 1

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: Theme.space12
                                spacing: Theme.space12

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: Theme.space4

                                    Text {
                                        Layout.fillWidth: true
                                        text: sessionRow.modelData.taskTitle && String(sessionRow.modelData.taskTitle).length > 0 ? sessionRow.modelData.taskTitle : "未知任务"
                                        textFormat: Text.PlainText
                                        font.pixelSize: Theme.fontLg
                                        font.weight: Font.Medium
                                        color: Theme.inkStrong
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: MgFmt.formatClock(sessionRow.modelData.startTime) + " - " + MgFmt.formatClock(sessionRow.modelData.endTime)
                                        textFormat: Text.PlainText
                                        font.pixelSize: Theme.fontSm
                                        color: Theme.inkSoft
                                        elide: Text.ElideRight
                                    }
                                }

                                // 三列固定次序：内容 → 时长 → 操作。
                                // 操作列夹在内容和时长之间时没有列宽约束，会浮在行中间；
                                // 放到最右并给定宽度，各行的按钮、数字才会各自对齐成一列。
                                ColumnLayout {
                                    Layout.preferredWidth: 116
                                    Layout.maximumWidth: 140
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: Theme.space4

                                    Text {
                                        Layout.fillWidth: true
                                        // formatDurationFn 由视图在运行时注入，静态工具只能看到 var 属性。
                                        // qmllint disable use-proper-function
                                        text: sessionRow.isRest && Number(sessionRow.modelData.durationSeconds) < 60
                                              ? qsTr("%1秒").arg(Number(sessionRow.modelData.durationSeconds) || 0)
                                              : root.formatDurationFn(Number(sessionRow.modelData.durationSeconds) || 0)
                                        // qmllint enable use-proper-function
                                        textFormat: Text.PlainText
                                        font.pixelSize: Theme.fontLg
                                        font.weight: Font.Bold
                                        // accent 是填充/描边用的品牌色，压在浅底上只有 2.07:1。
                                        // 时长读数是这一行最该看清的数字，用可读文字版。
                                        color: sessionRow.isRest ? Theme.inkSoft : Theme.accentInk
                                        horizontalAlignment: Text.AlignRight
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: sessionRow.isRest ? qsTr("不计入专注") : qsTr("已完成")
                                        textFormat: Text.PlainText
                                        font.pixelSize: Theme.fontXs
                                        font.weight: Font.Medium
                                        // 同理：success 是状态色，作文字用 successInk。
                                        color: sessionRow.isRest ? Theme.inkSoft : Theme.successInk
                                        horizontalAlignment: Text.AlignRight
                                    }
                                }

                                RowLayout {
                                    // 固定列宽，让每一行的两个按钮上下对齐。
                                    Layout.preferredWidth: 112
                                    // 与时长之间留出一档间距，数字和按钮才不会读成一坨。
                                    Layout.leftMargin: Theme.space8
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: Theme.space8
                                    // 模型携带记录类型，宿主按类型分发到对应服务接口。
                                    visible: root.editable

                                    TimelineTextButton {
                                        objectName: "focusSessionEdit-" + sessionRow.index
                                        text: qsTr("修改")
                                        onClicked: root.editRequested(sessionRow.modelData)
                                    }

                                    TimelineTextButton {
                                        objectName: "focusSessionDelete-" + sessionRow.index
                                        text: qsTr("删除")
                                        danger: true
                                        onClicked: root.deleteRequested(sessionRow.modelData)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
