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

        implicitWidth: Math.max(52, contentLabel.implicitWidth + Theme.space16)
        implicitHeight: 26

        background: Rectangle {
            radius: Theme.radiusSm
            color: textButton.hovered ? Theme.glassHover : Qt.rgba(0, 0, 0, 0)
            border.color: textButton.danger ? Theme.dangerBorder : Theme.border
            border.width: 1
        }

        contentItem: Text {
            id: contentLabel
            text: textButton.text
            textFormat: Text.PlainText
            color: textButton.danger ? Theme.danger : Theme.ink
            font.pixelSize: Theme.fontXs
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
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

            Text {
                objectName: "focusTimelineTitle"
                Layout.fillWidth: true
                text: root.currentMonth + "月" + root.selectedDay + "日 专注记录"
                font.pixelSize: Theme.fontXl
                font.weight: Font.Bold
                color: Theme.ink
            }

            Text {
                text: root.sessions.length + "次记录"
                font.pixelSize: Theme.fontMd
                color: Theme.inkSoft
            }

            TimelineTextButton {
                objectName: "focusSessionAddButton"
                visible: root.editable
                text: qsTr("补录")
                implicitHeight: 30
                onClicked: root.addRequested()
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.sessions.length === 0

            Text {
                objectName: "focusHistoryEmptyState"
                anchors.centerIn: parent
                text: "这一天还没有专注记录"
                font.pixelSize: Theme.fontMd
                color: Theme.inkSoft
                horizontalAlignment: Text.AlignHCenter
            }
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

                        width: timelineColumn.width
                        height: sessionCard.height + (sessionRow.index < root.sessions.length - 1 ? 14 : 0)

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
                            color: Theme.accent
                            border.color: Theme.surface
                            border.width: 2
                            z: 2
                        }

                        Rectangle {
                            id: sessionCard
                            objectName: "focusSessionCard-" + sessionRow.index
                            x: 24
                            width: Math.max(1, parent.width - x)
                            height: root.editable ? 112 : 86
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
                                        font.pixelSize: Theme.fontLg
                                        font.weight: Font.Medium
                                        color: Theme.inkStrong
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: MgFmt.formatClock(sessionRow.modelData.startTime) + " - " + MgFmt.formatClock(sessionRow.modelData.endTime)
                                        font.pixelSize: Theme.fontSm
                                        color: Theme.inkSoft
                                        elide: Text.ElideRight
                                    }

                                    RowLayout {
                                        spacing: Theme.space8
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

                                ColumnLayout {
                                    Layout.preferredWidth: 116
                                    Layout.maximumWidth: 140
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: Theme.space4

                                    Text {
                                        Layout.fillWidth: true
                                        text: root.formatDurationFn(Number(sessionRow.modelData.durationSeconds) || 0)
                                        font.pixelSize: Theme.fontXl
                                        font.weight: Font.Bold
                                        color: Theme.accent
                                        horizontalAlignment: Text.AlignRight
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: "已完成"
                                        font.pixelSize: Theme.fontXs
                                        font.weight: Font.Medium
                                        color: Theme.success
                                        horizontalAlignment: Text.AlignRight
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
