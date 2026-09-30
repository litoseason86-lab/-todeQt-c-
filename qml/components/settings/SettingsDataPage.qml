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
    property var syncControllerRef: null
    property bool compact: false
    readonly property bool backupBusy: root.backupServiceRef
                                       ? root.backupServiceRef.busy : false
    signal routineRequested
    signal categoryRequested
    signal exportRequested
    signal backupRequested
    signal restoreRequested
    signal syncLogRequested

    // 同步的几个派生状态。控制器可能没装配（独立实例化的测试），这时一律按「关着」处理。
    readonly property bool syncEnabled: root.syncControllerRef ? root.syncControllerRef.enabled : false
    readonly property string syncStatusKey: root.syncControllerRef ? root.syncControllerRef.statusKey : "stopped"
    readonly property bool syncHasProblem: root.syncControllerRef ? root.syncControllerRef.hasProblem : false
    readonly property bool syncChoosesFolder: root.syncControllerRef ? root.syncControllerRef.choosesFolder : false
    readonly property bool syncChoosingFolder: root.syncControllerRef ? root.syncControllerRef.choosingFolder : false
    // 需要把完整说明摆出来的时候：等你确认加入、还在等数据传过来，以及各种没走通的情况。
    // 已同步、已关闭这些，设置行里的一句话就够了。
    readonly property bool syncShowsExplanation: root.syncEnabled
                                                 && (root.syncStatusKey === "needsConfirmation"
                                                     || root.syncStatusKey === "waitingForSnapshot"
                                                     || root.syncHasProblem)

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
            objectName: "settingsSyncSection"
            title: "设备间同步"
            description: "通过 iCloud 云盘里的「番茄Todo同步」文件夹，在这台设备和另一台设备之间同步任务、科目、每日例行、专注与休息记录，以及「一天开始于」。课表、知识缺口和倒计时暂不同步。两边改了同一处时，以较晚的修改为准，被覆盖的内容记在同步日志里。"

            SettingsRow {
                label: "同步"
                caption: root.syncControllerRef ? root.syncControllerRef.summaryText : "同步服务未装配"
                iconName: "sync"
                compact: root.compact

                SettingsSwitch {
                    objectName: "settingsSyncSwitch"
                    text: "同步"
                    persistedChecked: root.syncEnabled
                    // 正在选文件夹或校验时不让再点：iPad 上打开同步就是先去选文件夹。
                    enabled: Boolean(root.syncControllerRef) && !root.syncChoosingFolder
                    reduceMotion: root.appSettingsRef ? root.appSettingsRef.reduceMotion : false
                    onChangeRequested: value => { if (root.syncControllerRef) root.syncControllerRef.setEnabled(value) }
                }
            }

            // 完整说明与要你做的决定。放在开关正下方：打开同步之后第一眼就能看到还差哪一步。
            ColumnLayout {
                objectName: "settingsSyncExplanation"
                Layout.fillWidth: true
                Layout.leftMargin: 20 + Theme.space12
                Layout.bottomMargin: Theme.space12
                visible: root.syncShowsExplanation
                spacing: Theme.space8

                Text {
                    objectName: "settingsSyncStatusText"
                    Layout.fillWidth: true
                    text: root.syncControllerRef ? root.syncControllerRef.statusText : ""
                    textFormat: Text.PlainText
                    // 出了问题用提醒色；说明文字本身写清楚发生了什么，不只靠颜色。
                    color: root.syncHasProblem ? Theme.danger : Theme.ink
                    font.pixelSize: Theme.fontMd
                    wrapMode: Text.Wrap
                    Accessible.role: root.syncHasProblem ? Accessible.AlertMessage : Accessible.StaticText
                    Accessible.name: text
                }

                Text {
                    objectName: "settingsSyncStatusDetail"
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: root.syncControllerRef ? root.syncControllerRef.statusDetail : ""
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                    wrapMode: Text.Wrap
                }

                RowLayout {
                    visible: root.syncStatusKey === "needsConfirmation"
                    spacing: Theme.space12

                    SyncActionButton {
                        objectName: "settingsSyncConfirmJoin"
                        text: "确认加入"
                        primary: true
                        Accessible.description: "本机数据先自动备份，再换成同步文件夹里的数据"
                        onClicked: { if (root.syncControllerRef) root.syncControllerRef.confirmJoin() }
                    }
                    SyncActionButton {
                        objectName: "settingsSyncDeclineJoin"
                        text: "暂不加入"
                        Accessible.description: "关闭同步，本机数据不变"
                        onClicked: { if (root.syncControllerRef) root.syncControllerRef.setEnabled(false) }
                    }
                }

                SyncActionButton {
                    objectName: "settingsSyncRebuild"
                    visible: root.syncStatusKey === "folderMissing"
                    text: root.syncChoosesFolder ? "重新选择文件夹" : "重新建立同步文件夹"
                    primary: true
                    Accessible.description: root.syncChoosesFolder
                                            ? "在「文件」里重新选 iCloud 云盘里的「番茄Todo同步」"
                                            : "在 iCloud 云盘里建一个新的同步文件夹，另一台设备要重新选择它"
                    onClicked: { if (root.syncControllerRef) root.syncControllerRef.rebuildFolder() }
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.syncStatusKey === "folderMissing" && !root.syncChoosesFolder
                    text: "重新建立后是一个新的同步文件夹，iPad 要在设置里重新选择它，并确认加入。"
                    textFormat: Text.PlainText
                    color: Theme.inkSoft
                    font.pixelSize: Theme.fontSm
                    wrapMode: Text.Wrap
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            // iPad 要自己在「文件」里选同步文件夹；Mac 的位置固定，只显示在哪。
            ManageButton {
                objectName: "settingsSyncChooseFolder"
                visible: root.syncChoosesFolder
                text: "同步文件夹"
                caption: {
                    if (!root.syncControllerRef)
                        return ""
                    if (root.syncChoosingFolder)
                        return "正在检查选中的文件夹…"
                    return root.syncControllerRef.hasFolder
                            ? root.syncControllerRef.folderDisplayPath
                            : "还没有选择：请选 iCloud 云盘里 Mac 建好的「番茄Todo同步」"
                }
                iconName: "folder"
                enabled: Boolean(root.syncControllerRef) && !root.syncChoosingFolder
                onClicked: { if (root.syncControllerRef) root.syncControllerRef.chooseFolder() }
            }

            SettingsRow {
                visible: !root.syncChoosesFolder
                label: "同步文件夹"
                caption: root.syncControllerRef ? root.syncControllerRef.folderDisplayPath : ""
                iconName: "folder"
                compact: root.compact
            }

            // 选中的文件夹没用上（选错了哪一层、读不了）：就地说明，原来的文件夹照常用。
            // 只在 iPad 出现，紧跟在「同步文件夹」按钮下面，和按钮里的文字对齐：
            // 按钮左内边距 8 + 图标缩进 4 + 图标 20 + 间距 12。
            Text {
                objectName: "settingsSyncFolderProblem"
                Layout.fillWidth: true
                Layout.leftMargin: 8 + Theme.space4 + 20 + Theme.space12
                Layout.bottomMargin: Theme.space8
                visible: text.length > 0
                text: root.syncControllerRef ? root.syncControllerRef.folderProblem : ""
                textFormat: Text.PlainText
                color: Theme.danger
                font.pixelSize: Theme.fontMd
                wrapMode: Text.Wrap
                Accessible.role: Accessible.AlertMessage
                Accessible.name: text
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            ManageButton {
                objectName: "settingsSyncNow"
                text: "立即同步"
                // 不显示「正在同步」：Mac 每 20 秒在后台同步一轮，这行字会跟着来回闪。
                // 点了之后，设置行里「已同步 · 时刻」会更新，那就是反馈。
                caption: {
                    if (!root.syncEnabled || !root.syncControllerRef)
                        return "打开同步后才能用"
                    var pending = root.syncControllerRef.pendingCount
                    return pending > 0 ? "还有 " + pending + " 条改动等着发出" : "没有等着发出的改动"
                }
                iconName: "sync"
                enabled: root.syncEnabled && !root.syncChoosingFolder
                onClicked: { if (root.syncControllerRef) root.syncControllerRef.syncNow() }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.borderSubtle
            }

            ManageButton {
                objectName: "settingsSyncLog"
                text: "同步日志"
                caption: {
                    var count = root.syncControllerRef ? root.syncControllerRef.logCount : 0
                    return count > 0 ? count + " 条：两边同时修改、删除优先和读不懂的文件"
                                     : "还没有记录"
                }
                iconName: "list"
                enabled: Boolean(root.syncControllerRef)
                onClicked: root.syncLogRequested()
            }
        }

        SettingsSection {
            title: "外部 AI 接入"
            description: "通过本机 MCP 客户端读取任务、专注统计和知识缺口。应用需保持运行；同一 macOS 账户内的进程共享接入权限。"

            SettingsRow {
                label: "允许外部 AI 接入"
                caption: "默认关闭；关闭后立即断开连接、使旧会话失效，并一并撤销任务写入权限"
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

    // 同步说明里的操作按钮：主操作用强调色填充，次要操作用描边；两者都有文字，不只靠颜色区分。
    component SyncActionButton: Button {
        id: action

        property bool primary: false

        implicitHeight: Theme.controlHeightMd
        leftPadding: Theme.space16
        rightPadding: Theme.space16
        activeFocusOnTab: true
        Accessible.name: text

        background: Rectangle {
            implicitWidth: 96
            color: action.primary ? (action.hovered ? Theme.accentFillStrong : Theme.accentFill)
                                  : (action.hovered ? Theme.surfaceSunken : Theme.surfaceRaised)
            border.color: action.activeFocus ? Theme.focusRing : (action.primary ? "transparent" : Theme.border)
            border.width: action.activeFocus ? 2 : 1
            radius: Theme.radiusMd
            opacity: action.enabled ? 1 : 0.5
        }

        contentItem: Text {
            text: action.text
            textFormat: Text.PlainText
            color: action.primary ? Theme.accentFillInk : Theme.ink
            font.pixelSize: Theme.fontMd
            font.weight: action.primary ? Font.Medium : Font.Normal
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
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
