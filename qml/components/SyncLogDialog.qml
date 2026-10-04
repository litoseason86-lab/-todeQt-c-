pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 同步日志：两台设备同时改了同一处（以较晚的修改为准）、删除优先、同名科目合并、没能应用的记录，
// 以及读不懂的文件。只读：每一条写清楚留下了谁的、谁的没有生效，需要的话可以手动补回去。
// 冲突是自动处理的（你定的：不弹窗），这里是事后能查的地方。
Popup {
    id: root

    objectName: "syncLogDialog"

    property var syncControllerRef: null
    // 打开时读一次；开着的时候日志又有新记录（控制器发 logChanged），再读一次。
    property var entries: []

    function reload() {
        root.entries = root.syncControllerRef ? root.syncControllerRef.syncLog(200) : []
    }

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(560, parent ? Math.max(320, parent.width - 64) : 560)
    height: Math.min(600, parent ? Math.max(360, parent.height - 64) : 600)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    onOpened: {
        root.reload()
        closeButton.forceActiveFocus()
    }

    Connections {
        target: root.syncControllerRef
        ignoreUnknownSignals: true

        function onLogChanged() {
            if (root.opened)
                root.reload()
        }
    }

    enter: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "scale"
                from: 0.96
                to: 1
                duration: Theme.reduceMotion ? 0 : 180
                easing.type: Easing.OutQuad
            }
            OpacityAnimator {
                from: 0
                to: 1
                duration: Theme.reduceMotion ? 0 : 180
                easing.type: Easing.OutQuad
            }
        }
    }

    exit: Transition {
        OpacityAnimator {
            from: 1
            to: 0
            duration: Theme.reduceMotion ? 0 : 160
            easing.type: Easing.InQuad
        }
    }

    Overlay.modal: Rectangle {
        color: Theme.dialogScrim
    }

    background: Rectangle {
        implicitWidth: root.width
        implicitHeight: root.height
        radius: Theme.radiusMd
        color: Theme.glassDialog
        border.color: Theme.border
        border.width: 1
    }

    contentItem: ColumnLayout {
        spacing: Theme.space12

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 52
            radius: Theme.radiusMd
            color: Theme.surface

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Theme.space16
                text: "同步日志"
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontXl
                font.bold: true
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            text: "两台设备同时改了同一处时，以较晚的修改为准；删除优先于修改。被覆盖或被删除的备忘录文字可复制找回。只保留最近 500 条。"
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
            wrapMode: Text.Wrap
        }

        // 列表外面包一层始终可见的容器：列表和「还没有记录」按条目数切换显示，
        // 但占多大的地方始终由这一层决定，布局不会因为切换而跳动。
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16

            ListView {
                id: list

                objectName: "syncLogList"
                anchors.fill: parent
                clip: true
                spacing: Theme.space8
                model: root.entries
                visible: root.entries.length > 0
                boundsBehavior: Flickable.StopAtBounds
                Accessible.role: Accessible.List
                Accessible.name: "同步日志"

                ScrollBar.vertical: PageScrollBar {}

                delegate: Rectangle {
                    id: entry

                    required property var modelData
                    required property int index

                    objectName: "syncLogEntry" + index
                    width: ListView.view ? ListView.view.width - Theme.space12 : 0
                    implicitHeight: entryColumn.implicitHeight + Theme.space12 * 2
                    radius: Theme.radiusMd
                    color: Theme.surfaceRaised
                    border.color: Theme.borderSubtle
                    border.width: 1
                    Accessible.role: Accessible.ListItem
                    Accessible.name: entry.modelData.kindLabel + "，" + entry.modelData.title + "。" + entry.modelData.summary

                    ColumnLayout {
                        id: entryColumn

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.space12
                        spacing: Theme.space4

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space8

                            // 种类用文字标出来，不只靠颜色区分。
                            Rectangle {
                                implicitWidth: kindText.implicitWidth + Theme.space8 * 2
                                implicitHeight: kindText.implicitHeight + Theme.space4
                                radius: Theme.radiusSm
                                color: Theme.accentFill

                                Text {
                                    id: kindText

                                    anchors.centerIn: parent
                                    text: entry.modelData.kindLabel
                                    textFormat: Text.PlainText
                                    color: Theme.accentFillInk
                                    font.pixelSize: Theme.fontSm
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                text: entry.modelData.title
                                textFormat: Text.PlainText
                                color: Theme.inkStrong
                                font.pixelSize: Theme.fontMd
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                            }

                            Text {
                                text: entry.modelData.time
                                textFormat: Text.PlainText
                                color: Theme.inkSoft
                                font.pixelSize: Theme.fontSm
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: entry.modelData.summary
                            textFormat: Text.PlainText
                            color: Theme.ink
                            font.pixelSize: Theme.fontMd
                            wrapMode: Text.Wrap
                        }

                        // 按钮和「已复制」排成一行，按钮保持文字宽度；不要直接把按钮装进填满整行的 Loader，
                        // Loader 有了宽度会把装进来的按钮拉成一整条。
                        Loader {
                            active: Boolean(entry.modelData.canCopyLostValue)
                            sourceComponent: RowLayout {
                                id: copyRow

                                property bool copied: false

                                spacing: Theme.space8

                                PageActionButton {
                                    objectName: "syncLogCopyLostValue" + entry.index
                                    text: qsTr("复制被覆盖的内容")
                                    onClicked: {
                                        if (!root.syncControllerRef)
                                            return
                                        root.syncControllerRef.copyLostValue(String(entry.modelData.lostValue))
                                        copyRow.copied = true
                                        copiedReset.restart()
                                    }
                                }

                                // 复制成功的反馈就放在按钮旁边。用透明度显隐，提示出现、消失时按钮不会跳动。
                                // 不用悬浮提示条：弹窗打开之前它挂不到覆盖层上，结果从来没显示过。
                                Text {
                                    objectName: "syncLogCopied" + entry.index
                                    text: qsTr("已复制")
                                    textFormat: Text.PlainText
                                    color: Theme.inkSoft
                                    font.pixelSize: Theme.fontSm
                                    opacity: copyRow.copied ? 1 : 0
                                    Accessible.ignored: !copyRow.copied
                                }

                                Timer {
                                    id: copiedReset
                                    interval: 2000
                                    onTriggered: copyRow.copied = false
                                }
                            }
                        }
                    }
                }
            }

            Text {
                objectName: "syncLogEmpty"
                anchors.centerIn: parent
                width: parent.width
                visible: root.entries.length === 0
                text: "还没有记录。两台设备同时改了同一处、或者遇到读不懂的文件时，会记在这里。"
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontMd
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.bottomMargin: Theme.space16

            Item { Layout.fillWidth: true }

            Button {
                id: closeButton

                objectName: "syncLogCloseButton"
                text: "关闭"
                implicitWidth: 88
                implicitHeight: Theme.controlHeightMd
                activeFocusOnTab: true
                Accessible.name: "关闭同步日志"
                onClicked: root.close()

                background: Rectangle {
                    color: closeButton.hovered ? Theme.surfaceSunken : Theme.surfaceRaised
                    border.color: closeButton.activeFocus ? Theme.focusRing : Theme.border
                    border.width: closeButton.activeFocus ? 2 : 1
                    radius: Theme.radiusMd
                }
                contentItem: Text {
                    text: closeButton.text
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontMd
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }
}
