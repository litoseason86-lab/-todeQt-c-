pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Shapes
import ".."

// 给 iPad 的配对码。默认只显示前缀和固定数量的圆点，避免旁人一眼看到含密钥的完整内容。
Popup {
    id: root

    objectName: "pairingCodeDialog"

    property var syncControllerRef: null
    property string actualCode: ""
    property bool showCode: false
    property bool copied: false
    readonly property string maskedCode: "ptsync1.••••••••••••••••••••••••"
    readonly property string displayedCode: root.showCode ? root.actualCode : root.maskedCode

    function copyCode() {
        if (!root.syncControllerRef || root.actualCode.length === 0)
            return
        root.syncControllerRef.copyPairingCode()
        root.copied = true
        copiedReset.restart()
    }

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    width: Math.min(520, parent ? Math.max(360, parent.width - 64) : 520)
    height: panel.implicitHeight
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: parent ? Math.round((parent.height - height) / 2) : 0
    padding: 0

    palette.text: Theme.inputInk
    palette.placeholderText: Theme.inputPlaceholderInk
    palette.highlight: Theme.inputSelection
    palette.highlightedText: Theme.inputSelectedInk
    palette.window: Theme.inputPopupSurface
    palette.mid: Theme.inputPopupBorder
    palette.light: Theme.inputPopupHighlight
    palette.midlight: Theme.inputPopupHighlight
    palette.base: Theme.controlSurface
    palette.button: Theme.controlSurface
    palette.buttonText: Theme.controlInk
    palette.windowText: Theme.controlInk

    onOpened: {
        root.actualCode = root.syncControllerRef ? String(root.syncControllerRef.pairingCode()) : ""
        root.showCode = false
        root.copied = false
        doneButton.forceActiveFocus()
    }

    onClosed: {
        root.showCode = false
        root.copied = false
        copiedReset.stop()
    }

    Overlay.modal: Rectangle {
        color: Theme.dialogScrim
    }

    background: Rectangle {
        id: panel

        implicitWidth: root.width
        implicitHeight: contentColumn.implicitHeight
        color: Theme.glassDialog
        border.color: Theme.border
        border.width: 1
        radius: Theme.radiusLg
    }

    contentItem: ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space12

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 48
            color: Theme.surface
            radius: Theme.radiusMd

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Theme.space16
                text: "给 iPad 的配对码"
                textFormat: Text.PlainText
                color: Theme.inkStrong
                font.pixelSize: Theme.fontXl
                font.weight: Font.DemiBold
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.minimumHeight: 52
            color: Theme.surfaceSunken
            border.color: Theme.border
            border.width: 1
            radius: Theme.radiusMd

            RowLayout {
                anchors.fill: parent
                anchors.margins: Theme.space12
                spacing: Theme.space8

                Text {
                    id: codeText

                    objectName: "pairingCodeValue"
                    Layout.fillWidth: true
                    text: root.displayedCode
                    textFormat: Text.PlainText
                    color: Theme.inkStrong
                    font.family: "Menlo"
                    font.pixelSize: Theme.fontMd
                    wrapMode: Text.WrapAnywhere
                    Accessible.name: root.showCode ? "配对码已显示" : "配对码已隐藏"
                }

                Button {
                    id: revealButton

                    objectName: "pairingCodeRevealButton"
                    implicitWidth: 34
                    implicitHeight: 34
                    padding: 0
                    activeFocusOnTab: true
                    enabled: root.actualCode.length > 0
                    Accessible.name: root.showCode ? "隐藏配对码" : "显示配对码"
                    onClicked: root.showCode = !root.showCode

                    background: Rectangle {
                        color: revealButton.hovered ? Theme.surfaceRaised : "transparent"
                        border.color: revealButton.visualFocus ? Theme.focusRing : "transparent"
                        border.width: revealButton.visualFocus ? 2 : 0
                        radius: Theme.radiusMd
                    }

                    contentItem: Item {
                        id: eyeIcon

                        implicitWidth: 22
                        implicitHeight: 22

                        Shape {
                            anchors.centerIn: parent
                            width: 22
                            height: 22

                            ShapePath {
                                strokeColor: revealButton.hovered ? Theme.accentInk : Theme.ink
                                strokeWidth: 1.8
                                fillColor: "transparent"
                                capStyle: ShapePath.RoundCap
                                joinStyle: ShapePath.RoundJoin
                                PathMove { x: 2.5; y: 11 }
                                PathQuad { controlX: 11; controlY: 3.5; x: 19.5; y: 11 }
                                PathQuad { controlX: 11; controlY: 18.5; x: 2.5; y: 11 }
                            }

                            ShapePath {
                                strokeColor: revealButton.hovered ? Theme.accentInk : Theme.ink
                                strokeWidth: 1.8
                                fillColor: "transparent"
                                PathAngleArc {
                                    centerX: 11
                                    centerY: 11
                                    radiusX: 3.2
                                    radiusY: 3.2
                                    startAngle: 0
                                    sweepAngle: 360
                                }
                            }
                        }

                        Shape {
                            anchors.centerIn: parent
                            width: 22
                            height: 22
                            visible: !root.showCode

                            ShapePath {
                                strokeColor: revealButton.hovered ? Theme.accentInk : Theme.ink
                                strokeWidth: 1.8
                                fillColor: "transparent"
                                capStyle: ShapePath.RoundCap
                                PathMove { x: 3.5; y: 3.5 }
                                PathLine { x: 18.5; y: 18.5 }
                            }
                        }
                    }

                    ThemedToolTip {
                        text: revealButton.Accessible.name
                        visible: revealButton.hovered && revealButton.enabled
                    }
                }
            }
        }

        Text {
            objectName: "pairingCodeDescription"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            text: "在 iPad 的「设置 › 同步 › 输入配对码」里粘贴。配对码里有解密密钥，只给自己的设备，别截图、别发给别人。"
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontMd
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            Layout.topMargin: Theme.space4
            Layout.bottomMargin: Theme.space16
            spacing: Theme.space12

            Item { Layout.fillWidth: true }

            DialogButton {
                id: doneButton

                objectName: "pairingCodeDoneButton"
                text: "完成"
                onClicked: root.close()
            }

            DialogButton {
                objectName: "pairingCodeCopyButton"
                text: root.copied ? "已复制" : "复制配对码"
                primary: true
                enabled: root.actualCode.length > 0
                onClicked: root.copyCode()
            }
        }
    }

    Timer {
        id: copiedReset

        interval: 2000
        repeat: false
        onTriggered: root.copied = false
    }

    component DialogButton: Button {
        id: button

        property bool primary: false

        implicitHeight: Theme.controlHeightMd
        leftPadding: Theme.space16
        rightPadding: Theme.space16
        activeFocusOnTab: true
        Accessible.name: text

        background: Rectangle {
            implicitWidth: button.primary ? 112 : 80
            color: button.primary
                   ? (button.hovered ? Theme.accentFillStrong : Theme.accentFill)
                   : (button.hovered ? Theme.surfaceSunken : Theme.surfaceRaised)
            border.color: button.visualFocus ? Theme.focusRing
                          : (button.primary ? "transparent" : Theme.border)
            border.width: button.visualFocus ? 2 : 1
            radius: Theme.radiusMd
            opacity: button.enabled ? 1 : 0.5
        }

        contentItem: Text {
            text: button.text
            textFormat: Text.PlainText
            color: button.primary ? Theme.accentFillInk : Theme.ink
            font.pixelSize: Theme.fontMd
            font.weight: button.primary ? Font.Medium : Font.Normal
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }
}
