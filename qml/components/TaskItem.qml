import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    Layout.fillWidth: true
    // compact：仪表盘「已完成」等只读列表用更矮的行高，避免每张卡都占 76 的执行态高度。
    implicitHeight: Math.max(root.compact ? 48 : 76, content.implicitHeight + (root.compact ? 16 : 28))
    radius: Theme.radiusLg
    color: root.itemHovered ? Theme.glassHover : Theme.glassCard
    border.color: root.itemHovered ? Theme.accent : Theme.border
    border.width: root.itemHovered ? 1.5 : 1
    // MultiEffect 的阴影参数不直接承载动画，先放到 root 属性上过渡，再绑定给效果。
    property color warmShadowColor: Theme.ink
    // compact 行阴影压轻一档，列表密排时不互相发灰。
    property real warmShadowOpacity: root.compact ? (root.itemHovered ? 0.08 : 0.05)
                                                  : (root.itemHovered ? 0.12 : 0.08)
    property real warmShadowBlur: root.compact ? (root.itemHovered ? 0.16 : 0.12)
                                               : (root.itemHovered ? 0.25 : 0.18)
    property real warmShadowVerticalOffset: root.compact ? (root.itemHovered ? 3 : 1)
                                                         : (root.itemHovered ? 6 : 2)
    // 图层生命周期必须稳定：hover 事件分发期间切换 layer.enabled 会重建效果项，
    // Qt Quick 此时仍在递归遍历命中树，可能继续访问已释放的 QQuickItem。
    layer.enabled: true
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: root.warmShadowColor
        shadowOpacity: root.warmShadowOpacity
        shadowBlur: root.warmShadowBlur
        shadowHorizontalOffset: 0
        shadowVerticalOffset: root.warmShadowVerticalOffset
    }

    property int taskId: 0
    property string taskTitle: ""
    property var taskCategory: ""
    property bool taskCompleted: false
    property bool visualTaskCompleted: false
    property bool titleEditing: false
    // 父视图负责判断任务是否允许开始专注；TaskItem 只消费结果，避免把日期规则塞进通用任务项。
    property bool startFocusAllowed: true
    // 父视图负责决定这个任务是否属于“执行态”；历史和未来任务不露出执行入口。
    property bool showStartFocus: true
    // 父视图控制编辑/删除入口；仪表盘已完成筛选为纯查看，关掉后右侧改放状态徽章。
    property bool showEditDelete: true
    // 紧凑只读行：标题单行省略、分类横排、行高更矮，专供仪表盘已完成列表等。
    property bool compact: false
    // 显式记录指针状态，避免不同平台的 MouseArea/HoverHandler 事件差异影响 hover 视觉。
    property bool pointerInside: false
    property bool componentReady: false
    property bool completionAnimationPlayed: false
    property real completionOffset: 0
    readonly property bool itemHovered: root.pointerInside
    // 视图可能传入标准化科目对象，也可能传入旧版字符串科目。
    readonly property string categoryName: typeof taskCategory === "object" ? (taskCategory && taskCategory.name ? taskCategory.name : "") : String(taskCategory || "")
    readonly property string categoryColor: typeof taskCategory === "object" ? (taskCategory && taskCategory.color ? taskCategory.color : "") : ""

    signal completionChanged(int taskId, bool completed)
    signal startFocusClicked(int taskId, string title)
    signal deleteClicked(int taskId, string title)
    signal renameSubmitted(int taskId, string newTitle)
    signal editClicked(int taskId)

    function setPointerInside(inside) {
        root.pointerInside = inside;
    }

    function beginTitleEdit() {
        root.titleEditing = true;
        titleEditField.text = root.taskTitle;
        titleEditField.forceActiveFocus();
        titleEditField.selectAll();
    }

    function commitTitleEdit() {
        var newTitle = titleEditField.text.trim();
        root.titleEditing = false;
        // 空标题或未修改都当作取消，避免无意义刷新和空标题打到服务层。
        if (newTitle.length === 0 || newTitle === root.taskTitle) {
            return;
        }
        root.renameSubmitted(root.taskId, newTitle);
    }

    function cancelTitleEdit() {
        root.titleEditing = false;
    }

    function playCompletionAnimation() {
        if (root.completionAnimationPlayed)
            return;
        if (completionParticles.particleCount > 0)
            return;

        root.completionAnimationPlayed = true;

        // 原点必须留在 TaskItem：只有这里知道复选框的真实位置，粒子组件只负责按坐标播放。
        var indicatorPosition = checkIndicator.mapToItem(root, 0, 0);
        var startX = indicatorPosition.x + checkIndicator.width / 2 - 2.5;
        var startY = indicatorPosition.y + checkIndicator.height / 2 - 2.5;
        completionParticles.burst(startX, startY);
    }

    onTaskCompletedChanged: {
        if (!root.componentReady) {
            // 初始数据可能直接带着已完成状态进来，此时不播放庆祝动画，只记录状态边界。
            root.visualTaskCompleted = root.taskCompleted;
            root.completionAnimationPlayed = root.taskCompleted;
            return;
        }

        root.visualTaskCompleted = root.taskCompleted;
        if (root.taskCompleted) {
            root.playCompletionAnimation();
        } else {
            // 取消完成后必须重置，下一次重新勾选才允许再次播放庆祝动画。
            root.completionAnimationPlayed = false;
        }
    }

    Component.onCompleted: {
        root.visualTaskCompleted = root.taskCompleted;
        root.componentReady = true;
        root.completionAnimationPlayed = root.taskCompleted;
    }

    states: [
        // 完成状态只做轻微位移和透明度变化，避免影响相邻任务布局。
        // compact 完成态不再下沉位移：密排列表里 5px 偏移会显得参差不齐。
        State {
            name: "normal"
            when: !root.visualTaskCompleted
            PropertyChanges {
                root.opacity: 1.0
                root.completionOffset: 0
            }
        },
        State {
            name: "completed"
            when: root.visualTaskCompleted
            PropertyChanges {
                root.opacity: root.compact ? 0.88 : 0.70
                root.completionOffset: root.compact ? 0 : 5
            }
        }
    ]

    transitions: [
        Transition {
            from: "normal"
            to: "completed"

            ParallelAnimation {
                OpacityAnimator {
                    target: root
                    duration: 200
                    easing.type: Easing.OutQuad
                }

                NumberAnimation {
                    target: root
                    property: "completionOffset"
                    duration: 200
                    easing.type: Easing.OutQuad
                }
            }
        },
        Transition {
            from: "completed"
            to: "normal"

            ParallelAnimation {
                OpacityAnimator {
                    target: root
                    duration: 150
                    easing.type: Easing.InQuad
                }

                NumberAnimation {
                    target: root
                    property: "completionOffset"
                    duration: 150
                    easing.type: Easing.InQuad
                }
            }
        }
    ]

    Behavior on color {
        ColorAnimation {
            duration: 180
            easing.type: Easing.OutQuad
        }
    }

    Behavior on border.color {
        ColorAnimation {
            duration: 180
            easing.type: Easing.OutQuad
        }
    }

    Behavior on border.width {
        NumberAnimation {
            duration: 180
            easing.type: Easing.OutQuad
        }
    }

    Behavior on warmShadowOpacity {
        NumberAnimation {
            duration: 200
            easing.type: Easing.OutQuad
        }
    }

    Behavior on warmShadowBlur {
        NumberAnimation {
            duration: 200
            easing.type: Easing.OutQuad
        }
    }

    Behavior on warmShadowVerticalOffset {
        NumberAnimation {
            duration: 200
            easing.type: Easing.OutQuad
        }
    }

    Behavior on opacity {
        OpacityAnimator {
            duration: 180
            easing.type: Easing.OutQuad
        }
    }

    MouseArea {
        id: hoverArea

        // 这里只处理视觉悬停；按钮和复选框各自处理点击。
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onEntered: root.setPointerInside(true)
        onExited: root.setPointerInside(false)
    }

    HoverHandler {
        id: hoverHandler

        // HoverHandler 补足触控板或平台事件路径，MouseArea 仍负责原有视觉悬停边界。
        onHoveredChanged: root.setPointerInside(hovered)
    }

    CompletionParticles {
        id: completionParticles

        anchors.fill: parent
    }

    RowLayout {
        id: content

        anchors.fill: parent
        anchors.leftMargin: root.compact ? Theme.space8 : Theme.space12
        anchors.rightMargin: root.compact ? Theme.space8 : Theme.space12
        anchors.topMargin: (root.compact ? Theme.space8 : Theme.space12) + root.completionOffset
        anchors.bottomMargin: root.compact ? Theme.space8 : Theme.space12
        spacing: root.compact ? Theme.space8 : Theme.space12

        CheckBox {
            id: checkbox

            objectName: "taskCheckBox"
            Layout.preferredWidth: 28
            Layout.preferredHeight: root.compact ? 28 : 40
            Layout.alignment: Qt.AlignVCenter
            padding: 0
            checked: root.visualTaskCompleted
            onClicked: {
                if (checked) {
                    // 真实点击路径会先进入这里，再由外层同步更新数据源；先切换视觉态并播放动画，
                    // 避免等待 model 回写时 delegate 已被刷新销毁。
                    root.visualTaskCompleted = true;
                    root.playCompletionAnimation();
                } else {
                    root.visualTaskCompleted = false;
                    root.completionAnimationPlayed = false;
                }
                root.completionChanged(root.taskId, checked);
            }

            indicator: Rectangle {
                id: checkIndicator

                objectName: "taskCheckIndicator"
                implicitWidth: root.compact ? 18 : 20
                implicitHeight: root.compact ? 18 : 20
                x: checkbox.leftPadding
                y: (checkbox.height - height) / 2
                radius: Theme.radiusSm
                color: checkbox.checked ? Theme.accent : "transparent"
                border.color: checkbox.hovered ? Theme.accent : Theme.border
                border.width: checkbox.hovered ? 2 : 1.5

                Text {
                    anchors.centerIn: parent
                    text: "✓"
                    visible: checkbox.checked
                    color: Theme.surface
                    font.pixelSize: root.compact ? Theme.fontMd : Theme.fontLg
                    font.weight: Font.Bold
                }

                Behavior on color {
                    ColorAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.color {
                    ColorAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.width {
                    NumberAnimation {
                        duration: 180
                        easing.type: Easing.OutQuad
                    }
                }
            }

            contentItem: Item {
                implicitWidth: 0
                implicitHeight: 0
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: root.compact ? 2 : Theme.space4

            // compact：标题与分类同一视觉行族，标题单行省略，避免完成列表被长标题撑得参差。
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space8
                visible: !root.titleEditing

                Text {
                    objectName: "taskTitleText"
                    Layout.fillWidth: true
                    text: root.taskTitle
                    font.pixelSize: root.compact ? Theme.fontMd : Theme.fontLg
                    font.weight: Font.Medium
                    lineHeight: root.compact ? 1.2 : 1.4
                    color: root.visualTaskCompleted ? Theme.inkSoft : Theme.inkStrong
                    font.strikeout: root.visualTaskCompleted
                    wrapMode: root.compact ? Text.NoWrap : Text.WordWrap
                    elide: root.compact ? Text.ElideRight : Text.ElideNone
                    maximumLineCount: root.compact ? 1 : 0

                    TapHandler {
                        enabled: root.showEditDelete
                        acceptedButtons: Qt.LeftButton
                        onDoubleTapped: root.beginTitleEdit()
                    }

                    Behavior on color {
                        ColorAnimation {
                            duration: 180
                            easing.type: Easing.OutQuad
                        }
                    }
                }

                // compact 且有分类：色点 + 名横排在标题右侧，省掉第二行高度。
                RowLayout {
                    visible: root.compact && root.categoryName.length > 0
                    spacing: 4
                    Layout.alignment: Qt.AlignVCenter

                    Rectangle {
                        Layout.preferredWidth: 8
                        Layout.preferredHeight: 8
                        radius: 4
                        visible: root.categoryColor.length > 0
                        color: root.categoryColor
                    }

                    Text {
                        objectName: "taskCategoryInline"
                        text: root.categoryName
                        textFormat: Text.PlainText
                        font.pixelSize: Theme.fontXs
                        color: Theme.inkMuted
                        elide: Text.ElideRight
                        Layout.maximumWidth: 88
                    }
                }
            }

            TextField {
                id: titleEditField

                objectName: "taskTitleEditField"
                Layout.fillWidth: true
                visible: root.titleEditing
                font.pixelSize: Theme.fontLg
                color: Theme.inkStrong
                selectByMouse: true

                background: Rectangle {
                    color: Theme.surface
                    border.color: Theme.accent
                    border.width: 1
                    radius: Theme.radiusSm
                }

                Keys.onReturnPressed: root.commitTitleEdit()
                Keys.onEnterPressed: root.commitTitleEdit()
                Keys.onEscapePressed: root.cancelTitleEdit()
                onActiveFocusChanged: {
                    // 失焦等同取消，避免列表中残留半编辑状态。
                    if (!activeFocus && root.titleEditing) {
                        root.cancelTitleEdit();
                    }
                }
            }

            // 非 compact：分类仍独占第二行，与今日任务页执行态一致。
            RowLayout {
                Layout.fillWidth: true
                visible: !root.compact && root.categoryName.length > 0
                spacing: Theme.space8

                Rectangle {
                    Layout.preferredWidth: root.categoryColor.length > 0 ? 12 : 0
                    Layout.preferredHeight: 12
                    radius: Theme.radiusSm
                    visible: root.categoryColor.length > 0
                    color: root.categoryColor
                }

                Text {
                    Layout.fillWidth: true
                    text: root.categoryName
                    font.pixelSize: Theme.fontSm
                    color: Theme.inkSoft
                    elide: Text.ElideRight
                }
            }
        }

        Button {
            id: focusButton

            objectName: "focusButton"
            text: root.visualTaskCompleted ? "已完成" : "开始专注"
            visible: root.showStartFocus && !root.visualTaskCompleted
            enabled: !root.visualTaskCompleted && root.startFocusAllowed
            // 与仪表盘 DashboardTimerPanel 主按钮同尺寸，避免两处“开始专注”视觉规格漂移。
            implicitWidth: 104
            implicitHeight: 34
            // down 是 Qt Controls 的视觉按下态；真实点击会同步 pressed，测试可稳定驱动 down。
            readonly property bool pressFeedbackActive: focusButton.enabled && (focusButton.down || focusButton.pressed)

            // 与仪表盘专注按钮同一玻璃基底：glassCard 半透明底 + 玻璃描边 + 受光棱边；
            // 悬停加实一档、按下用强调玻璃反馈，不再用大块实心焦糖。
            // 嵌在任务卡玻璃上，关掉落影避免阴影叠层发灰。
            background: GlassPanel {
                id: focusButtonBackground

                objectName: "focusButtonBackground"
                color: {
                    if (!focusButton.enabled)
                        return Theme.border
                    if (focusButton.pressFeedbackActive)
                        return Theme.glassAccent
                    if (focusButton.hovered)
                        return Theme.glassHover
                    return Theme.glassCard
                }
                panelShadowEnabled: false

                Behavior on color {
                    ColorAnimation {
                        duration: 160
                        easing.type: Easing.OutQuad
                    }
                }
            }

            contentItem: Text {
                objectName: "focusButtonLabel"
                text: focusButton.text
                // accentInk：浅/深主题下都可读的强调字色，配玻璃底而不是实心焦糖上的 surface 白字。
                color: focusButton.enabled ? Theme.accentInk : Theme.inkMuted
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }

            onClicked: {
                if (root.startFocusAllowed)
                    root.startFocusClicked(root.taskId, root.taskTitle)
            }
        }

        // 纯查看完成态：右侧固定「已完成」玻璃徽章，填补开始专注/编辑/删除腾出的空洞。
        GlassPanel {
            objectName: "taskCompletedBadge"
            visible: root.visualTaskCompleted && !root.showEditDelete
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: completedBadgeLabel.implicitWidth + Theme.space12
            implicitHeight: root.compact ? 24 : 28
            radius: Theme.radiusMd
            color: Theme.glassAccent
            specularEnabled: false
            panelShadowEnabled: false

            Text {
                id: completedBadgeLabel
                anchors.centerIn: parent
                text: "已完成"
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontXs
                font.weight: Font.Medium
                color: Theme.accentInk
            }
        }

        Button {
            id: editButton

            objectName: "taskEditButton"
            text: "编辑"
            visible: root.showEditDelete
            implicitWidth: 48
            implicitHeight: root.compact ? 30 : 36
            opacity: 1
            enabled: true

            background: Rectangle {
                radius: Theme.radiusMd
                color: editButton.hovered ? Theme.surfaceSunken : "transparent"
                border.color: editButton.hovered ? Theme.accent : Theme.border
                border.width: 1
            }

            contentItem: Text {
                text: editButton.text
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }

            onClicked: root.editClicked(root.taskId)
        }

        Button {
            id: deleteButton

            objectName: "taskDeleteButton"
            text: "删除"
            visible: root.showEditDelete
            implicitWidth: 48
            implicitHeight: root.compact ? 30 : 36
            opacity: 1
            enabled: true
            readonly property bool pressFeedbackActive: deleteButton.down || deleteButton.pressed

            background: Rectangle {
                id: taskDeleteButtonBackground

                objectName: "taskDeleteButtonBackground"
                radius: Theme.radiusMd
                y: deleteButton.pressFeedbackActive ? 1 : 0
                color: {
                    if (deleteButton.pressFeedbackActive)
                        return Theme.accentSoft;
                    if (deleteButton.hovered)
                        return Theme.surfaceSunken;
                    return "transparent";
                }
                border.color: deleteButton.hovered || deleteButton.pressFeedbackActive ? Theme.dangerSoft : Theme.border
                border.width: 1
                property color warmShadowColor: Theme.ink
                property real warmShadowOpacity: deleteButton.pressFeedbackActive ? 0.04 : 0.08
                property real warmShadowBlur: deleteButton.pressFeedbackActive ? 0.10 : 0.14
                property real warmShadowVerticalOffset: deleteButton.pressFeedbackActive ? 1 : 2
                // 按钮 hover/按下期间只改阴影参数，不改变效果层生命周期。
                layer.enabled: true
                layer.effect: MultiEffect {
                    autoPaddingEnabled: true
                    shadowEnabled: true
                    shadowColor: taskDeleteButtonBackground.warmShadowColor
                    shadowOpacity: taskDeleteButtonBackground.warmShadowOpacity
                    shadowBlur: taskDeleteButtonBackground.warmShadowBlur
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: taskDeleteButtonBackground.warmShadowVerticalOffset
                }

                Behavior on color {
                    ColorAnimation {
                        duration: 160
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on border.color {
                    ColorAnimation {
                        duration: 160
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on y {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on warmShadowOpacity {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on warmShadowBlur {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }

                Behavior on warmShadowVerticalOffset {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }
            }

            contentItem: Text {
                objectName: "taskDeleteButtonLabel"
                text: deleteButton.text
                color: Theme.dangerSoft
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                scale: deleteButton.pressFeedbackActive ? 0.98 : 1.0
                transformOrigin: Item.Center

                Behavior on scale {
                    NumberAnimation {
                        duration: 90
                        easing.type: Easing.OutQuad
                    }
                }
            }

            onClicked: root.deleteClicked(root.taskId, root.taskTitle)
        }
    }
}
