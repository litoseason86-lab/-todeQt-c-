import QtQuick
import QtQuick.Layouts
import "../.."

ColumnLayout {
    id: root

    default property alias content: sectionContent.data
    property string title: ""
    property string description: ""

    width: parent ? parent.width : implicitWidth
    spacing: Theme.space8

    Text {
        Layout.fillWidth: true
        text: root.title
        color: Theme.inkStrong
        font.pixelSize: Theme.fontLg
        font.weight: Font.DemiBold
    }

    Text {
        Layout.fillWidth: true
        visible: root.description.length > 0
        text: root.description
        color: Theme.inkSoft
        font.pixelSize: Theme.fontMd
        wrapMode: Text.WordWrap
    }

    ColumnLayout {
        id: sectionContent

        Layout.fillWidth: true
        Layout.topMargin: Theme.space4
        spacing: 0
    }
}
