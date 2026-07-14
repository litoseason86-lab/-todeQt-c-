import QtQuick
import QtQuick.Layouts
import ".."
import "../.."

FocusScope {
    id: root

    objectName: "settingsFocusPage"
    property var appSettingsRef: null
    property bool compact: false
    readonly property bool longBreakOn: appSettingsRef ? appSettingsRef.longBreakEnabled : true

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
                iconName: "target"
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
                iconName: "pause"
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

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            SettingsRow {
                label: "长休息"
                caption: "每完成若干个番茄后休息更久"
                iconName: "moon"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsLongBreakSwitch"
                    text: "长休息"
                    checked: root.longBreakOn
                    reduceMotion: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
                    onToggled: {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.longBreakEnabled = checked
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
                visible: root.longBreakOn
            }

            SettingsRow {
                label: "长休息时长"
                caption: "5–60 分钟"
                iconName: "moon"
                compact: root.compact
                visible: root.longBreakOn

                DurationStepper {
                    namePrefix: "settingsLongBreakMinutes"
                    accessibleName: "长休息时长"
                    value: root.appSettingsRef ? root.appSettingsRef.longBreakMinutes : 15
                    from: 5
                    to: 60
                    onAdjusted: newValue => {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.longBreakMinutes = newValue
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
                visible: root.longBreakOn
            }

            SettingsRow {
                label: "长休息间隔"
                caption: "每 2–8 个番茄一次"
                iconName: "hash"
                compact: root.compact
                visible: root.longBreakOn

                DurationStepper {
                    namePrefix: "settingsLongBreakInterval"
                    accessibleName: "长休息间隔"
                    unit: "个"
                    value: root.appSettingsRef ? root.appSettingsRef.longBreakInterval : 4
                    from: 2
                    to: 8
                    onAdjusted: newValue => {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.longBreakInterval = newValue
                        }
                    }
                }
            }
        }

        SettingsSection {
            title: "自动衔接"
            description: "开启后阶段结束会自动进入下一段，不必手动点击。"

            SettingsRow {
                label: "自动开始休息"
                caption: "专注结束后自动进入休息"
                iconName: "play"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsAutoStartBreakSwitch"
                    text: "自动开始休息"
                    checked: root.appSettingsRef ? root.appSettingsRef.autoStartBreak : false
                    reduceMotion: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
                    onToggled: {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.autoStartBreak = checked
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
                label: "休息后自动开始下一个番茄"
                caption: "休息结束后接着上一个任务继续专注"
                iconName: "next"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsAutoStartNextSwitch"
                    text: "休息后自动开始下一个番茄"
                    checked: root.appSettingsRef ? root.appSettingsRef.autoStartNextPomodoro : false
                    reduceMotion: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
                    onToggled: {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.autoStartNextPomodoro = checked
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
                iconName: "bell"
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

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            SettingsRow {
                label: "阶段结束时窗口置前"
                caption: "把窗口带到最前提醒切换；关掉则仅靠提示音"
                iconName: "front"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsRaiseOnPhaseSwitch"
                    text: "阶段结束时窗口置前"
                    checked: root.appSettingsRef ? root.appSettingsRef.raiseOnPhaseComplete : true
                    reduceMotion: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
                    onToggled: {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.raiseOnPhaseComplete = checked
                        }
                    }
                }
            }
        }
    }
}
