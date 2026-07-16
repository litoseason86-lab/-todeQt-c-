pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import ".."

// macOS 风格分段控件：下沉的玻璃轨道里嵌一颗浮起的胶囊，胶囊滑到当前段。
// 用来表达「一组互斥选项里选一个」，视觉重量要明显低于页面主按钮，
// 避免和真正的行动按钮（如「开始专注」）抢注意力。
//
// 本组件是受控组件：自己不保存选中态。currentIndex 完全由调用方传入，
// 点击只发 activated(index)，由调用方决定要不要真的切换。
// 这样做是因为 QML 里对属性直接赋值会永久摧毁外部绑定——
// 如果组件内部自己改 currentIndex，调用方写的 `currentIndex: 业务状态`
// 就会在第一次点击后失效，控件从此和业务状态脱节。
FocusScope {
    id: root

    // 各段文案，按显示顺序排列；调用方负责 qsTr()。
    property var segments: []
    property int currentIndex: 0
    property bool reduceMotion: false
    // 无模糊环境改用更实的底色，保证轨道和胶囊仍分得开。
    property bool solidFallback: false

    // 用户点了某一段（含已选中的那一段），index 是该段下标。
    signal activated(int index)

    // 所有段等宽，按最宽文案统一。等宽的好处是切换时胶囊只需平移、不必同时变形，
    // 动画更稳，也不会因为文案长短不同让控件看起来歪。
    property int segmentWidth: 0
    // 文案两侧留白；不写死总宽是因为翻译后中文/英文长度差异很大。
    readonly property int labelPadding: Theme.space16
    readonly property int minSegmentWidth: 96
    // 轨道内壁到胶囊的缝隙，即胶囊「嵌在槽里」的那圈厚度。
    readonly property int trackInset: 3
    // 胶囊平移与文字变色共用这一个时长，两者必须完全同步才跟手。
    readonly property int slideDuration: 200

    implicitWidth: root.segmentWidth * root.segments.length + root.trackInset * 2
    implicitHeight: 34

    // Tab 停在整个控件上，段间切换交给左右方向键——与 macOS 分段控件一致。
    activeFocusOnTab: true
    Accessible.role: Accessible.Grouping

    onSegmentsChanged: root.measureSegments()
    Component.onCompleted: root.measureSegments()

    // 用隐藏的 TextMetrics 逐条量文案宽度取最大值。
    // 特意写成函数而不是绑定：绑定里改 labelProbe.text 会让 labelProbe.width 变化，
    // 而 width 又是本绑定的依赖，Qt 会报绑定循环。
    function measureSegments() {
        var widest = root.minSegmentWidth
        for (var i = 0; i < root.segments.length; i++) {
            labelProbe.text = root.segments[i]
            widest = Math.max(widest, Math.ceil(labelProbe.width) + root.labelPadding * 2)
        }
        root.segmentWidth = widest
    }

    // 方向键换段：到头就停住，不做首尾环绕——环绕会让键盘用户失去「已经到边」的感知。
    function stepSelection(delta) {
        var next = root.currentIndex + delta
        if (next < 0 || next >= root.segments.length)
            return
        root.activated(next)
    }

    TextMetrics {
        id: labelProbe
        // 与段内文字同一字体设置；选中态不再改字重，所以量一次就代表所有状态。
        font.pixelSize: Theme.fontMd
    }

    Keys.onLeftPressed: root.stepSelection(-1)
    Keys.onRightPressed: root.stepSelection(1)

    Rectangle {
        id: track
        objectName: "segmentedSwitchTrack"

        anchors.fill: parent
        radius: height / 2
        color: root.solidFallback ? Theme.glassSolidTrack : Theme.glassTrack

        // 键盘焦点环：不能只靠 hover，键盘用户必须看得见焦点在哪。
        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            radius: height / 2
            color: "transparent"
            border.width: 2
            border.color: Theme.focusRing
            visible: root.activeFocus
            Accessible.ignored: true
        }

        GlassPanel {
            id: thumb
            objectName: "segmentedSwitchThumb"

            x: root.trackInset + root.currentIndex * root.segmentWidth
            y: root.trackInset
            width: root.segmentWidth
            height: track.height - root.trackInset * 2
            radius: height / 2
            color: root.solidFallback ? Theme.glassSolidThumb : Theme.glassThumb
            solidFallback: root.solidFallback
            // 胶囊是整个控件里唯一会动的东西，这里特意不开落影：
            // panelShadowEnabled 会给它挂一层 layer(FBO) + MultiEffect 阴影 pass，
            // 而给正在平移的元素挂离屏纹理和 shader pass 正是掉帧的典型来源。
            // 「浮起」感由顶部受光棱边 + 底部暗棱 + 与轨道的明度差表达，够用且零开销。
            panelShadowEnabled: false
            specularEnabled: true
            bottomRimEnabled: true
            // 下标越界时不画胶囊，避免停在错误的段上误导用户。
            visible: root.currentIndex >= 0 && root.currentIndex < root.segments.length

            // 只动 x（等宽保证宽度恒定）：XAnimator 跑在渲染线程，
            // 切模式时正文要整块重排，UI 线程正忙，胶囊仍能稳住不掉帧。
            Behavior on x {
                enabled: !root.reduceMotion
                XAnimator {
                    duration: root.slideDuration
                    easing.type: Easing.OutCubic
                }
            }
        }

        // 文案层声明在胶囊之后，保证始终压在胶囊上方。
        Row {
            anchors.fill: parent
            anchors.margins: root.trackInset

            Repeater {
                model: root.segments

                AbstractButton {
                    id: segment

                    required property int index
                    required property var modelData

                    readonly property bool selected: root.currentIndex === segment.index

                    objectName: "segmentedSwitchSegment" + segment.index

                    width: root.segmentWidth
                    // Row 不管孩子的高度，这里从轨道反推；不写 parent.height 是因为
                    // Row 的高度本身由孩子撑出来，会形成循环依赖。
                    height: track.height - root.trackInset * 2
                    // 焦点交给外层 FocusScope，Tab 不该在段之间停留。
                    focusPolicy: Qt.NoFocus
                    onClicked: root.activated(segment.index)

                    Accessible.role: Accessible.RadioButton
                    Accessible.name: segment.modelData
                    Accessible.checked: segment.selected

                    contentItem: Text {
                        text: segment.modelData
                        font.pixelSize: Theme.fontMd
                        // 选中态不改字重：macOS 的分段控件靠胶囊本身表达选中，文字始终同一字重。
                        // 之前选中瞬间翻粗体、而胶囊还要滑 180ms 才到位，两者对不上；
                        // 翻字重还会触发字形重新栅格化。选中态改由「胶囊位置 + 字色」表达，
                        // 胶囊是位置/形状线索，不算只靠颜色。
                        //
                        // 未选中用 ink 而不是更淡的 inkSoft：轨道是压暗的凹槽，
                        // inkSoft 压在上面只有 4.27:1，够不到正文 AA 的 4.5:1。
                        color: {
                            if (segment.selected || segment.hovered)
                                return Theme.inkStrong
                            return Theme.ink
                        }
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter

                        // 与胶囊同一时长、同一曲线：三条动画各跑各的正是「切换发散」的来源。
                        Behavior on color {
                            enabled: !root.reduceMotion
                            ColorAnimation {
                                duration: root.slideDuration
                                easing.type: Easing.OutCubic
                            }
                        }
                    }
                }
            }
        }
    }
}
