import QtQuick
import QtQuick.Layouts
import ".."

// 仪表盘统计卡：图标徽章 + 标题 / 大数值 + 单位 / 副标题 / 底部图表插槽。
// 与通用 StatCard 的区别：带表意图标和迷你图表位，只服务于仪表盘。
// 实例的子元素默认落进底部插槽（放 MiniTrendChart / MiniBarChart / 进度条）。
GlassPanel {
    id: root

    property string icon: ""
    property string title: ""
    property string value: "0"
    property string unit: ""
    property string subtitle: ""
    property int animationDelay: 0
    // qmllint disable unqualified
    property bool reduceMotionActive: typeof appSettings !== "undefined" && appSettings && appSettings.reduceMotion
    // qmllint enable unqualified

    default property alias footerContent: footerSlot.data

    implicitWidth: 190
    implicitHeight: 132
    opacity: 0

    Component.onCompleted: fadeInAnimation.start()

    SequentialAnimation {
        id: fadeInAnimation

        // 与 StatCard 一致的错峰入场；减少动效时直接定格不透明。
        ScriptAction {
            script: root.opacity = root.reduceMotionActive ? 1 : 0
        }
        PauseAnimation {
            duration: root.reduceMotionActive ? 0 : root.animationDelay
        }
        OpacityAnimator {
            target: root
            from: 0
            to: 1
            duration: root.reduceMotionActive ? 0 : 180
            easing.type: Easing.OutQuad
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space12
        spacing: Theme.space8

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space8

            Rectangle {
                Layout.preferredWidth: 26
                Layout.preferredHeight: 26
                radius: Theme.radiusMd
                color: Theme.glassAccent
                border.color: Theme.glassBorder
                border.width: 1
                visible: root.icon.length > 0

                Text {
                    anchors.centerIn: parent
                    text: root.icon
                    textFormat: Text.PlainText
                    // 单字标记沿用侧栏的设计语言：焦糖字 + 玻璃底，不用表情图标。
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Bold
                    color: Theme.accentInk
                }
            }

            Text {
                Layout.fillWidth: true
                text: root.title
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
                color: Theme.inkSoft
                elide: Text.ElideRight
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space4

            Text {
                id: valueText
                objectName: "dashboardStatValue"

                text: root.value
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontXxl
                font.family: Theme.fontFamilyData
                font.weight: Font.Bold
                color: Theme.inkStrong

                onTextChanged: {
                    if (!root.reduceMotionActive) {
                        valuePulse.restart()
                    }
                }

                SequentialAnimation {
                    id: valuePulse

                    // 数值刷新的轻微脉冲提示，不改布局。
                    NumberAnimation {
                        target: valueText
                        property: "scale"
                        to: 1.05
                        duration: 150
                        easing.type: Easing.OutQuad
                    }

                    NumberAnimation {
                        target: valueText
                        property: "scale"
                        to: 1.0
                        duration: 150
                        easing.type: Easing.InOutQuad
                    }
                }
            }

            Text {
                visible: root.unit.length > 0
                text: root.unit
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontMd
                color: Theme.inkSoft
                Layout.alignment: Qt.AlignBottom
                Layout.bottomMargin: Theme.space4
            }

            Item {
                Layout.fillWidth: true
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root.subtitle.length > 0
            text: root.subtitle
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontSm
            color: Theme.inkSoft
            elide: Text.ElideRight
        }

        Item {
            id: footerSlot

            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 20
        }
    }
}
