import QtQuick
import QtQuick.Layouts
import ".."
import "../.."

FocusScope {
    id: root

    objectName: "settingsFocusPage"
    property var appSettingsRef: null
    property bool compact: false

    implicitHeight: contentColumn.implicitHeight

    ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space24

        SettingsSection {
            title: "番茄计时"
            description: "这里调整的是新一轮专注的默认值，不会改动正在进行的计时。"

            SettingsRow {
                label: "专注时长"
                caption: "5–180 分钟"
                compact: root.compact

                DurationStepper {
                    namePrefix: "settingsWorkMinutes"
                    accessibleName: "专注时长"
                    value: root.appSettingsRef ? root.appSettingsRef.workMinutes : 25
                    from: 5
                    to: 180
                    onAdjusted: newValue => {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.workMinutes = newValue
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
                label: "休息时长"
                caption: "1–60 分钟"
                compact: root.compact

                DurationStepper {
                    namePrefix: "settingsBreakMinutes"
                    accessibleName: "休息时长"
                    value: root.appSettingsRef ? root.appSettingsRef.breakMinutes : 5
                    from: 1
                    to: 60
                    onAdjusted: newValue => {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.breakMinutes = newValue
                        }
                    }
                }
            }
        }

        SettingsSection {
            title: "提醒"

            SettingsRow {
                label: "阶段完成提示音"
                caption: "专注或休息结束时播放系统提示音"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsSoundSwitch"
                    text: "阶段完成提示音"
                    checked: root.appSettingsRef ? root.appSettingsRef.soundEnabled : true
                    reduceMotion: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
                    onToggled: {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.soundEnabled = checked
                        }
                    }
                }
            }
        }
    }
}
