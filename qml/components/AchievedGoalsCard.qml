pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 长期层只负责“回味”：安静列出完成事实，不在统计页再叠加即时庆祝或进度动画。
Control {
    id: root

    property var achievedGoals: []
    property string errorText: ""
    property var levelInfo: ({ lv: 1, name: qsTr("起步") })
    property bool expanded: false
    readonly property int maximumCollapsedRows: 5
    readonly property bool hasMore: root.achievedGoals.length > root.maximumCollapsedRows
    readonly property var displayedGoals: root.expanded || !root.hasMore
                                                 ? root.achievedGoals
                                                 : root.achievedGoals.slice(0, root.maximumCollapsedRows)
    readonly property int displayedCount: root.displayedGoals.length
    readonly property string levelText: qsTr("LV.%1 %2")
                                        .arg(Number(root.levelInfo.lv || 1))
                                        .arg(String(root.levelInfo.name || qsTr("起步")))
    readonly property string emptyText: qsTr("完成第一个长期目标后，这里会留下记录")

    signal goalClicked(int goalId)

    function toggleExpanded() {
        if (root.hasMore)
            root.expanded = !root.expanded
    }

    onAchievedGoalsChanged: {
        if (!root.hasMore)
            root.expanded = false
    }

    implicitWidth: 560
    implicitHeight: contentColumn.implicitHeight + Theme.space32

    background: Rectangle {
        color: Theme.glassCard
        border.color: Theme.glassBorder
        border.width: 1
        radius: Theme.radiusLg
    }

    contentItem: ColumnLayout {
        id: contentColumn

        spacing: Theme.space8

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space12

            Text {
                Layout.fillWidth: true
                text: qsTr("已达成目标")
                color: Theme.inkStrong
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
            }

            Rectangle {
                Layout.preferredWidth: levelLabel.implicitWidth + Theme.space16
                Layout.preferredHeight: 28
                radius: height / 2
                color: Theme.accentFill

                Text {
                    id: levelLabel
                    objectName: "achievedGoalsLevelText"
                    anchors.centerIn: parent
                    text: root.levelText
                    color: Theme.accentFillInk
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.DemiBold
                }
            }
        }

        Text {
            objectName: "achievedGoalsEmptyText"
            Layout.fillWidth: true
            Layout.preferredHeight: root.errorText.length > 0 || root.achievedGoals.length === 0
                                    ? implicitHeight : 0
            text: root.errorText.length > 0 ? root.errorText
                                             : (root.achievedGoals.length === 0 ? root.emptyText : "")
            color: root.errorText.length > 0 ? Theme.danger : Theme.inkSoft
            font.pixelSize: Theme.fontMd
            wrapMode: Text.WordWrap
        }

        Repeater {
            model: root.displayedGoals

            AbstractButton {
                id: row

                required property var modelData
                readonly property int goalId: Number(row.modelData.id || -1)

                objectName: "achievedGoalRow-" + row.goalId
                Layout.fillWidth: true
                implicitHeight: 44
                hoverEnabled: true
                focusPolicy: Qt.StrongFocus
                onClicked: root.goalClicked(row.goalId)
                Accessible.name: String(row.modelData.title || qsTr("未命名目标"))

                background: Rectangle {
                    color: row.down || row.hovered ? Theme.glassHover : "transparent"
                    border.color: row.activeFocus ? Theme.focusRing : "transparent"
                    border.width: row.activeFocus ? 2 : 0
                    radius: Theme.radiusMd
                }

                contentItem: RowLayout {
                    spacing: Theme.space8

                    Rectangle {
                        Layout.preferredWidth: 9
                        Layout.preferredHeight: 9
                        radius: width / 2
                        color: String(row.modelData.categoryColor || "").length > 0
                               ? row.modelData.categoryColor : Theme.accent
                    }

                    Text {
                        Layout.fillWidth: true
                        text: String(row.modelData.title || qsTr("未命名目标"))
                        textFormat: Text.PlainText
                        color: Theme.ink
                        font.pixelSize: Theme.fontMd
                        elide: Text.ElideRight
                    }

                    Text {
                        text: {
                            var value = row.modelData.achievedAt
                            var date = value instanceof Date ? value : new Date(String(value || ""))
                            return isNaN(date.getTime()) ? qsTr("日期未知")
                                                          : Qt.formatDate(date, "M月d日")
                        }
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontSm
                    }
                }
            }
        }

        Button {
            id: expandButton
            objectName: "achievedGoalsExpandButton"
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: root.hasMore ? 40 : 0
            enabled: root.hasMore
            opacity: root.hasMore ? 1 : 0
            text: root.expanded ? qsTr("收起")
                                : qsTr("展开全部 %1 项").arg(root.achievedGoals.length)
            onClicked: root.toggleExpanded()
            background: Rectangle {
                color: expandButton.down || expandButton.hovered
                       ? Theme.glassHover : Theme.glassCard
                border.color: Theme.border
                border.width: 1
                radius: Theme.radiusMd
            }
            contentItem: Text {
                text: expandButton.text
                color: Theme.ink
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
    }
}
