import QtQuick
import QtQuick.Controls
import ".."

// 番茄时长预设按钮：选中态暖色填充。从 FocusView 抽出，零外部状态依赖（仅 Theme + 自身）。
Button {
    id: presetButton

    property string backgroundObjectName: ""

    checkable: true
    implicitWidth: 104
    implicitHeight: 42

    background: Rectangle {
        objectName: presetButton.backgroundObjectName
        color: presetButton.checked ? Theme.accentFill : (presetButton.hovered ? Theme.surface : Theme.surfaceRaised)
        border.color: presetButton.checked ? Theme.accentStrong : Theme.border
        border.width: 1
        radius: Theme.radiusMd
    }

    contentItem: Text {
        text: presetButton.text
        textFormat: Text.PlainText
        color: presetButton.checked ? Theme.accentFillInk : Theme.ink
        font.pixelSize: Theme.fontMd
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
