pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    width: 208
    // 导航栏允许着色玻璃；实时模糊由 MainWindow.sidebarFrost 单层采样，这里不二次模糊。
    color: Theme.glassBlurAllowed ? Theme.glassSidebar : Theme.glassSolidSidebar
    // 玻璃侧栏上的条目默认态要“隐形”才能透出壁纸；但不能用 Qt 的 transparent（黑基透明）：
    // hover 退场的 ColorAnimation 会在黑白之间插出灰闪。白基透明只动 alpha，不经过灰。
    readonly property color sidebarItemIdleColor: Qt.rgba(1, 1, 1, 0)
    readonly property color sidebarItemIdleBorderColor: Qt.rgba(1, 1, 1, 0)
    readonly property color sidebarItemHoverColor: Qt.rgba(1, 1, 1, 0.45)
    readonly property color sidebarItemHoverBorderColor: Theme.border
    readonly property color sidebarItemActiveColor: Theme.glassAccent
    readonly property color sidebarItemActiveBorderColor: Theme.accent

    property string currentView: "today"
    property var focusTimerRef: null
    // 顺序由设置决定；ref 缺失时退回本组件自带的出厂顺序，侧栏不能因为没注入设置就空掉。
    property var settingsRef: null

    // 条目的呈现定义：这张表只回答「这个 id 长什么样」，不回答顺序。
    // 顺序的唯一定义处是 AppSettings::defaultSidebarOrder()，用户可在设置里重排。
    // 新增页面要同时改这两处，QmlTest.sidebar_order 会在漏改时转红。
    readonly property var entryPresentation: ({
        "dashboard": { text: "仪表盘", marker: "仪", iconName: "" },
        "today": { text: "今日任务", marker: "今", iconName: "" },
        "todayFocus": { text: "今日专注", marker: "记", iconName: "" },
        "focus": { text: "专注计时", marker: "专", iconName: "" },
        "schedule": { text: "课表", marker: "课", iconName: "" },
        "week": { text: "本周计划", marker: "周", iconName: "" },
        "month": { text: "专注历史", marker: "月", iconName: "" },
        "stats": { text: "数据统计", marker: "数", iconName: "" },
        "countdown": { text: "目标倒计时", marker: "倒", iconName: "" },
        "goals": { text: "目标", marker: "目", iconName: "target" },
        "knowledgeGaps": { text: "知识缺口", marker: "补", iconName: "gap" }
    })

    // 出厂顺序的兜底副本。正常路径读 settingsRef.sidebarOrder；
    // 离屏测试和预览场景常常只注入自己关心的那几个 ref，不能因此渲不出侧栏。
    readonly property var fallbackOrder: [
        "dashboard", "today", "todayFocus", "focus", "schedule", "week",
        "month", "stats", "countdown", "goals", "knowledgeGaps"
    ]

    // 实际渲染用的有序 id 列表。这里再过滤一次不认识的 id：
    // 设置层已经归一化过，但替身或旧配置仍可能塞进本组件没有呈现定义的 id，
    // 那会让 delegate 读到 undefined 而整行空白。
    readonly property var orderedEntryIds: {
        var source = root.settingsRef && root.settingsRef.sidebarOrder
                     && root.settingsRef.sidebarOrder.length > 0
                ? root.settingsRef.sidebarOrder
                : root.fallbackOrder
        var result = []
        for (var i = 0; i < source.length; ++i) {
            var id = String(source[i])
            if (root.entryPresentation[id] !== undefined && result.indexOf(id) < 0) {
                result.push(id)
            }
        }
        return result
    }
    // 减少动效默认读全局 appSettings；测试可直接覆盖该属性，避免为了一个开关伪造整套上下文。
    // qmllint disable unqualified
    property bool reduceMotionActive: Theme.reduceMotion
                                      || (typeof appSettings !== "undefined"
                                          && appSettings && appSettings.reduceMotion)
    // qmllint enable unqualified
    signal itemClicked(string viewName)
    signal settingsRequested
    // 请求收起侧栏：由 MainWindow 做宽度动画与持久化，侧栏自身不持有布局态。
    signal collapseRequested()

    function formatMinuteTime(seconds) {
        var safe = Math.max(0, Number(seconds || 0))
        var minutes = Math.floor(safe / 60)
        var secs = safe % 60
        return (minutes < 10 ? "0" : "") + minutes + ":" + (secs < 10 ? "0" : "") + secs
    }

    function formatClockTime(seconds) {
        var safe = Math.max(0, Number(seconds || 0))
        var hours = Math.floor(safe / 3600)
        var minutes = Math.floor((safe % 3600) / 60)
        var secs = safe % 60
        return (hours < 10 ? "0" : "") + hours + ":"
                + (minutes < 10 ? "0" : "") + minutes + ":"
                + (secs < 10 ? "0" : "") + secs
    }

    function focusStatusFor(hasActiveSession, phase, mode, isRunning, remainingSeconds, elapsedSeconds) {
        // 参数显式传入，保证 QML 绑定依赖具体 timer 属性；tick 才能驱动文本每秒刷新。
        var active = hasActiveSession || phase !== 0
        if (!active) {
            return ""
        }
        var timeText = mode === 1 ? root.formatMinuteTime(remainingSeconds) : root.formatClockTime(elapsedSeconds)
        return (isRunning ? "● " : "⏸ ") + (mode === 2 ? "休息 " : "") + timeText
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space16
        spacing: Theme.space4

        // 标题行右侧放 Apple 风侧栏切换钮（收起）。
        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: Theme.space8
            spacing: Theme.space8

            Text {
                text: "番茄Todo"
                font.pixelSize: Theme.fontXl
                font.weight: Font.Bold
                color: Theme.ink
                Layout.fillWidth: true
                elide: Text.ElideRight
            }

            GlassToolbarButton {
                id: collapseButton
                objectName: "sidebarCollapseButton"

                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                implicitWidth: 30
                implicitHeight: 30
                reduceMotion: root.reduceMotionActive
                // 嵌在侧栏玻璃上：关掉落影，避免双层阴影发灰。
                solidFallback: !Theme.glassBlurAllowed
                Accessible.name: "隐藏侧栏"
                onClicked: root.collapseRequested()

                // 侧栏内嵌钮不需要再套一层 panel 阴影。
                Component.onCompleted: {
                    // background 的具体组件在运行时提供 panelShadowEnabled，静态类型只有 QQuickItem。
                    // qmllint disable missing-property
                    if (background && background.panelShadowEnabled !== undefined)
                        background.panelShadowEnabled = false
                    // qmllint enable missing-property
                }
            }
        }

        // 条目按用户设定的顺序渲染。原来这里是两组写死的 SidebarItem，中间夹一条
        // 「时间视图」小标题和一条分隔线；顺序既然交给用户，分组就不再成立——
        // 一个用户可以把「课表」排到「今日任务」前面，那条线也就失去了含义。
        Repeater {
            model: root.orderedEntryIds

            SidebarItem {
                id: entryItem
                required property string modelData

                readonly property var presentation: root.entryPresentation[entryItem.modelData]

                text: entryItem.presentation ? entryItem.presentation.text : ""
                marker: entryItem.presentation ? entryItem.presentation.marker : ""
                iconName: entryItem.presentation ? entryItem.presentation.iconName : ""
                isActive: root.currentView === entryItem.modelData
                // 只有专注计时那一条带走秒状态；参数显式传入，tick 才能驱动文本每秒刷新。
                statusText: entryItem.modelData === "focus" && root.focusTimerRef
                            ? root.focusStatusFor(root.focusTimerRef.hasActiveSession,
                                                  root.focusTimerRef.phase,
                                                  root.focusTimerRef.mode,
                                                  root.focusTimerRef.isRunning,
                                                  root.focusTimerRef.remainingSeconds,
                                                  root.focusTimerRef.elapsedSeconds)
                            : ""
                onClicked: root.itemClicked(entryItem.modelData)
            }
        }

        Item {
            Layout.fillHeight: true
        }

        SidebarItem {
            text: "设置"
            marker: "设"
            isActive: false
            onClicked: root.settingsRequested()
        }
    }

    // 条目根用 Control 而不是 Rectangle：焦点环要区分「键盘把焦点送进来」和「别的原因让焦点回来」，
    // 而只有 Control 带 visualFocus（焦点原因是 Tab / Backtab / 快捷键时才为真）。
    // 纯 Rectangle 只看得到 activeFocus：窗口切走再切回、弹窗关闭把焦点还回来时它同样从假变真，
    // 于是鼠标点过的那一项会在窗口重新激活后亮起焦点环，和当前选中项一起出现两个框。
    component SidebarItem: Control {
        id: item

        property string text: ""
        property string marker: ""
        // 新入口优先使用项目已有线性图标；旧入口仍显示单字标记，避免扩大本期视觉改造范围。
        property string iconName: ""
        property bool isActive: false
        property string statusText: ""
        readonly property string statusGlyph: item.statusText.indexOf("● ") === 0
                                             ? "●"
                                             : (item.statusText.indexOf("⏸ ") === 0 ? "⏸" : "")
        readonly property string statusTimeText: item.statusGlyph.length > 0
                                                ? item.statusText.slice(2)
                                                : item.statusText
        // 显式状态能抵消 MouseArea 和 HoverHandler 在不同设备上的悬停事件差异。
        property bool pointerInside: false
        readonly property bool visualHovered: item.enabled && item.pointerInside
        // 外观读数仍留在条目自身：调用方和测试一直按 Rectangle 那几个属性名读它们。
        property alias color: itemBackground.color
        property alias border: itemBackground.border
        property alias radius: itemBackground.radius
        signal clicked
        activeFocusOnTab: true
        // 焦点环只在键盘导航时出现。点击也取焦点是为了让 Tab 能从当前项继续，
        // 但 macOS 惯例里鼠标点击不该留下焦点环，否则每点一次侧栏就多一圈描边。
        readonly property bool showFocusRing: item.visualFocus
        Accessible.role: Accessible.Button
        Accessible.name: item.text + (item.statusText ? "，" + item.statusText : "")
        Accessible.onPressAction: item.clicked()
        Keys.onReturnPressed: item.clicked()
        Keys.onSpacePressed: item.clicked()

        function setPointerInside(inside) {
            item.pointerInside = item.enabled && inside;
        }

        objectName: "sidebarItem-" + item.marker
        Layout.fillWidth: true
        Layout.preferredHeight: 44
        padding: 0
        opacity: item.enabled ? 1.0 : 0.55
        // 侧边栏只用颜色和边框反馈，避免悬浮或选中时先出现阴影造成顿挫。
        layer.enabled: false

        background: Rectangle {
            id: itemBackground

            radius: Theme.radiusMd
            // 不能把非激活状态设为 transparent：Qt 的 transparent 是黑基透明，
            // hover 退场时 ColorAnimation 会插出灰色。白基透明只变化 alpha，能透出壁纸且不灰闪。
            color: item.isActive ? root.sidebarItemActiveColor : (item.visualHovered ? root.sidebarItemHoverColor : root.sidebarItemIdleColor)
            border.color: item.showFocusRing ? Theme.focusRing : item.isActive ? root.sidebarItemActiveBorderColor : (item.visualHovered ? root.sidebarItemHoverBorderColor : root.sidebarItemIdleBorderColor)
            border.width: item.showFocusRing ? 2 : (item.isActive || item.visualHovered ? 1 : 0)

            Behavior on color {
                ColorAnimation {
                    duration: Theme.reduceMotion ? 0 : 70
                    easing.type: Easing.OutQuad
                }
            }

            Behavior on border.color {
                ColorAnimation {
                    duration: Theme.reduceMotion ? 0 : 70
                    easing.type: Easing.OutQuad
                }
            }

            Behavior on border.width {
                NumberAnimation {
                    duration: Theme.reduceMotion ? 0 : 70
                    easing.type: Easing.OutQuad
                }
            }
        }

        onEnabledChanged: {
            if (!item.enabled) {
                item.pointerInside = false;
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.space8
            anchors.rightMargin: Theme.space8
            spacing: Theme.space8

            Rectangle {
                objectName: "sidebarMarker-" + item.marker
                Layout.preferredWidth: 22
                Layout.preferredHeight: 22
                radius: Theme.radiusSm
                color: item.isActive ? Theme.accentFill : Theme.glassCard

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.reduceMotion ? 0 : 70
                        easing.type: Easing.OutQuad
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: item.iconName.length === 0
                    text: item.marker
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Bold
                    color: item.isActive ? Theme.accentFillInk : Theme.inkSoft

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.reduceMotion ? 0 : 70
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                GlyphIcon {
                    anchors.centerIn: parent
                    visible: item.iconName.length > 0
                    name: item.iconName
                    size: 16
                    color: item.isActive ? Theme.accentFillInk : Theme.inkSoft
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    Layout.fillWidth: true
                    text: item.text
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontLg
                    font.weight: item.isActive ? Font.Medium : Font.Normal
                    color: item.isActive ? Theme.ink : Theme.inkSoft
                    elide: Text.ElideRight
                }

                RowLayout {
                    visible: item.statusText.length > 0
                    spacing: Theme.space4

                    Text {
                        id: statusPulse
                        objectName: "sidebarStatusPulse-" + item.marker

                        property bool pulseRunning: item.statusGlyph === "●"
                        readonly property bool pulseAnimationRunning: pulseAnimation.running

                        text: item.statusGlyph
                        textFormat: Text.PlainText
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.Medium
                        color: Theme.accentInk

                        SequentialAnimation on opacity {
                            id: pulseAnimation

                            running: statusPulse.pulseRunning
                                     && !root.reduceMotionActive
                                     && !Theme.reduceMotion
                            loops: Animation.Infinite

                            NumberAnimation {
                                from: 1.0
                                to: 0.35
                                duration: Theme.reduceMotion ? 0 : 620
                                easing.type: Easing.InOutQuad
                            }

                            NumberAnimation {
                                from: 0.35
                                to: 1.0
                                duration: Theme.reduceMotion ? 0 : 620
                                easing.type: Easing.InOutQuad
                            }

                            onRunningChanged: {
                                // 减少动效或状态变化都会停动画；停在半透明帧会像“禁用态”，所以回到不透明。
                                if (!running) {
                                    statusPulse.opacity = 1
                                }
                            }
                        }

                        onPulseRunningChanged: {
                            if (!statusPulse.pulseRunning) {
                                statusPulse.opacity = 1
                            }
                        }
                    }

                    Text {
                        objectName: "sidebarStatus-" + item.marker
                        text: item.statusTimeText
                        textFormat: Text.PlainText
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamilyClock
                        font.weight: Font.Medium
                        color: Theme.accentInk
                    }
                }
            }
        }

        MouseArea {
            id: mouseArea

            objectName: "sidebarHitArea-" + item.marker
            anchors.fill: parent
            hoverEnabled: true
            enabled: item.enabled
            cursorShape: Qt.PointingHandCursor
            onEntered: item.setPointerInside(true)
            onExited: item.setPointerInside(false)
            // 点击也取焦点，Tab 才能从当前项继续。焦点原因记成鼠标，visualFocus 随之为假，
            // 于是不会留下焦点环。
            // focusReason 要显式再写一次：对已经有焦点的项调 forceActiveFocus 是空操作，
            // 不会派发焦点事件，原因会停在上一次（比如先用 Tab 选中、再用鼠标点同一项）。
            onClicked: {
                item.forceActiveFocus(Qt.MouseFocusReason);
                item.focusReason = Qt.MouseFocusReason;
                item.clicked();
            }
        }

        HoverHandler {
            id: hoverHandler
            enabled: item.enabled
            // 某些 Qt/macOS 触控板路径可能绕过 MouseArea 的进入/离开事件。
            onHoveredChanged: item.setPointerInside(hovered)
        }
    }
}
