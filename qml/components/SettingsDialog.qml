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
    readonly property bool reduceMotion: appSettingsRef ? appSettingsRef.reduceMotion : false
    readonly property int animationDuration: reduceMotion ? 0 : 160
    readonly property var sectionTitles: ["外观", "专注", "通用", "数据与管理", "关于"]
    readonly property bool compact: width < 680

    signal routineRequested
    signal categoryRequested
    signal exportRequested

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
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
        if (pageLoader.status === Loader.Ready && pageLoader.item
                && typeof pageLoader.item.commitPendingEdits === "function"
                && !pageLoader.item.commitPendingEdits()) {
            return
        }
        currentSection = index
    }

    function requestClose() {
        if (pageLoader.status === Loader.Ready && pageLoader.item
                && typeof pageLoader.item.commitPendingEdits === "function"
                && !pageLoader.item.commitPendingEdits()) {
            return
        }
        close()
    }

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

    contentItem: ColumnLayout {
        spacing: Theme.space12

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space12

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                Text {
                    text: root.sectionTitles[root.currentSection]
                    color: Theme.inkStrong
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.DemiBold
                }

                Text {
                    text: "调整番茄 Todo 在这台 Mac 上的行为"
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                }
            }

            Button {
                id: closeButton

                objectName: "settingsCloseButton"
                implicitWidth: 44
                implicitHeight: 44
                text: "×"
                activeFocusOnTab: true
                Accessible.name: "关闭设置"
                onClicked: root.requestClose()

                background: Rectangle {
                    color: closeButton.hovered ? Theme.surfaceSunken : "transparent"
                    border.color: closeButton.activeFocus ? Theme.accent : Theme.borderSubtle
                    border.width: 1
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: closeButton.text
                    color: Theme.ink
                    font.pixelSize: Theme.fontXl
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Theme.space16

            SettingsNavigation {
                Layout.preferredWidth: root.compact ? 148 : 168
                Layout.fillHeight: true
                currentIndex: root.currentSection
                compact: root.compact
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
                    spacing: Theme.space8

                    ScrollView {
                        id: pageScroll

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

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 1
                        color: Theme.borderSubtle
                    }

                    Text {
                        objectName: "settingsStatusText"
                        Layout.fillWidth: true
                        text: root.statusText
                        color: Theme.inkSoft
                        font.pixelSize: Theme.fontMd
                        elide: Text.ElideRight
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

    Component { id: appearancePageComponent; SettingsAppearancePage {} }
    Component { id: focusPageComponent; SettingsFocusPage {} }
    Component { id: generalPageComponent; SettingsGeneralPage {} }
    Component { id: dataPageComponent; SettingsDataPage {} }
    Component { id: aboutPageComponent; SettingsAboutPage {} }
}
