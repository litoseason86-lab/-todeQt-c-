import QtQuick
import QtQuick.Effects
import QtQuick.Layouts

Rectangle {
    id: root

    property string title: ""
    property string value: "0"
    property string unit: ""
    property string subtitle: ""
    property int animationDelay: 0

    function restartIntro() {
        // 视图重新显示时重播入场动画，数据刷新不会显得突兀。
        fadeInAnimation.restart();
    }

    implicitWidth: 190
    implicitHeight: 104
    radius: 8
    color: "#fffef9"
    border.color: "#e8dfc8"
    border.width: 1
    layer.enabled: true
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: "#000000"
        shadowOpacity: 0.08
        shadowBlur: 0.14
        shadowHorizontalOffset: 0
        shadowVerticalOffset: 2
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
        anchors.margins: 14
        spacing: 6

        Text {
            Layout.fillWidth: true
            text: root.title
            font.pixelSize: 13
            font.weight: Font.Bold
            color: "#8b7355"
            elide: Text.ElideRight
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 4

            Text {
                id: valueText

                Layout.fillWidth: true
                text: root.value
                font.pixelSize: 28
                font.weight: Font.Bold
                fontSizeMode: Text.HorizontalFit
                minimumPixelSize: 18
                color: "#5d4e37"
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
                font.pixelSize: 13
                color: "#8b7355"
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }

        Text {
            Layout.fillWidth: true
            visible: root.subtitle.length > 0
            text: root.subtitle
            font.pixelSize: 12
            color: "#8b7355"
            elide: Text.ElideRight
        }
    }
}
