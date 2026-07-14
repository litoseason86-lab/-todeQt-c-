import QtQuick
import QtQuick.Controls

Control {
    id: root

    objectName: "settingsNavigation"
    property int currentIndex: 0
    property bool compact: false
    signal categoryRequested(int index)
}
