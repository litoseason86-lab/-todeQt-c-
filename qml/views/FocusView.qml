import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import ".."

Item {
    id: root

    signal focusEnded()

    property string errorText: ""

    function safeSeconds(value) {
        // 计时显示只接受非负秒数，避免服务异常值污染 UI。
        return Math.max(0, Number(value || 0))
    }

    function formatTime(seconds) {
        var safe = root.safeSeconds(seconds)
        var hours = Math.floor(safe / 3600)
        var minutes = Math.floor((safe % 3600) / 60)
        var secs = safe % 60
        return (hours < 10 ? "0" : "") + hours + ":"
                + (minutes < 10 ? "0" : "") + minutes + ":"
                + (secs < 10 ? "0" : "") + secs
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.surfaceSunken

        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - 64, 460)
            spacing: Theme.space24

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.space8

                Text {
                    Layout.fillWidth: true
                    text: focusTimer.currentTaskTitle && focusTimer.currentTaskTitle.length > 0
                          ? focusTimer.currentTaskTitle
                          : "尚未开始专注"
                    font.pixelSize: Theme.fontXl
                    font.bold: true
                    color: Theme.ink
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                Text {
                    Layout.fillWidth: true
                    text: "当前任务"
                    font.pixelSize: Theme.fontMd
                    color: Theme.inkSoft
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            Text {
                Layout.fillWidth: true
                text: root.formatTime(focusTimer.elapsedSeconds)
                font.pixelSize: Theme.fontDisplay
                font.bold: true
                color: Theme.accent
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                Layout.fillWidth: true
                text: focusTimer.isRunning ? "专注进行中" : "专注已暂停"
                font.pixelSize: Theme.fontLg
                color: Theme.inkSoft
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                Layout.fillWidth: true
                visible: root.errorText.length > 0
                text: root.errorText
                font.pixelSize: Theme.fontMd
                color: Theme.danger
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: Theme.space16

                Button {
                    id: pauseButton

                    text: focusTimer.isRunning ? "暂停" : "继续"
                    enabled: focusTimer.hasActiveSession
                    implicitWidth: 104
                    implicitHeight: 40

                    background: Rectangle {
                        color: pauseButton.enabled ? Theme.inkSoft : Theme.border
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: pauseButton.text
                        color: pauseButton.enabled ? Theme.surface : Theme.inkMuted
                        font.pixelSize: Theme.fontLg
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    onClicked: {
                        if (focusTimer.isRunning) {
                            focusTimer.pauseFocus()
                        } else {
                            if (!focusTimer.resumeFocus()) {
                                root.errorText = "专注恢复失败"
                            } else {
                                root.errorText = ""
                            }
                        }
                    }
                }

                Button {
                    id: stopButton

                    text: "结束专注"
                    enabled: focusTimer.hasActiveSession
                    implicitWidth: 104
                    implicitHeight: 40

                    background: Rectangle {
                        color: stopButton.enabled ? Theme.accent : Theme.border
                        radius: Theme.radiusMd
                    }

                    contentItem: Text {
                        text: stopButton.text
                        color: stopButton.enabled ? Theme.surface : Theme.inkMuted
                        font.pixelSize: Theme.fontLg
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    onClicked: {
                        if (focusTimer.stopFocus()) {
                            root.errorText = ""
                            root.focusEnded()
                        } else {
                            root.errorText = "专注保存失败，请重试"
                        }
                    }
                }
            }
        }
    }
}
