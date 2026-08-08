import QtQuick
import QtQuick.Layouts
import ".."
import "../.."

// 设置分组卡里的一行：左侧图标 + 标题/说明，右侧放控件。
//
// 行高由内容决定而不是写死：原来固定 68px 是按「标题 + 说明」两行的最坏情况配的，
// 结果只有标题的行也占 68px，一屏放不下几行。现在只保证 44px 的可点最小高度
// （无障碍下限），其余交给内容自己撑。
Item {
    id: root

    default property alias trailing: trailingSlot.data
    property string label: ""
    property string caption: ""
    // 行首图标：iconName 走 GlyphIcon 线性图标；iconText 走文字字形（如「Aa」）。
    property string iconName: ""
    property string iconText: ""
    property bool compact: false

    readonly property bool hasIcon: iconName.length > 0 || iconText.length > 0

    Layout.fillWidth: true
    // 44 是可点目标的无障碍下限；上下各留 8px 呼吸，两行文字时自然长到 ~56px。
    implicitHeight: Math.max(44, rowLayout.implicitHeight + Theme.space8 * 2)

    RowLayout {
        id: rowLayout

        anchors.fill: parent
        anchors.topMargin: Theme.space8
        anchors.bottomMargin: Theme.space8
        spacing: Theme.space12

        // 图标不再套浅色圆角方块：那层色块在每一行重复出现，是纯装饰的“贴纸感”，
        // 信息量为零却主导了整页的视觉噪音。线条图标直接落在卡片底上就够。
        GlyphIcon {
            visible: root.iconName.length > 0
            Layout.preferredWidth: 20
            Layout.preferredHeight: 20
            Layout.alignment: Qt.AlignVCenter
            name: root.iconName
            size: 20
            color: Theme.inkSoft
        }

        Text {
            visible: root.iconText.length > 0
            Layout.preferredWidth: 20
            Layout.alignment: Qt.AlignVCenter
            text: root.iconText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontLg
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.minimumWidth: 110
            Layout.alignment: Qt.AlignVCenter
            // 没有图标的行左边补齐图标宽度，让所有行的文字起始位置对齐。
            Layout.leftMargin: root.hasIcon ? 0 : 20 + Theme.space12
            spacing: 2

            Text {
                Layout.fillWidth: true
                text: root.label
                color: Theme.ink
                font.pixelSize: Theme.fontLg
                wrapMode: Text.WordWrap
            }

            Text {
                Layout.fillWidth: true
                visible: root.caption.length > 0
                text: root.caption
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                wrapMode: Text.WordWrap
            }
        }

        RowLayout {
            id: trailingSlot

            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            spacing: Theme.space8
        }
    }
}
