import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root

    signal focusEnded()

    property string errorText: ""

    function safeSeconds(value) {
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
        color: "#f5f0e6"

        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - 64, 460)
            spacing: 28

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    Layout.fillWidth: true
                    text: focusTimer.currentTaskTitle && focusTimer.currentTaskTitle.length > 0
                          ? focusTimer.currentTaskTitle
                          : "尚未开始专注"
                    font.pixelSize: 20
                    font.bold: true
                    color: "#5d4e37"
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                Text {
                    Layout.fillWidth: true
                    text: "当前任务"
                    font.pixelSize: 13
                    color: "#8b7355"
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            Text {
                Layout.fillWidth: true
                text: root.formatTime(focusTimer.elapsedSeconds)
                font.pixelSize: 64
                font.bold: true
                color: "#d4a574"
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                Layout.fillWidth: true
                text: focusTimer.isRunning ? "专注进行中" : "专注已暂停"
                font.pixelSize: 14
                color: "#8b7355"
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                Layout.fillWidth: true
                visible: root.errorText.length > 0
                text: root.errorText
                font.pixelSize: 13
                color: "#b24f3d"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 16

                Button {
                    id: pauseButton

                    text: focusTimer.isRunning ? "暂停" : "继续"
                    enabled: focusTimer.hasActiveSession
                    implicitWidth: 104
                    implicitHeight: 40

                    background: Rectangle {
                        color: pauseButton.enabled ? "#8b7355" : "#e8dfc8"
                        radius: 6
                    }

                    contentItem: Text {
                        text: pauseButton.text
                        color: pauseButton.enabled ? "#fffef9" : "#a0896b"
                        font.pixelSize: 14
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
                        color: stopButton.enabled ? "#d4a574" : "#e8dfc8"
                        radius: 6
                    }

                    contentItem: Text {
                        text: stopButton.text
                        color: stopButton.enabled ? "#fffef9" : "#a0896b"
                        font.pixelSize: 14
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
