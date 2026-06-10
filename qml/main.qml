import QtQuick
import QtQuick.Controls

ApplicationWindow {
    id: root

    // 这里是 QML 应用入口，只负责窗口尺寸和装载真正的主界面。
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
