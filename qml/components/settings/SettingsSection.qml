import QtQuick
import QtQuick.Layouts
import "../.."

ColumnLayout {
    id: root

    default property alias content: sectionContent.data
    property string title: ""
    property string description: ""
    // 分组卡：把成组的设置行收进圆角卡片（macOS 系统设置观感）。
    // 主题画廊等非行内容传 card:false，保持平铺。
    property bool card: true

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

    Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: Theme.space4
        implicitHeight: sectionContent.implicitHeight + (root.card ? Theme.space8 * 2 : 0)
        color: root.card ? Theme.surfaceRaised : "transparent"
        border.color: root.card ? Theme.borderSubtle : "transparent"
        border.width: root.card ? 1 : 0
        radius: Theme.radiusLg

        ColumnLayout {
            id: sectionContent

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: root.card ? Theme.space16 : 0
            anchors.rightMargin: root.card ? Theme.space16 : 0
            anchors.topMargin: root.card ? Theme.space8 : 0
            spacing: 0
        }
    }
}
