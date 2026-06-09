import QtQuick
import QtQuick.Controls

ApplicationWindow {
    id: root

    visible: true
    width: 1024
    height: 768
    minimumWidth: 860
    minimumHeight: 620
    title: "番茄Todo"
    color: "#fffef9"

    MainWindow {
        anchors.fill: parent
    }
}
