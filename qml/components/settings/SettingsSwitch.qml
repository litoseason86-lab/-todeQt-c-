import QtQuick
import QtQuick.Controls.Basic
import "../.."

Switch {
    id: root

    property bool reduceMotion: false
    // 控件只展示后端已确认的值。点击后的临时 checked 不能成为第二个状态源，
    // 否则 QSettings 写失败时界面会显示伪成功直到重新打开弹窗。
    property bool persistedChecked: false
    readonly property int animationDuration: reduceMotion ? 0 : 120
    signal changeRequested(bool enabled)

    implicitWidth: 48
    implicitHeight: 44
    activeFocusOnTab: true
    checked: persistedChecked
    Accessible.name: text

    onToggled: {
        root.changeRequested(root.checked)
        // 后端 setter 是同步的；下一事件轮次恢复绑定并回读成功值或失败后的旧值。
        Qt.callLater(function() {
            root.checked = Qt.binding(function() { return root.persistedChecked })
        })
    }

    indicator: Rectangle {
        x: root.width - width
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: 42
        implicitHeight: 24
        radius: height / 2
        color: root.checked ? Theme.accent : Theme.surfaceSunken
        border.color: root.activeFocus ? Theme.focusRing : Theme.border
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
