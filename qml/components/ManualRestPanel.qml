import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 主动休息独立于番茄完成后的倒计时休息：它没有任务上下文，也不产生专注记录。
Item {
    id: root

    objectName: "manualRestPanel"

    property int elapsedSeconds: 0
    property bool isRunning: false

    signal pauseResumeRequested()
    signal endRequested()

    function formatTime(seconds) {
        var safe = Math.max(0, Number(seconds || 0))
        var hours = Math.floor(safe / 3600)
        var minutes = Math.floor((safe % 3600) / 60)
        var secs = safe % 60
        return (hours < 10 ? "0" : "") + hours + ":"
                + (minutes < 10 ? "0" : "") + minutes + ":"
                + (secs < 10 ? "0" : "") + secs
    }

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 96, 560)
        spacing: Theme.space24

        // 与自由专注共用“标题 + 状态 → 大号计时 → 辅助说明 → 操作”的信息层级，
        // 主动休息只通过语义色和文案区分，避免再套一层卡片造成页面风格断裂。
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.space8

            Text {
                objectName: "manualRestTitle"
                Layout.fillWidth: true
                text: qsTr("主动休息")
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontXl
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            Text {
                objectName: "manualRestStatus"
                Layout.fillWidth: true
                text: root.isRunning ? qsTr("休息进行中") : qsTr("休息已暂停")
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                horizontalAlignment: Text.AlignHCenter
            }
        }

        Text {
            objectName: "manualRestTime"
            Layout.fillWidth: true
            text: root.formatTime(root.elapsedSeconds)
            textFormat: Text.PlainText
            // chart 色只能给色块；这里使用休息色的文字版，浅色壁纸上仍满足可读性。
            color: Theme.focusBreakInk
            font.pixelSize: Theme.fontDisplay
            font.family: Theme.fontFamilyClock
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: Theme.space16

            Button {
                id: pauseResumeButton
                objectName: "manualRestPauseResumeButton"
                text: root.isRunning ? qsTr("暂停") : qsTr("继续")
                implicitWidth: 104
                implicitHeight: 40
                activeFocusOnTab: true
                onClicked: root.pauseResumeRequested()

                background: Rectangle {
                    color: Theme.inkSoft
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: pauseResumeButton.text
                    textFormat: Text.PlainText
                    color: Theme.surface
                    font.pixelSize: Theme.fontLg
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            Button {
                id: endButton
                objectName: "manualRestEndButton"
                text: qsTr("结束休息")
                implicitWidth: 104
                implicitHeight: 40
                activeFocusOnTab: true
                onClicked: root.endRequested()

                background: Rectangle {
                    color: Theme.accent
                    radius: Theme.radiusMd
                }

                contentItem: Text {
                    text: endButton.text
                    textFormat: Text.PlainText
                    color: Theme.surface
                    font.pixelSize: Theme.fontLg
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
