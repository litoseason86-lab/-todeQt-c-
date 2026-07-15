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
    property int currentSection: 0
    property string statusText: "设置将自动保存到本机"
    property bool statusIsError: false
    property SettingsGeneralPage activeGeneralPage: null
    readonly property bool reduceMotion: appSettingsRef ? appSettingsRef.reduceMotion : false
    readonly property int animationDuration: reduceMotion ? 0 : 160
    readonly property var sectionTitles: ["外观", "专注", "通用", "数据与管理", "关于"]
    readonly property bool compact: width < 680

    signal routineRequested
    signal categoryRequested
    signal exportRequested

    modal: true
    focus: true
    // 关闭前必须提交昵称草稿；禁用 Popup 的绕过式自动关闭，Escape 和按钮统一走 requestClose()。
    closePolicy: Popup.NoAutoClose
    width: parent ? Math.min(760, Math.max(0, parent.width - Theme.space32 * 2)) : 760
    height: parent ? Math.min(640, Math.max(0, parent.height - Theme.space32 * 2)) : 640
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
                duration: root.animationDuration
                easing.type: Easing.OutCubic
            }
            OpacityAnimator {
                from: 0
                to: 1
                duration: root.animationDuration
            }
        }
    }

    exit: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 1
                to: 0.97
                duration: root.animationDuration
            }
            OpacityAnimator {
                from: 1
                to: 0
                duration: root.animationDuration
            }
        }
    }

    Overlay.modal: Rectangle {
        color: "#8c000000"
        opacity: root.opened ? 1 : 0

        Behavior on opacity {
            NumberAnimation { duration: root.animationDuration }
        }
    }

    background: Rectangle {
        id: panel

        objectName: "settingsDialogPanel"
        color: Theme.glassBlurAllowed ? Theme.glassDialog : Theme.glassSolidCard
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
            color: Theme.surface
            border.color: Theme.borderSubtle
            border.width: 1
            radius: Theme.radiusLg

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.space16
                spacing: Theme.space12

                Text {
                    Layout.fillWidth: true
                    text: "设置"
                    color: Theme.inkStrong
                    font.pixelSize: Theme.fontXxl
                    font.weight: Font.Bold
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
                                       : root.currentSection === 3 ? dataPageComponent
                                       : aboutPageComponent
                        onLoaded: {
                            if (item) {
                                item.appSettingsRef = Qt.binding(function() { return root.appSettingsRef })
                                item.compact = Qt.binding(function() { return root.compact })
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space12

                    Text {
                        objectName: "settingsStatusText"
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        text: root.statusText
                        color: root.statusIsError ? Theme.danger : Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        elide: Text.ElideRight
                        Accessible.role: root.statusIsError
                                         ? Accessible.AlertMessage : Accessible.StaticText
                        Accessible.name: text
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
    Component { id: dataPageComponent; SettingsDataPage {} }
    Component { id: aboutPageComponent; SettingsAboutPage {} }
}
