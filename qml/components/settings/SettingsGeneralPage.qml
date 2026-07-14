import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../.."

FocusScope {
    id: root

    objectName: "settingsGeneralPage"
    property var appSettingsRef: null
    property bool compact: false
    property string nicknameDraft: appSettingsRef ? appSettingsRef.nickname : ""

    implicitHeight: contentColumn.implicitHeight

    function commitPendingEdits() {
        var normalized = nicknameDraft.trim()
        if (!appSettingsRef || normalized === appSettingsRef.nickname) {
            nicknameDraft = normalized
            return true
        }

        // AppSettings 写失败时会回滚旧值；用回读结果判定提交是否真实落盘，失败则保留草稿。
        appSettingsRef.nickname = normalized
        if (appSettingsRef.nickname === normalized) {
            nicknameDraft = normalized
            return true
        }
        return false
    }

    onAppSettingsRefChanged: {
        if (!nicknameField.activeFocus) {
            nicknameDraft = appSettingsRef ? appSettingsRef.nickname : ""
        }
    }

    ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space24

        SettingsSection {
            title: "个人化"
            description: "昵称只用于首页问候，不会上传或同步。"

            SettingsRow {
                label: "昵称"
                caption: "留空时使用默认问候"
                compact: root.compact

                TextField {
                    id: nicknameField

                    objectName: "settingsNicknameField"
                    implicitWidth: root.compact ? 150 : 190
                    implicitHeight: 44
                    text: root.nicknameDraft
                    placeholderText: "例如：小番茄"
                    maximumLength: 24
                    selectByMouse: true
                    activeFocusOnTab: true
                    Accessible.name: "昵称"
                    onTextEdited: root.nicknameDraft = text
                    onEditingFinished: root.commitPendingEdits()

                    background: Rectangle {
                        color: Theme.surfaceSunken
                        border.color: nicknameField.activeFocus ? Theme.accent : Theme.border
                        border.width: nicknameField.activeFocus ? 2 : 1
                        radius: Theme.radiusMd
                    }
                }
            }
        }

        SettingsSection {
            title: "日期口径"
            description: "凌晨时段仍可计入前一天，适合晚睡习惯。修改后任务与统计会立即按新日界刷新。"

            SettingsRow {
                label: "一天开始于"
                caption: "可设置 00:00–06:00"
                compact: root.compact

                DurationStepper {
                    namePrefix: "settingsDayStart"
                    accessibleName: "一天开始时间"
                    value: root.appSettingsRef ? root.appSettingsRef.dayStartHour : 4
                    from: 0
                    to: 6
                    onAdjusted: newValue => {
                        if (root.appSettingsRef) {
                            root.appSettingsRef.dayStartHour = newValue
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: "当前逻辑日从 %1:00 开始".arg(
                          root.appSettingsRef ? root.appSettingsRef.dayStartHour : 4)
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                wrapMode: Text.WordWrap
            }
        }
    }
}
