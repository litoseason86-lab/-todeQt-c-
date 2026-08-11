pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import QtQuick.Layouts
import ".."
import "settings"

Popup {
    id: root

    property var appSettingsRef: null
    property var backupServiceRef: null
    property var shortcutRegistryRef: null
    property int currentSection: 0
    // 静息态留空：「设置将自动保存到本机」是一句永远为真的话，占一整行却零信息量。
    // 只有真正发生过写入（成功或失败）时这一行才有内容。
    property string statusText: ""
    property bool statusIsError: false
    property SettingsGeneralPage activeGeneralPage: null
    readonly property bool reduceMotion: appSettingsRef ? appSettingsRef.reduceMotion : false
    readonly property int animationDuration: reduceMotion ? 0 : 160
    readonly property var sectionTitles: ["外观", "专注", "通用", "快捷键", "数据与管理", "关于"]
    // 「快捷键速查」(⌘/) 要直接跳到这一页。从标题表里查出来而不是写死数字：
    // 以后再插一个分段时，写死的索引会静默指到隔壁页面去。
    readonly property int shortcutSectionIndex: sectionTitles.indexOf("快捷键")
    // 快捷键页正在等待用户按下新组合。此时应用内快捷键必须整体让路，
    // 否则按 ⌘1 会先被「切到仪表盘」吃掉，永远录不进去。
    property bool recordingShortcut: false
    readonly property bool compact: width < 680

    signal routineRequested
    signal categoryRequested
    signal exportRequested
    signal backupRequested
    signal restoreRequested

    modal: true
    focus: true
    // 关闭前必须提交昵称草稿；禁用 Popup 的绕过式自动关闭，Escape 和按钮统一走 requestClose()。
    closePolicy: Popup.NoAutoClose
    // 820 宽让外观页的主题画廊有余量、快捷键行不再挤；高度尽量吃满可用空间，
    // 因为专注/快捷键/数据三页的内容本来就超过一屏。
    width: parent ? Math.min(820, Math.max(0, parent.width - Theme.space32 * 2)) : 820
    height: parent ? Math.min(680, Math.max(0, parent.height - Theme.space32 * 2)) : 680
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: Theme.space16

    function requestSection(index) {
        if (index < 0 || index >= sectionTitles.length || index === currentSection) {
            return
        }
        // 通用页可能仍有正在编辑的文本，切页前先给当前页提交或拒绝切换的机会。
        if (activeGeneralPage && !activeGeneralPage.commitPendingEdits()) {
            return
        }
        currentSection = index
        Qt.callLater(root.resetPageScroll)
    }

    function resetPageScroll() {
        if (pageScroll.contentItem) {
            pageScroll.contentItem.contentY = 0
        }
    }

    function belongsToLoadedPage(item) {
        var current = item
        while (current) {
            if (current === pageLoader.item) {
                return true
            }
            current = current.parent
        }
        return false
    }

    function ensureFocusVisible(item) {
        if (!opened || !item || !pageLoader.item || !root.belongsToLoadedPage(item)
                || !pageScroll.contentItem) {
            return
        }

        var flickable = pageScroll.contentItem
        var point = item.mapToItem(pageLoader, 0, 0)
        var top = point.y - Theme.space8
        var bottom = point.y + item.height + Theme.space8
        if (top < flickable.contentY) {
            flickable.contentY = Math.max(0, top)
        } else if (bottom > flickable.contentY + flickable.height) {
            flickable.contentY = Math.min(
                        Math.max(0, flickable.contentHeight - flickable.height),
                        bottom - flickable.height)
        }
    }

    function requestClose() {
        if (activeGeneralPage && !activeGeneralPage.commitPendingEdits()) {
            return
        }
        close()
    }

    onOpened: resetPageScroll()

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 0.97
                to: 1
                duration: Theme.reduceMotion ? 0 : root.animationDuration
                easing.type: Easing.OutCubic
            }
            OpacityAnimator {
                from: 0
                to: 1
                duration: Theme.reduceMotion ? 0 : root.animationDuration
            }
        }
    }

    exit: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 1
                to: 0.97
                duration: Theme.reduceMotion ? 0 : root.animationDuration
            }
            OpacityAnimator {
                from: 1
                to: 0
                duration: Theme.reduceMotion ? 0 : root.animationDuration
            }
        }
    }

    Overlay.modal: Rectangle {
        color: Theme.dialogScrim
        opacity: root.opened ? 1 : 0

        Behavior on opacity {
            NumberAnimation { duration: Theme.reduceMotion ? 0 : root.animationDuration }
        }
    }

    background: Rectangle {
        id: panel

        objectName: "settingsDialogPanel"
        color: Theme.glassBlurAllowed ? Theme.glassDialogSoft : Theme.glassSolidCard
        border.color: Theme.glassBorder
        border.width: 1
        radius: Theme.radiusLg
        layer.enabled: Theme.glassBlurAllowed
        layer.effect: MultiEffect {
            autoPaddingEnabled: true
            shadowEnabled: true
            shadowColor: Theme.shadow
            shadowOpacity: 0.16
            shadowBlur: 0.22
            shadowVerticalOffset: 6
        }
    }

    contentItem: RowLayout {
        spacing: Theme.space16
        Keys.onEscapePressed: event => {
            root.requestClose()
            event.accepted = true
        }

        SettingsNavigation {
            Layout.preferredWidth: root.compact ? 168 : 204
            Layout.fillHeight: true
            currentIndex: root.currentSection
            compact: root.compact
            reduceMotion: root.reduceMotion
            onCategoryRequested: index => root.requestSection(index)
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            // 内容直接躺在对话框面板上（macOS 系统设置层次）；
            // Rectangle 保留为布局宿主，不再自带底色和描边。
            color: "transparent"
            radius: Theme.radiusLg

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.space16
                spacing: Theme.space12

                // 标题显示当前分页名而不是固定的「设置」：模态窗 + 左栏品牌区已经
                // 说明了这是设置，再写一次「设置」是第三层重复标题，白吃一行高度。
                // 换成分页名后这一行开始承担 wayfinding，与 macOS 系统设置一致。
                Text {
                    objectName: "settingsSectionTitle"
                    Layout.fillWidth: true
                    Layout.bottomMargin: Theme.space4
                    text: root.sectionTitles[root.currentSection]
                    textFormat: Text.PlainText
                    color: Theme.inkStrong
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.DemiBold
                    Accessible.role: Accessible.Heading
                    Accessible.name: text + "设置"
                }

                ScrollView {
                    id: pageScroll
                    objectName: "settingsPageScroll"

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: availableWidth
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                    Loader {
                        id: pageLoader

                        objectName: "settingsPageLoader"
                        width: pageScroll.availableWidth
                        sourceComponent: root.currentSection === 0 ? appearancePageComponent
                                       : root.currentSection === 1 ? focusPageComponent
                                       : root.currentSection === 2 ? generalPageComponent
                                       : root.currentSection === 3 ? shortcutsPageComponent
                                       : root.currentSection === 4 ? dataPageComponent
                                       : aboutPageComponent
                        onLoaded: {
                            if (item) {
                                item.appSettingsRef = Qt.binding(function() { return root.appSettingsRef })
                                item.compact = Qt.binding(function() { return root.compact })
                                // 数据页需要备份服务引用；其余页面没有该属性，跳过即可。
                                if (item.hasOwnProperty("backupServiceRef")) {
                                    item.backupServiceRef = Qt.binding(function() { return root.backupServiceRef })
                                }
                                // 快捷键页需要注册表引用；其余页面没有该属性，跳过即可。
                                if (item.hasOwnProperty("shortcutRegistryRef")) {
                                    item.shortcutRegistryRef = Qt.binding(function() { return root.shortcutRegistryRef })
                                }
                                // 关于页这类"内容少于一屏"的页面需要知道视口高度做垂直居中；
                                // 其余页面没有该属性，跳过即可。
                                if (item.hasOwnProperty("viewportHeight")) {
                                    item.viewportHeight = Qt.binding(function() { return pageScroll.height })
                                }
                            }
                        }
                    }
                }

                // 页脚分隔线：内容区与页脚原来直接相接，超出一屏的页面（专注/快捷键/数据）
                // 被齐平切断，看起来像渲染缺陷而不是"可以往下滚"。
                Rectangle {
                    objectName: "settingsFooterDivider"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: Theme.borderSubtle
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space12

                    Text {
                        objectName: "settingsStatusText"
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        text: root.statusText
                        textFormat: Text.PlainText
                        color: root.statusIsError ? Theme.danger : Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        elide: Text.ElideRight
                        Accessible.role: root.statusIsError
                                         ? Accessible.AlertMessage : Accessible.StaticText
                        Accessible.name: text
                        Accessible.ignored: text.length === 0
                    }

                    Button {
                        id: closeButton

                        objectName: "settingsCloseButton"
                        implicitHeight: 44
                        activeFocusOnTab: true
                        Accessible.name: "关闭设置"
                        onClicked: root.requestClose()

                        background: Rectangle {
                            implicitWidth: 92
                            color: closeButton.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
                            border.color: closeButton.activeFocus ? Theme.focusRing : Theme.border
                            border.width: closeButton.activeFocus ? 2 : 1
                            radius: Theme.radiusMd
                        }

                        contentItem: Text {
                            text: "关闭"
                            color: Theme.ink
                            font.pixelSize: Theme.fontLg
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }
        }
    }

    Connections {
        target: pageLoader.status === Loader.Ready ? pageLoader.item : null
        ignoreUnknownSignals: true

        function onRoutineRequested() {
            root.close()
            root.routineRequested()
        }
        function onCategoryRequested() {
            root.close()
            root.categoryRequested()
        }
        function onExportRequested() {
            root.close()
            root.exportRequested()
        }
        function onBackupRequested() {
            root.close()
            root.backupRequested()
        }
        function onRestoreRequested() {
            root.close()
            root.restoreRequested()
        }
    }

    Connections {
        // Popup 本身不在普通 Item 继承链上；从页内 Item 取得实际 QQuickWindow 才能收到焦点项变化。
        target: pageScroll.Window.window
        ignoreUnknownSignals: true

        function onActiveFocusItemChanged() {
            root.ensureFocusVisible(pageScroll.Window.window
                                    ? pageScroll.Window.window.activeFocusItem : null)
        }
    }

    Connections {
        target: root.appSettingsRef
        ignoreUnknownSignals: true

        function onSettingsWriteSucceeded(key) {
            root.statusIsError = false
            root.statusText = "所有设置已保存到本机"
        }

        function onSettingsWriteFailed(key, message) {
            // 后端错误详情可能随平台变化；界面给出稳定动作指引，错误态保持到下一次成功写入。
            root.statusIsError = true
            root.statusText = "无法保存设置，请检查系统权限后重试"
        }
    }

    Component { id: appearancePageComponent; SettingsAppearancePage {} }
    Component { id: focusPageComponent; SettingsFocusPage {} }
    Component {
        id: generalPageComponent

        SettingsGeneralPage {
            id: generalPage

            Component.onCompleted: {
                // Loader 只暴露 QObject 静态类型；具体页面注册强类型引用，壳层不猜测动态属性。
                root.activeGeneralPage = generalPage
            }
            Component.onDestruction: root.activeGeneralPage = null
        }
    }
    Component {
        id: shortcutsPageComponent

        SettingsShortcutsPage {
            // 录制态必须上抬到对话框：应用内 Shortcut 挂在 MainWindow 上，
            // 页面自己关不掉它们。
            onRecordingChanged: root.recordingShortcut = recording
            Component.onDestruction: root.recordingShortcut = false
        }
    }
    Component { id: dataPageComponent; SettingsDataPage {} }
    Component { id: aboutPageComponent; SettingsAboutPage {} }
}
