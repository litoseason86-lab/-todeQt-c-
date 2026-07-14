import QtQuick.Controls

Switch {
    id: root

    property bool reduceMotion: false
    readonly property int animationDuration: reduceMotion ? 0 : 120
}
