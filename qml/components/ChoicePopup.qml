pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 应用自己的选项弹层：备忘录页的科目下拉、「新建」菜单、挑科目都用它。
// 外观和专注页的任务选择同一套：玻璃底（不能模糊时退回实色）、圆角、浮起阴影。
// 行为照系统下拉菜单：打开时停在当前项；鼠标移到哪行、方向键走到哪行，哪行就亮起焦糖底，看得出点下去会选哪个；
// 当前项另有对勾、字重加一级，亮起的行移走了也认得出来；回车、空格选定，Esc 或点外面关闭。
Popup {
    id: popup

    // 每项：{ id, name, color（科目色点，可空）, action（「新建…」这类动作项：前面画加号，上方一条分隔线）}
    property var options: []
    // 当前项的 id，画对勾；菜单这类没有当前项的不设。
    property var currentId: undefined
    // 测试按名字找：背景、列表、每一行分别叫 <前缀>PopupBackground、<前缀>List、<前缀>Option<id>。
    property string namePrefix: ""
    // 行首留给色点、加号的一格。整张都没有色点的菜单不留，文字靠左。
    property bool showLeading: true
    property bool touchUi: false
    property string accessibleName: ""
    readonly property alias list: optionList
    // 亮起行的底色与它的零透明版本：颜色过渡只改透明度，不会从黑色插值出一层灰。
    readonly property color litColor: Theme.inputPopupHighlight
    readonly property color litIdle: Qt.rgba(litColor.r, litColor.g, litColor.b, 0)
    // 这次选中的项，弹层完全关上后随 finished 发出。
    property var pickedOption: null

    // 选中一项后马上发出：换科目这类只改数值的选择在这里生效。
    signal picked(var option)
    // 弹层完全关上后发出；按 Esc、点外面关掉时 option 为 null。
    // 选完要接着打开另一层的（比如「新建分类…」接着挑科目），放在这里做：
    // 等这一层淡出完再打开下一层，两层不会叠在同一个位置一起动。
    signal finished(var option)

    function choose(index) {
        var option = popup.options[index];
        if (!option)
            return;
        popup.pickedOption = option;
        popup.close();
        popup.picked(option);
    }

    padding: Theme.space8
    margins: Theme.space8
    modal: false
    dim: false
    focus: true
    // 按在弹层所属的按钮上不算「点外面」：否则按下时弹层先关，松手时按钮又把它打开，点按钮收不起来。
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

    // 打开前就停到当前项：淡入的那一下已经看得到它亮着，方向键也从它开始走。
    onAboutToShow: {
        popup.pickedOption = null;
        var index = popup.options.findIndex(function (option) {
            return option.id === popup.currentId;
        });
        optionList.currentIndex = Math.max(0, index);
        optionList.positionViewAtIndex(optionList.currentIndex, ListView.Contain);
    }
    onClosed: {
        var option = popup.pickedOption;
        popup.pickedOption = null;
        popup.finished(option);
    }

    // 从按钮那一侧淡入、略微放大展开；收起时反过来，比打开快一点。减少动效时直接出现、消失。
    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "opacity"
                from: 0
                to: 1
                duration: Theme.reduceMotion ? 0 : 140
                easing.type: Easing.OutQuad
            }
            NumberAnimation {
                property: "scale"
                from: 0.96
                to: 1
                duration: Theme.reduceMotion ? 0 : 140
                easing.type: Easing.OutCubic
            }
        }
    }
    exit: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "opacity"
                from: 1
                to: 0
                duration: Theme.reduceMotion ? 0 : 100
                easing.type: Easing.InQuad
            }
            NumberAnimation {
                property: "scale"
                from: 1
                to: 0.96
                duration: Theme.reduceMotion ? 0 : 100
                easing.type: Easing.InQuad
            }
        }
    }

    background: GlassPanel {
        objectName: popup.namePrefix + "PopupBackground"
        radius: Theme.radiusLg
        color: Theme.glassBlurAllowed ? Theme.glassDialog : Theme.glassSolidCard
        solidFallback: !Theme.glassBlurAllowed
        panelShadowEnabled: true
    }

    contentItem: ListView {
        id: optionList
        objectName: popup.namePrefix + "List"
        implicitHeight: Math.min(contentHeight, 320)
        // 弹层拿到焦点时由列表接住，方向键、回车直接生效。
        focus: true
        clip: true
        model: popup.options
        spacing: 2
        boundsBehavior: Flickable.StopAtBounds
        keyNavigationEnabled: true
        Accessible.role: Accessible.List
        Accessible.name: popup.accessibleName
        Keys.onReturnPressed: popup.choose(optionList.currentIndex)
        Keys.onEnterPressed: popup.choose(optionList.currentIndex)
        Keys.onSpacePressed: popup.choose(optionList.currentIndex)
        ScrollBar.vertical: PageScrollBar {}
        delegate: ItemDelegate {
            id: option
            required property var modelData
            required property int index
            readonly property bool isAction: !!option.modelData.action
            readonly property bool current: popup.currentId !== undefined && option.modelData.id === popup.currentId
            // 亮起：键盘或鼠标停在这一行（列表的当前行），或者正按着它。
            readonly property bool lit: option.ListView.isCurrentItem || option.down
            // 动作项和上面的选项之间留一条分隔线的位置。
            readonly property int separatorSpace: option.isAction && option.index > 0 ? Theme.space8 + 1 : 0
            objectName: popup.namePrefix + "Option" + option.modelData.id
            width: optionList.width
            // 文字在亮起的底色里上下居中：上边让出分隔线的位置，下边清掉 Basic 样式默认的 8。
            topInset: option.separatorSpace
            topPadding: option.separatorSpace
            bottomPadding: 0
            implicitHeight: (popup.touchUi ? 44 : Theme.controlHeightMd) + option.separatorSpace
            leftPadding: Theme.space12
            rightPadding: Theme.space12
            hoverEnabled: !popup.touchUi
            Accessible.name: option.modelData.name
            // 鼠标移到哪行，哪行就成为当前行：亮起的只有一行，键盘接着从这里走。
            onHoveredChanged: {
                if (option.hovered)
                    optionList.currentIndex = option.index;
            }
            onClicked: popup.choose(option.index)
            background: Rectangle {
                objectName: popup.namePrefix + "OptionBackground" + option.modelData.id
                radius: Theme.radiusSm
                color: option.lit ? popup.litColor : popup.litIdle
                Behavior on color {
                    ColorAnimation {
                        duration: Theme.reduceMotion ? 0 : 120
                        easing.type: Easing.OutQuad
                    }
                }
            }
            Rectangle {
                visible: option.separatorSpace > 0
                x: Theme.space4
                y: Math.round(Theme.space8 / 2)
                width: option.width - Theme.space4 * 2
                height: 1
                color: Theme.borderSubtle
            }
            contentItem: RowLayout {
                spacing: Theme.space8
                Item {
                    visible: popup.showLeading
                    implicitWidth: 12
                    implicitHeight: 12
                    Rectangle {
                        readonly property string dotColor: String(option.modelData.color || "")
                        visible: !option.isAction && dotColor.length > 0
                        anchors.centerIn: parent
                        width: 8
                        height: 8
                        radius: 4
                        color: dotColor.length > 0 ? dotColor : Qt.rgba(1, 1, 1, 0)
                    }
                    GlyphIcon {
                        visible: option.isAction
                        anchors.centerIn: parent
                        name: "plus"
                        size: 12
                        color: option.lit ? Theme.ink : Theme.inkSoft
                        Accessible.ignored: true
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: option.modelData.name
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontMd
                    font.weight: option.current ? Font.Medium : Font.Normal
                    // 动作项平时用次要色；亮起时换正文色，压在焦糖底上也够 4.5:1。
                    color: option.current ? Theme.accentFillInk : (option.isAction && !option.lit ? Theme.inkSoft : Theme.ink)
                    elide: Text.ElideRight
                }
                GlyphIcon {
                    objectName: popup.namePrefix + "OptionCheck" + option.modelData.id
                    visible: option.current
                    name: "check"
                    size: 14
                    color: Theme.accentFillInk
                    Accessible.ignored: true
                }
            }
        }
    }
}
