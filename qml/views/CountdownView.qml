import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
import ".."

Item {
    id: root

    property var countdownServiceRef: null

    function primaryGoal() {
        return root.countdownServiceRef ? root.countdownServiceRef.primaryGoal : null;
    }

    function openEditor(goalId, name, targetDate) {
        countdownDialog.openForEdit(goalId, name, targetDate);
    }

    function weekdayText(value) {
        // Qt.formatDate 的星期占位符依赖系统区域设置，C locale 下会输出英文；
        // 手工映射保证任何环境都显示中文「周X」。
        var glyphs = ["日", "一", "二", "三", "四", "五", "六"];
        return "周" + glyphs[new Date(value).getDay()];
    }

    function heroDateText() {
        var goal = root.primaryGoal();
        if (!goal) {
            return "";
        }
        var text = Qt.formatDate(goal.targetDate, "yyyy年MM月dd日") + " · " + root.weekdayText(goal.targetDate);
        // 过期状态并入日期行，天数大字保持「还剩/已过 N 天」同一种排版，不再切换布局。
        if (Number(goal.daysRemaining || 0) < 0) {
            text += " · 已过期";
        }
        return text;
    }

    CountdownDialog {
        id: countdownDialog
        parent: root
        countdownServiceRef: root.countdownServiceRef
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space24
        spacing: Theme.space16

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space12

            ColumnLayout {
                spacing: Theme.space4

                Text {
                    text: "目标倒计时"
                    font.pixelSize: Theme.fontXxl
                    font.weight: Font.Bold
                    color: Theme.ink
                }

                Text {
                    text: "把关键日期放到每天都能看见的位置。"
                    font.pixelSize: Theme.fontMd
                    color: Theme.inkSoft
                }
            }

            // 弹性占位把「添加目标」推到贴齐内容右缘；嵌套列的 fillWidth
            // 会被 Text 的隐式宽度钉住，见统计页头部同款注释。
            Item {
                Layout.fillWidth: true
            }

            Button {
                id: addButton
                text: "添加目标"
                implicitWidth: 108
                implicitHeight: 44

                background: Rectangle {
                    color: addButton.pressed ? Theme.accentFillStrong : (addButton.hovered ? Theme.accentFillStrong : Theme.accentFill)
                    radius: Theme.radiusLg
                }

                contentItem: Text {
                    text: addButton.text
                    color: Theme.accentFillInk
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.Medium
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                onClicked: countdownDialog.openForAdd()
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.border
        }

        // —— 英雄卡：与全应用一致的玻璃面板；悬停用描边转强调色提示可点击 ——
        GlassPanel {
            objectName: "countdownHeroCard"

            visible: !!root.primaryGoal()
            Layout.fillWidth: true
            Layout.preferredHeight: 220
            bottomRimEnabled: true
            border.color: heroArea.containsMouse ? Theme.accent : Theme.glassBorder

            ColumnLayout {
                anchors.centerIn: parent
                width: parent.width - 64
                spacing: Theme.space8

                Text {
                    Layout.fillWidth: true
                    text: root.primaryGoal() ? root.primaryGoal().name : ""
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.Medium
                    color: Theme.inkStrong
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                }

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Theme.space8

                    Text {
                        objectName: "countdownHeroDays"

                        Layout.alignment: Qt.AlignBaseline
                        text: root.primaryGoal() ? Math.abs(Number(root.primaryGoal().daysRemaining || 0)) : "0"
                        font.pixelSize: Theme.fontDisplay
                        font.family: Theme.fontFamilyData
                        font.weight: Font.Bold
                        color: Theme.accentInk
                    }

                    Text {
                        Layout.alignment: Qt.AlignBaseline
                        text: "天"
                        font.pixelSize: Theme.fontXl
                        color: Theme.inkSoft
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: root.heroDateText()
                    font.pixelSize: Theme.fontMd
                    color: Theme.inkSoft
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            MouseArea {
                id: heroArea

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    var goal = root.primaryGoal();
                    if (goal) {
                        root.openEditor(goal.goalId, goal.name, goal.targetDate);
                    }
                }
            }
        }

        Text {
            visible: !!root.primaryGoal() && countdownListView.count > 1
            Layout.topMargin: Theme.space8
            text: "更多目标"
            font.pixelSize: Theme.fontSm
            font.weight: Font.Bold
            color: Theme.inkSoft
        }

        // 次要目标不再套不透明容器，玻璃行直接落在壁纸上。
        // 包装 Item 必须始终显式可见：Qt Quick Layouts 按可见性纳入/剔除条目，
        // 而祖先不可见时（离屏测试的 TestCase 就是隐藏的）子项显式 visible 翻转
        // 不会发出 visibleChanged，布局便永远不给它分配几何。列表和空状态卡
        // 都放进这个恒可见的包装里，各自的 visible 只控制绘制、不参与布局。
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            // 窗口很矮时布局会优先压缩无最小高度的项；这里保住两行的可视高度，
            // 否则 ListView 视口为 0 就不会实例化任何 delegate。
            Layout.minimumHeight: 150

            ListView {
                id: countdownListView
                objectName: "countdownSecondaryList"

                anchors.fill: parent
                visible: !!root.primaryGoal()
                spacing: 0
                clip: true
                model: root.countdownServiceRef ? root.countdownServiceRef.model : null

                delegate: Loader {
                    id: secondaryGoalLoader

                    width: ListView.view.width
                    height: active ? 74 : 0
                    active: index > 0

                    property int sourceIndex: index
                    property int sourceGoalId: model.goalId
                    property string sourceName: model.name
                    property date sourceTargetDate: model.targetDate
                    property int sourceDaysRemaining: model.daysRemaining

                    sourceComponent: CountdownItem {
                        objectName: "countdownSecondaryItem"
                        width: secondaryGoalLoader.width
                        height: 62
                        goalId: secondaryGoalLoader.sourceGoalId
                        goalName: secondaryGoalLoader.sourceName
                        targetDate: secondaryGoalLoader.sourceTargetDate
                        daysRemaining: secondaryGoalLoader.sourceDaysRemaining
                        // 第一条次要目标对应源模型 index 1，上移就是晋升主目标。
                        canMoveUp: secondaryGoalLoader.sourceIndex > 0
                        canMoveDown: secondaryGoalLoader.sourceIndex < countdownListView.count - 1

                        onClicked: root.openEditor(goalId, goalName, targetDate)
                        onDeleteRequested: function (id) {
                            if (root.countdownServiceRef) {
                                root.countdownServiceRef.deleteGoal(id);
                            }
                        }
                        onMoveUpRequested: {
                            if (root.countdownServiceRef) {
                                root.countdownServiceRef.reorder(
                                    secondaryGoalLoader.sourceIndex,
                                    secondaryGoalLoader.sourceIndex - 1);
                            }
                        }
                        onMoveDownRequested: {
                            if (root.countdownServiceRef) {
                                root.countdownServiceRef.reorder(
                                    secondaryGoalLoader.sourceIndex,
                                    secondaryGoalLoader.sourceIndex + 1);
                            }
                        }
                    }
                }
            }

            // —— 空状态：与今日任务页同构的引导卡 ——
            GlassPanel {
                objectName: "countdownEmptyStateCard"

                visible: !root.primaryGoal()
                anchors.centerIn: parent
                width: Math.min(420, parent.width - Theme.space16)
                height: 190

                ColumnLayout {
                    anchors.centerIn: parent
                    width: parent.width - 48
                    spacing: 10

                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        radius: Theme.radiusLg
                        color: Theme.accentFill

                        Text {
                            anchors.centerIn: parent
                            text: "倒"
                            font.pixelSize: Theme.fontXl
                            font.weight: Font.Bold
                            color: Theme.accentFillInk
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "还没有目标倒计时"
                        font.pixelSize: Theme.fontXl
                        font.weight: Font.Bold
                        color: Theme.ink
                        horizontalAlignment: Text.AlignHCenter
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "添加考试日或报名截止日，把最重要的日期放在每天都能看见的位置。"
                        font.pixelSize: Theme.fontMd
                        color: Theme.inkSoft
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }
    }
}
