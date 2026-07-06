import QtQuick
import QtQuick.Controls
import QtQuick.Effects
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
                Layout.fillWidth: true
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

            Button {
                id: addButton
                text: "添加目标"
                implicitWidth: 108
                implicitHeight: 44

                background: Rectangle {
                    color: addButton.pressed ? Theme.accentStrong : (addButton.hovered ? Theme.accentStrong : Theme.accent)
                    radius: Theme.radiusLg
                }

                contentItem: Text {
                    text: addButton.text
                    color: Theme.surface
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

        Rectangle {
            visible: !!root.primaryGoal()
            Layout.fillWidth: true
            Layout.preferredHeight: 210
            radius: Theme.radiusLg
            border.color: Theme.accent
            border.width: 2

            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Theme.accentSoft }
                GradientStop { position: 1.0; color: Theme.surfaceRaised }
            }

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
                anchors.centerIn: parent
                width: parent.width - 64
                spacing: Theme.space8

                Text {
                    Layout.fillWidth: true
                    text: root.primaryGoal() ? root.primaryGoal().name : ""
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.Medium
                    color: Theme.ink
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                }

                Text {
                    objectName: "countdownHeroDays"
                    Layout.fillWidth: true
                    text: root.primaryGoal() ? Math.abs(Number(root.primaryGoal().daysRemaining || 0)) : "0"
                    font.pixelSize: Theme.fontDisplay
                    font.family: Theme.fontFamilyData
                    font.weight: Font.Bold
                    color: Theme.accent
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    Layout.fillWidth: true
                    text: {
                        var goal = root.primaryGoal();
                        if (!goal) {
                            return "天";
                        }
                        return Number(goal.daysRemaining || 0) >= 0 ? "天" : "已过期";
                    }
                    font.pixelSize: Theme.fontLg
                    color: Theme.inkSoft
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    Layout.fillWidth: true
                    text: root.primaryGoal() ? Qt.formatDate(root.primaryGoal().targetDate, "yyyy年MM月dd日") : ""
                    font.pixelSize: Theme.fontMd
                    color: Theme.ink
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    var goal = root.primaryGoal();
                    if (goal) {
                        root.openEditor(goal.goalId, goal.name, goal.targetDate);
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Theme.radiusLg
            color: Theme.surface
            border.color: Theme.border
            border.width: 1

            Text {
                visible: !root.primaryGoal()
                anchors.centerIn: parent
                width: parent.width - 48
                text: "暂无目标倒计时\n\n点击右上角添加第一个目标"
                font.pixelSize: Theme.fontLg
                color: Theme.inkSoft
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            ListView {
                id: countdownListView

                anchors.fill: parent
                anchors.margins: Theme.space12
                visible: root.primaryGoal() !== null && root.primaryGoal() !== undefined && count > 1
                spacing: Theme.space12
                clip: true
                model: root.countdownServiceRef ? root.countdownServiceRef.model : null

                delegate: CountdownItem {
                    visible: index > 0
                    width: ListView.view.width
                    goalId: model.goalId
                    goalName: model.name
                    targetDate: model.targetDate
                    daysRemaining: model.daysRemaining
                    canMoveUp: index > 1
                    canMoveDown: index < ListView.view.count - 1

                    onClicked: root.openEditor(model.goalId, model.name, model.targetDate)
                    onDeleteRequested: function (id) {
                        if (root.countdownServiceRef) {
                            root.countdownServiceRef.deleteGoal(id);
                        }
                    }
                    onMoveUpRequested: {
                        if (root.countdownServiceRef) {
                            // 上移/下移是拖拽排序的低风险替代交互，同样会更新首选目标顺序。
                            root.countdownServiceRef.reorder(index, index - 1);
                        }
                    }
                    onMoveDownRequested: {
                        if (root.countdownServiceRef) {
                            root.countdownServiceRef.reorder(index, index + 1);
                        }
                    }
                }
            }
        }
    }
}
