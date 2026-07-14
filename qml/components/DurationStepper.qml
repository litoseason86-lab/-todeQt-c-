import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 暖纸步进器替代 SpinBox 与“自定义”chip。value 只读外部状态，
// 加减通过 adjusted 信号回给 select*Minutes，避免出现第二套时长来源。
RowLayout {
    id: stepper

    property int value: 0
    property int from: 1
    property int to: 99
    property string namePrefix: ""
    property string accessibleName: "时长"

    signal adjusted(int newValue)

    spacing: 0

    Button {
        id: minusButton
        objectName: stepper.namePrefix + "Minus"
        enabled: stepper.value > stepper.from
        implicitWidth: 44
        implicitHeight: 44
        activeFocusOnTab: true
        Accessible.name: "减少" + stepper.accessibleName
        onClicked: stepper.adjusted(stepper.value - 1)

        background: Rectangle {
            color: minusButton.enabled ? Theme.surface : Theme.surfaceSunken
            border.color: Theme.border
            border.width: 1
            radius: Theme.radiusMd
        }

        contentItem: Text {
            text: "−"
            textFormat: Text.PlainText
            color: minusButton.enabled ? Theme.inkSoft : Theme.inkMuted
            font.pixelSize: Theme.fontLg
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    Rectangle {
        implicitWidth: 56
        implicitHeight: 44
        color: Theme.surfaceSunken
        border.color: Theme.border
        border.width: 1

        Text {
            objectName: stepper.namePrefix + "Value"
            anchors.centerIn: parent
            text: stepper.value
            textFormat: Text.PlainText
            color: Theme.inkStrong
            font.pixelSize: Theme.fontMd
            font.weight: Font.DemiBold
            Accessible.role: Accessible.StaticText
            Accessible.name: stepper.accessibleName + "，" + stepper.value + "分钟"
        }
    }

    Button {
        id: plusButton
        objectName: stepper.namePrefix + "Plus"
        enabled: stepper.value < stepper.to
        implicitWidth: 44
        implicitHeight: 44
        activeFocusOnTab: true
        Accessible.name: "增加" + stepper.accessibleName
        onClicked: stepper.adjusted(stepper.value + 1)

        background: Rectangle {
            color: plusButton.enabled ? Theme.surface : Theme.surfaceSunken
            border.color: Theme.border
            border.width: 1
            radius: Theme.radiusMd
        }

        contentItem: Text {
            text: "+"
            textFormat: Text.PlainText
            color: plusButton.enabled ? Theme.inkSoft : Theme.inkMuted
            font.pixelSize: Theme.fontLg
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }
}
