pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    property string title: ""
    property string value: "0"
    property string unit: ""
    property string subtitle: ""
    property int animationDelay: 0
    property string comparisonText: ""
    property int comparisonTrend: 0
    property bool showComparison: false
    // 减少动效默认读全局 appSettings；测试可直接覆盖该属性，不需要构造完整应用上下文。
    // qmllint disable unqualified
    property bool reduceMotionActive: Theme.reduceMotion
                                      || (typeof appSettings !== "undefined"
                                          && appSettings && appSettings.reduceMotion)
    // qmllint enable unqualified
    readonly property bool valuePulseRunning: valuePulse.running
    readonly property color cardShadowColor: Theme.ink
    readonly property real cardShadowOpacity: 0.08
    readonly property real cardShadowBlur: 0.18
    readonly property real cardShadowHorizontalOffset: 0
    readonly property real cardShadowVerticalOffset: 2

    function restartIntro() {
        // 视图重新显示时重播入场动画，数据刷新不会显得突兀。
        fadeInAnimation.restart();
    }

    implicitWidth: 190
    implicitHeight: root.showComparison && root.comparisonText.length > 0 ? 126 : 104
    radius: Theme.radiusLg
    color: Theme.glassCard
    border.color: Theme.glassBorder
    border.width: 1
    layer.enabled: true
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: root.cardShadowColor
        shadowOpacity: root.cardShadowOpacity
        shadowBlur: root.cardShadowBlur
        shadowHorizontalOffset: root.cardShadowHorizontalOffset
        shadowVerticalOffset: root.cardShadowVerticalOffset
    }
    opacity: 0

    Component.onCompleted: fadeInAnimation.start()

    onReduceMotionActiveChanged: {
        if (root.reduceMotionActive) {
            valuePulse.stop()
            valueText.scale = 1
        }
    }

    SequentialAnimation {
        id: fadeInAnimation

        ScriptAction {
            script: root.opacity = 0
        }
        PauseAnimation {
            duration: Theme.reduceMotion ? 0 : root.animationDelay
        }
        OpacityAnimator {
            target: root
            from: 0
            to: 1
            duration: Theme.reduceMotion ? 0 : 180
            easing.type: Easing.OutQuad
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space12
        spacing: Theme.space8

        Text {
            Layout.fillWidth: true
            text: root.title
            font.pixelSize: Theme.fontMd
            font.weight: Font.Bold
            color: Theme.inkSoft
            elide: Text.ElideRight
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space4

            Text {
                id: valueText
                objectName: "statCardValue"

                // 数值和单位要读成一个量（「2.6 小时」）。这里不能撑满整行：
                // 撑满会把单位顶到卡片最右缘，中间空出一大段，数字和单位读着像两回事。
                // 改为按内容取宽，上限收在「卡片内宽 - 单位宽」，
                // 长数值被上限截住时仍由 HorizontalFit 缩字号兜底。
                Layout.maximumWidth: Math.max(
                        root.width - Theme.space12 * 2
                        - (unitText.visible ? unitText.implicitWidth + Theme.space4 : 0), 1)
                text: root.value
                font.pixelSize: Theme.fontXxl
                font.family: Theme.fontFamilyData
                font.weight: Font.Bold
                fontSizeMode: Text.HorizontalFit
                minimumPixelSize: 18
                color: Theme.ink
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter

                onTextChanged: {
                    if (!root.reduceMotionActive) {
                        valuePulse.restart()
                    }
                }

                SequentialAnimation {
                    id: valuePulse

                    // 数值变化时用轻微脉冲提示刷新，不改变卡片布局。
                    NumberAnimation {
                        target: valueText
                        property: "scale"
                        to: 1.05
                        duration: Theme.reduceMotion ? 0 : 150
                        easing.type: Easing.OutQuad
                    }

                    NumberAnimation {
                        target: valueText
                        property: "scale"
                        to: 1.0
                        duration: Theme.reduceMotion ? 0 : 150
                        easing.type: Easing.InOutQuad
                    }
                }
            }

            Text {
                id: unitText

                visible: root.unit.length > 0
                text: root.unit
                font.pixelSize: Theme.fontMd
                color: Theme.inkSoft
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }

            // 富余宽度全部归这根尾部弹簧，数值与单位保持在左侧成组。
            Item {
                Layout.fillWidth: true
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root.subtitle.length > 0
            text: root.subtitle
            font.pixelSize: Theme.fontSm
            color: Theme.inkSoft
            elide: Text.ElideRight
        }

        Text {
            objectName: "statCardComparisonText"

            Layout.fillWidth: true
            visible: root.showComparison && root.comparisonText.length > 0
            text: root.comparisonText
            font.pixelSize: Theme.fontMd
            color: {
                if (root.comparisonTrend > 0) {
                    return Theme.success
                }
                if (root.comparisonTrend < 0) {
                    return Theme.danger
                }
                return Theme.inkSoft
            }
            elide: Text.ElideRight
        }
    }
}
