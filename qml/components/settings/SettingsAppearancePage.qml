import QtQuick
import QtQuick.Layouts
import "../.."

FocusScope {
    id: root

    objectName: "settingsAppearancePage"
    property var appSettingsRef: null
    property bool compact: false

    implicitHeight: contentColumn.implicitHeight

    ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space24

        SettingsSection {
            title: "背景主题"
            description: "选择背景时会立即预览并保存。深色主题会同步提高文字与控件对比度。"

            GridLayout {
                Layout.fillWidth: true
                columns: root.compact ? 2 : 3
                columnSpacing: Theme.space8
                rowSpacing: Theme.space8

                Repeater {
                    id: themeRepeater

                    objectName: "settingsThemeRepeater"
                    model: Theme.themes

                    delegate: SettingsThemeChoice {
                        required property var modelData

                        Layout.fillWidth: true
                        appSettingsRef: root.appSettingsRef
                        themeId: modelData.id
                        themeName: modelData.name
                        themeMode: modelData.mode
                    }
                }
            }
        }

        SettingsSection {
            title: "显示"

            SettingsRow {
                label: "减少动效"
                caption: "关闭弹窗、开关与页面切换中的非必要动画"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsReduceMotionSwitch"
                    text: "减少动效"
                    checked: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
                    reduceMotion: checked
                    onToggled: {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.reduceMotion = checked
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            SettingsRow {
                label: "纤细计时字体"
                caption: "专注页使用更轻的数字字重"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsSlimClockFontSwitch"
                    text: "纤细计时字体"
                    checked: root.appSettingsRef ? root.appSettingsRef.slimClockFont : true
                    reduceMotion: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
                    onToggled: {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.slimClockFont = checked
                        }
                    }
                }
            }
        }
    }
}
