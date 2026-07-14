import QtQuick
import QtQuick.Controls.Basic
import "../.."

Switch {
    id: root

    property bool reduceMotion: false
    readonly property int animationDuration: reduceMotion ? 0 : 120

    implicitWidth: 48
    implicitHeight: 44
    activeFocusOnTab: true
    Accessible.name: text

    indicator: Rectangle {
        x: root.width - width
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: 42
        implicitHeight: 24
        radius: height / 2
        color: root.checked ? Theme.accent : Theme.surfaceSunken
        border.color: root.activeFocus ? Theme.accentStrong : Theme.border
        border.width: root.activeFocus ? 2 : 1

        Rectangle {
            x: root.checked ? parent.width - width - 3 : 3
            anchors.verticalCenter: parent.verticalCenter
            width: 18
            height: 18
            radius: 9
            color: Theme.surface

            Behavior on x {
                NumberAnimation {
                    duration: root.animationDuration
                    easing.type: Easing.OutCubic
                }
            }
        }
    }

    contentItem: Item {}
}
