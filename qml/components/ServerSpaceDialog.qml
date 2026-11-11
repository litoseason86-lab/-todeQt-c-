pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."

// 建立同步空间：首次从 iCloud 改用自建服务器、以及服务器空间丢失后重建共用这一层。
// 网络请求与是否真正切换都由 SyncController 决定；这里只收集输入、显示进度与原因。
Popup {
    id: root

    objectName: "serverSpaceDialog"

    property var syncControllerRef: null
    property bool rebuilding: false
    // 重建时由设置页传入控制器的 serverUrl，完整保留协议、端口与路径。
    property string currentServerAddress: ""
    property bool submitted: false

    readonly property bool busy: root.syncControllerRef
                                      ? Boolean(root.syncControllerRef.switchingTransport) : false
    readonly property string problem: root.syncControllerRef
                                      && root.syncControllerRef.transportProblem !== undefined
                                      ? String(root.syncControllerRef.transportProblem) : ""
    readonly property string dialogTitle: root.rebuilding
                                          ? "重新建立同步空间"
                                          : "改用自建服务器同步"

    signal pairingRequested

    function openForMode(isRebuilding) {
        root.rebuilding = isRebuilding
        root.open()
    }

    function submit() {
        // 控制器通知期间 busy 绑定可能尚未刷新，准入必须直接读取控制器的切换状态。
        if (!root.syncControllerRef || root.syncControllerRef.switchingTransport)
            return
        root.submitted = true
        root.syncControllerRef.createServerSpace(
                    addressField.text.trim(),
                    enrollmentKeyField.text.trim())
    }

    modal: true
    focus: true
    closePolicy: root.busy ? Popup.NoAutoClose : Popup.CloseOnEscape
    width: Math.min(520, parent ? Math.max(340, parent.width - 64) : 520)
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
        addressField.text = root.rebuilding ? root.currentServerAddress : ""
        enrollmentKeyField.text = ""
        root.submitted = false
        addressField.forceActiveFocus()
    }

    onClosed: {
        // 注册口令只在本次建立请求里使用，关闭后不留在内存中的输入框里。
        enrollmentKeyField.text = ""
        root.submitted = false
    }

    Connections {
        target: root.syncControllerRef
        ignoreUnknownSignals: true

        // 明确成功信号在控制器收尾后发出，不再从几个派生属性的刷新先后推断成功。
        function onServerSpaceCreated() {
            if (root.opened && root.submitted) {
                root.submitted = false
                root.close()
                Qt.callLater(function () { root.pairingRequested() })
            }
        }
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
                objectName: "serverSpaceDialogTitle"
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Theme.space16
                text: root.dialogTitle
                textFormat: Text.PlainText
                color: Theme.inkStrong
                font.pixelSize: Theme.fontXl
                font.weight: Font.DemiBold
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }
        }

        DialogLabel {
            text: "服务器地址"
        }

        DialogField {
            id: addressField

            objectName: "serverSpaceAddressField"
            placeholderText: "https://…"
            readOnly: root.busy
            inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoPredictiveText
            Accessible.name: "服务器地址"
            onAccepted: enrollmentKeyField.forceActiveFocus()
        }

        DialogLabel {
            text: "注册口令"
        }

        DialogField {
            id: enrollmentKeyField

            objectName: "serverSpaceEnrollmentKeyField"
            echoMode: TextInput.Password
            readOnly: root.busy
            inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
            Accessible.name: "注册口令"
            // 与按钮共用提交入口，保留控制器切换中的重复请求守卫。
            onAccepted: root.submit()
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            text: "部署服务器时生成，只在建立同步空间时用一次，不保存在这台 Mac 上"
            textFormat: Text.PlainText
            color: Theme.inkSoft
            font.pixelSize: Theme.fontSm
            wrapMode: Text.Wrap
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            spacing: Theme.space4

            DialogBullet {
                text: "• 内容在这台 Mac 上加密，服务器只存密文"
            }
            DialogBullet {
                text: "• " + (root.rebuilding
                              ? "iPad 要输入新的配对码重新加入"
                              : "iPad 要输入配对码重新加入，加入时以这台 Mac 的数据为准（iPad 先自动备份）")
            }
            DialogBullet {
                visible: !root.rebuilding
                text: "• iCloud 云盘里原来的「番茄Todo同步」改名留着，不再使用"
            }
        }

        Text {
            objectName: "serverSpaceProblem"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space16
            Layout.rightMargin: Theme.space16
            visible: root.problem.length > 0
            text: root.problem
            textFormat: Text.PlainText
            color: Theme.danger
            font.pixelSize: Theme.fontMd
            wrapMode: Text.Wrap
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
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
                objectName: "serverSpaceCancelButton"
                text: "取消"
                enabled: !root.busy
                onClicked: root.close()
            }

            DialogButton {
                objectName: "serverSpaceSubmitButton"
                text: root.busy ? "正在建立…" : "建立并切换"
                primary: true
                enabled: !root.busy
                onClicked: root.submit()
            }
        }
    }

    component DialogLabel: Text {
        Layout.fillWidth: true
        Layout.leftMargin: Theme.space16
        Layout.rightMargin: Theme.space16
        Layout.topMargin: Theme.space4
        textFormat: Text.PlainText
        color: Theme.ink
        font.pixelSize: Theme.fontMd
        font.weight: Font.Medium
    }

    component DialogBullet: Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        color: Theme.inkSoft
        font.pixelSize: Theme.fontSm
        wrapMode: Text.Wrap
    }

    component DialogField: TextField {
        id: field

        Layout.fillWidth: true
        Layout.leftMargin: Theme.space16
        Layout.rightMargin: Theme.space16
        implicitHeight: Theme.controlHeightLg
        selectByMouse: true
        activeFocusOnTab: true

        background: Rectangle {
            color: Theme.surfaceSunken
            border.color: field.activeFocus ? Theme.focusRing : Theme.border
            border.width: field.activeFocus ? 2 : 1
            radius: Theme.radiusMd
        }
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
