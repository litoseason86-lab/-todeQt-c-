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
    color: Theme.surface
    border.color: Theme.border
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

    SequentialAnimation {
        id: fadeInAnimation

        ScriptAction {
            script: root.opacity = 0
        }
        PauseAnimation {
            duration: root.animationDelay
        }
        OpacityAnimator {
            target: root
            from: 0
            to: 1
            duration: 180
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

                Layout.fillWidth: true
                text: root.value
                font.pixelSize: Theme.fontXxl
                font.weight: Font.Bold
                fontSizeMode: Text.HorizontalFit
                minimumPixelSize: 18
                color: Theme.ink
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter

                onTextChanged: valuePulse.restart()

                SequentialAnimation {
                    id: valuePulse

                    // 数值变化时用轻微脉冲提示刷新，不改变卡片布局。
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
                font.pixelSize: Theme.fontMd
                color: Theme.inkSoft
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
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
