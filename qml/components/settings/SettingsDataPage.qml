pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import ".."
import "../.."

FocusScope {
    id: root

    objectName: "settingsDataPage"
    property var appSettingsRef: null
    property var backupServiceRef: null
    property var mcpAccessRef: null
    property bool compact: false
    readonly property bool backupBusy: root.backupServiceRef
                                       ? root.backupServiceRef.busy : false
    signal routineRequested
    signal categoryRequested
    signal exportRequested
    signal backupRequested
    signal restoreRequested

    // 最近备份时间说明；无备份服务或从未备份时给出中性文案。
    readonly property string lastBackupCaption: {
        if (!root.backupServiceRef)
            return "开启后每周自动备份一次，保留最近 4 份"
        if (root.backupBusy)
            return root.backupServiceRef.operationText || "正在处理数据"
        var iso = root.backupServiceRef.lastBackupTimeIso
        if (!iso || iso.length === 0)
            return "尚未自动备份；开启后每周备份一次，保留最近 4 份"
        var d = new Date(iso)
        return "最近备份：" + Qt.formatDateTime(d, "yyyy-MM-dd HH:mm")
    }

    implicitHeight: contentColumn.implicitHeight

    ColumnLayout {
        id: contentColumn

        width: root.width
        spacing: Theme.space24

        SettingsSection {
            title: "外部 AI 接入"
            description: "通过本机 MCP 客户端读取任务、专注统计和知识缺口。应用需保持运行；同一 macOS 账户内的进程共享接入权限。"

            SettingsRow {
                label: "允许外部 AI 接入"
                caption: "默认关闭；关闭后立即断开连接并使旧会话失效"
                iconName: "layers"
                compact: root.compact
                SettingsSwitch {
                    objectName: "settingsMcpEnabled"
                    text: "允许外部 AI 接入"
                    persistedChecked: root.mcpAccessRef ? root.mcpAccessRef.enabled : false
                    enabled: Boolean(root.mcpAccessRef)
                    reduceMotion: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
                    onChangeRequested: value => { if (root.mcpAccessRef) root.mcpAccessRef.setEnabled(value) }
                }
            }
            SettingsRow {
                label: "允许 AI 修改任务"
                caption: "开启后可新建、编辑、改期和设置完成状态，不逐条确认"
                iconName: "edit"
                compact: root.compact
                SettingsSwitch {
                    objectName: "settingsMcpWriteEnabled"
                    text: "允许 AI 修改任务"
                    persistedChecked: root.mcpAccessRef ? root.mcpAccessRef.writeEnabled : false
                    enabled: Boolean(root.mcpAccessRef && root.mcpAccessRef.enabled)
                    reduceMotion: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
                    onChangeRequested: value => { if (root.mcpAccessRef) root.mcpAccessRef.setWriteEnabled(value) }
                }
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                color: Theme.inkMuted
                font.pixelSize: Theme.fontSm
                text: "备注和知识缺口可能含有外部粘贴的指令。AI 可能误信这些内容并修改任务；仅向可信客户端开放写权限。接入策略只保存在本机，不随备份恢复。"
            }
            Label {
                objectName: "settingsMcpStatus"
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                color: Theme.ink
                font.pixelSize: Theme.fontSm
                text: root.mcpAccessRef ? ((root.mcpAccessRef.listening ? "正在监听 · 连接数 " + root.mcpAccessRef.connectionCount : "未监听")
                       + "\n" + root.mcpAccessRef.blockSummary
                       + (root.mcpAccessRef.lastOperation ? "\n最近操作：" + root.mcpAccessRef.lastOperation : "")
                       + (root.mcpAccessRef.lastError ? "\n" + root.mcpAccessRef.lastError : "")) : "接入服务未装配"
                Accessible.name: text
            }
            ManageButton {
                objectName: "settingsMcpCopyPath"
                text: "复制 MCP 辅助程序路径"
                caption: root.mcpAccessRef ? root.mcpAccessRef.helperPath : "接入服务未装配"
                iconName: "data"
                enabled: Boolean(root.mcpAccessRef)
                onClicked: { if (root.mcpAccessRef) root.mcpAccessRef.copyHelperPath() }
            }
        }

        SettingsSection {
            title: "管理"
            description: "这些入口会关闭设置，并打开对应的管理窗口。"

            ManageButton {
                objectName: "settingsManageRoutine"
                text: "每日例行"
                caption: "管理自动生成的重复任务"
                iconName: "calendar"
                onClicked: root.routineRequested()
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            ManageButton {
                objectName: "settingsManageCategory"
                text: "科目管理"
                caption: "维护任务分类、名称和颜色"
                iconName: "grid"
                onClicked: root.categoryRequested()
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            ManageButton {
                objectName: "settingsManageExport"
                text: "数据导出"
                caption: "把任务与专注记录导出为本机文件"
                iconName: "export"
                onClicked: root.exportRequested()
            }
        }

        SettingsSection {
            title: "数据备份与恢复"
            description: "备份是含任务、专注记录、倒计时目标与偏好的完整单文件快照。可自行放入 iCloud 云盘或移动硬盘长期保存；恢复会替换当前全部数据。"

            ManageButton {
                objectName: "settingsBackupNow"
                text: "立即备份"
                caption: "把全部数据保存为一个备份文件"
                iconName: "layers"
                enabled: !root.backupBusy
                onClicked: root.backupRequested()
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            ManageButton {
                objectName: "settingsRestoreBackup"
                text: "从备份恢复"
                caption: "用备份文件替换当前全部数据（会先自动备份当前数据）"
                iconName: "sunrise"
                enabled: !root.backupBusy
                onClicked: root.restoreRequested()
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            ManageButton {
                objectName: "settingsOpenBackupFolder"
                text: "打开备份文件夹"
                caption: "在访达中查看自动与手动备份"
                iconName: "data"
                enabled: !root.backupBusy
                onClicked: {
                    if (root.backupServiceRef)
                        root.backupServiceRef.openBackupsFolder()
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            SettingsRow {
                label: "自动备份"
                caption: root.lastBackupCaption
                iconName: "round"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsAutoBackupSwitch"
                    text: "自动备份"
                    persistedChecked: root.backupServiceRef ? root.backupServiceRef.autoBackupEnabled : true
                    reduceMotion: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
                    enabled: !root.backupBusy
                    onChangeRequested: enabled => {
                        if (root.backupServiceRef)
                            root.backupServiceRef.autoBackupEnabled = enabled
                    }
                }
            }
        }
    }

    component ManageButton: Button {
        id: control

        required property string caption
        required property string iconName

        Layout.fillWidth: true
        // 与 SettingsRow 对齐：44 是可点目标的无障碍下限，两行文字自然长到 ~52px。
        implicitHeight: 52
        activeFocusOnTab: true
        Accessible.name: text
        Accessible.description: caption

        background: Rectangle {
            color: control.hovered ? Theme.surfaceSunken : "transparent"
            border.color: control.activeFocus ? Theme.focusRing : "transparent"
            border.width: control.activeFocus ? 2 : 0
            radius: Theme.radiusMd
        }

        contentItem: RowLayout {
            spacing: Theme.space12

            // 与 SettingsRow 同一个取舍：图标不再套浅色圆角方块。那层色块在每一行
            // 重复出现，是零信息量的装饰，却主导了整页的视觉噪音。
            GlyphIcon {
                Layout.leftMargin: Theme.space4
                Layout.preferredWidth: 20
                Layout.preferredHeight: 20
                Layout.alignment: Qt.AlignVCenter
                name: control.iconName
                size: 20
                color: Theme.inkSoft
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Text {
                    Layout.fillWidth: true
                    text: control.text
                    textFormat: Text.PlainText
                    color: Theme.ink
                    font.pixelSize: Theme.fontLg
                }

                Text {
                    Layout.fillWidth: true
                    text: control.caption
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontMd
                    elide: Text.ElideRight
                }
            }

            Text {
                text: "›"
                color: Theme.inkSoft
                font.pixelSize: Theme.fontXl
            }
        }
    }
}
