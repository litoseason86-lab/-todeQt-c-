pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "../components"
import ".."
import "TrashFormat.js" as TrashFormat

// 废纸篓页（计划 054）：近 30 天被删除的内容，按删除那天分组，可以恢复或彻底删除。
// 数据全部来自 TrashService.readItems()：分组用的「今天」、每组的「还剩 N 天」都取服务给的值，
// 页面不自己算日期。
Item {
    id: root

    property var trashServiceRef: null
    // 逻辑日服务（LogicalDayService）：日界点或时区变化时它发 changed，页面据此重读。
    property var logicalDayServiceRef: null
    // 页面容器显式声明是否当前页；不能依赖 effective visible，离屏测试和窗口层级会污染该值。
    property bool pageActive: true
    property bool touchUi: Qt.platform.os === "ios"

    // 最近一次成功读取的结果。读取失败时清空：数据库都读不出来时，不能让用户对着过期的列表点「删除」。
    property var items: []
    property string today: ""
    // 读到过一次结果（无论有没有项）才算「加载完成」，之前既不画空状态也不画列表。
    property bool loaded: false
    // 读取失败与操作失败分开存：只有读取失败带「重试」，重试只会重读，补不上没做成的恢复或删除。
    property string loadError: ""
    property string actionError: ""
    readonly property var groups: TrashFormat.groupItems(root.items, root.today)
    readonly property bool hasItems: root.items.length > 0
    readonly property int controlHeight: root.touchUi ? 44 : Theme.controlHeightMd

    // 恢复成功后由 MainWindow 接成底部提示条；页面自己不画提示条。
    signal itemRestored(string title)

    // 页面第一次创建就是激活态时，onPageActiveChanged 与 onCompleted 都可能走到这里，
    // 靠 completed 保证创建期间只激活一次（先清理过期项、再读取，各一次）。
    property bool completed: false

    function service() {
        return root.trashServiceRef
    }

    function reload() {
        var svc = root.service()
        if (!svc || typeof svc.readItems !== "function") {
            root.items = []
            root.loadError = qsTr("废纸篓服务不可用")
            return
        }
        var result = svc.readItems()
        if (!result || !result.ok) {
            root.items = []
            root.loaded = false
            root.loadError = String(result && result.error ? result.error : qsTr("读取废纸篓失败"))
            return
        }
        root.loadError = ""
        root.today = String(result.today)
        root.items = result.items
        root.loaded = true
    }

    // 进页面先清掉到期的，再读：清理在启动和逻辑日变化时才跑，久开着的应用里到期项可能还没被清。
    // 上次在这一页留下的操作失败提示随之清掉：它说的是那时的列表，隔了一段时间再进来就是过期信息。
    function activate() {
        root.actionError = ""
        var svc = root.service()
        if (svc && typeof svc.purgeExpired === "function") {
            svc.purgeExpired()
        }
        root.reload()
    }

    // 另一台刚恢复或删掉这一项时，服务给 code "gone"（文案是「已经不在废纸篓里了」）：
    // 列表是过期的，提示后重读。认结构化的 code，不比文案。
    function noteFailure(text, result) {
        root.actionError = text
        if (result && result.code === "gone") {
            root.reload()
        }
    }

    function restore(item) {
        var svc = root.service()
        if (!svc || typeof svc.restoreItem !== "function") {
            root.actionError = qsTr("废纸篓服务不可用")
            return
        }
        var result = svc.restoreItem(Number(item.id))
        if (result && result.ok) {
            root.actionError = ""
            root.itemRestored(String(result.title !== undefined && result.title !== "" ? result.title : item.title))
            root.reload()
            return
        }
        root.noteFailure(TrashFormat.restoreFailureText(item, result, root.today), result)
    }

    function requestDelete(item) {
        deleteConfirm.pendingId = Number(item.id)
        deleteConfirm.pendingTitle = String(item.title)
        deleteConfirm.open()
    }

    function confirmDelete() {
        // onAboutToHide 会把 pendingId 复位，先取出再关。
        var id = deleteConfirm.pendingId
        deleteConfirm.close()
        var svc = root.service()
        if (id < 0 || !svc || typeof svc.deleteItem !== "function") {
            return
        }
        var result = svc.deleteItem(id)
        if (result && result.ok) {
            root.actionError = ""
            root.reload()
            return
        }
        var reason = String(result && result.error ? result.error : qsTr("删除失败"))
        root.noteFailure(reason, result)
    }

    function requestEmpty() {
        if (!root.hasItems) {
            return
        }
        var ids = []
        for (var i = 0; i < root.items.length; ++i) {
            ids.push(Number(root.items[i].id))
        }
        emptyConfirm.pendingIds = ids
        emptyConfirm.pendingCount = ids.length
        emptyConfirm.open()
    }

    function confirmEmpty() {
        // onAboutToHide 会把 pendingIds 复位，先取出再关。
        var ids = emptyConfirm.pendingIds
        emptyConfirm.close()
        var svc = root.service()
        if (!svc || typeof svc.emptyTrash !== "function") {
            return
        }
        var result = svc.emptyTrash(ids)
        if (result && result.ok) {
            root.actionError = ""
            root.reload()
            return
        }
        var reason = String(result && result.error ? result.error : qsTr("清空失败"))
        root.noteFailure(reason, result)
    }

    onPageActiveChanged: {
        if (root.completed && root.pageActive) {
            root.activate()
        }
    }

    Component.onCompleted: {
        root.completed = true
        if (root.pageActive) {
            root.activate()
        }
    }

    Connections {
        // 门禁写在处理函数里，不用 enabled 绑定（绑定重算晚于同步发出的信号，会漏掉）。
        // 页面常驻在 StackLayout 里，不在这一页时收到信号不读库，切回来时 activate 会读。
        target: root.trashServiceRef
        ignoreUnknownSignals: true

        function onTrashChanged() {
            if (root.pageActive) {
                root.reload()
            }
        }
    }

    Connections {
        // C++ 装配层（main.cpp）在同一信号上已先清理到期项（连接早于界面加载，先执行），这里只重读。
        // 刷新不能依赖有没有项被清掉：没有到期项时不会发 trashChanged，但「今天」分组和剩余天数已经变了。
        // 门禁同样写在处理函数里；不在这一页时不读库，切回来时 activate 会读。
        target: root.logicalDayServiceRef
        ignoreUnknownSignals: true

        function onChanged() {
            if (root.pageActive) {
                root.reload()
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space24
        spacing: Theme.space16

        RowLayout {
            Layout.fillWidth: true
            // ColumnLayout 里的子 Layout 默认纵向撑满，必须关掉，否则页头被拉到页面中间。
            Layout.fillHeight: false
            spacing: Theme.space12

            Text {
                objectName: "trashPageTitle"
                text: qsTr("废纸篓")
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontXxl
                font.weight: Font.Bold
                color: Theme.ink
            }

            Item {
                Layout.fillWidth: true
            }

            PageActionButton {
                objectName: "trashEmptyButton"
                translucent: true
                implicitHeight: root.controlHeight
                text: qsTr("清空废纸篓")
                enabled: root.hasItems && root.loadError.length === 0
                onClicked: root.requestEmpty()
            }
        }

        ErrorBanner {
            objectName: "trashLoadErrorBanner"
            messageName: "trashLoadErrorText"
            Layout.fillWidth: true
            visible: root.loadError.length > 0
            message: root.loadError
            retryable: true
            touchUi: root.touchUi
            onRetryRequested: root.reload()
        }

        ErrorBanner {
            objectName: "trashActionErrorBanner"
            messageName: "trashActionErrorText"
            Layout.fillWidth: true
            visible: root.actionError.length > 0
            message: root.actionError
            touchUi: root.touchUi
        }

        // 列表区：玻璃框与里面的内容是兄弟项，内容叠在框上，不放进框的阴影图层（图层会把子项裁在框内）。
        Item {
            id: listArea
            Layout.fillWidth: true
            Layout.fillHeight: true

            GlassPanel {
                id: panel
                objectName: "trashPanel"
                anchors.fill: parent
                visible: root.hasItems
            }

            ScrollView {
                id: scroll
                objectName: "trashScrollView"
                visible: root.hasItems
                clip: true
                anchors {
                    left: panel.left
                    top: panel.top
                    bottom: panel.bottom
                    // 向右伸出玻璃框和页边距、一直到窗口右缘，滚动条才贴窗口最右缘；
                    // 再用同样宽的右内边距把内容收回框内（框内边距 16）。
                    right: panel.right
                    rightMargin: -Theme.space24
                }
                leftPadding: Theme.space16
                topPadding: Theme.space16
                bottomPadding: Theme.space16
                rightPadding: Theme.space24 + Theme.space16
                contentWidth: availableWidth

                ScrollBar.vertical: PageScrollBar {
                    objectName: "trashScrollBar"
                    parent: scroll
                    x: scroll.width - width
                    y: scroll.topPadding
                    height: scroll.availableHeight
                    scrollAreaVisible: root.pageActive
                }

                ColumnLayout {
                    width: parent ? parent.width : 0
                    spacing: Theme.space16

                    Repeater {
                        model: root.groups

                        ColumnLayout {
                            id: groupBlock
                            required property var modelData

                            Layout.fillWidth: true
                            spacing: Theme.space8

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.space12

                                Text {
                                    objectName: "trashGroupHeading-" + (groupBlock.modelData.key.length > 0 ? groupBlock.modelData.key : "unknown")
                                    Layout.fillWidth: true
                                    text: TrashFormat.groupHeading(groupBlock.modelData)
                                    textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontSm
                                    font.weight: Font.Bold
                                    color: Theme.inkSoft
                                    elide: Text.ElideRight
                                }

                                Text {
                                    objectName: "trashGroupRemaining-" + (groupBlock.modelData.key.length > 0 ? groupBlock.modelData.key : "unknown")
                                    visible: groupBlock.modelData.remaining.length > 0
                                    text: groupBlock.modelData.remaining
                                    textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontSm
                                    color: Theme.inkSoft
                                }
                            }

                            Repeater {
                                model: groupBlock.modelData.items

                                Rectangle {
                                    id: card
                                    required property var modelData

                                    objectName: "trashRow-" + card.modelData.id
                                    Layout.fillWidth: true
                                    implicitHeight: cardRow.implicitHeight + Theme.space8 * 2 + 4
                                    radius: Theme.radiusMd
                                    // 内容卡保持清晰，不做玻璃；米色描边在玻璃框上才分得出卡片边界。
                                    color: Theme.surfaceRaised
                                    border.color: Theme.border
                                    border.width: 1

                                    RowLayout {
                                        id: cardRow
                                        anchors.fill: parent
                                        anchors.leftMargin: Theme.space16
                                        anchors.rightMargin: Theme.space16
                                        anchors.topMargin: 10
                                        anchors.bottomMargin: 10
                                        spacing: Theme.space12

                                        // 科目色点始终占位：没有科目只是不上色，标题左缘才对得齐。
                                        // 对齐标题首行而不是整行居中，看得出它标的是标题。
                                        Rectangle {
                                            objectName: "trashDot-" + card.modelData.id
                                            Layout.alignment: Qt.AlignTop
                                            Layout.topMargin: 5
                                            Layout.preferredWidth: 8
                                            Layout.preferredHeight: 8
                                            radius: 4
                                            color: String(card.modelData.categoryColor || "").length > 0
                                                   ? String(card.modelData.categoryColor)
                                                   : "transparent"
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.space4

                                            Text {
                                                objectName: "trashTitle-" + card.modelData.id
                                                Layout.fillWidth: true
                                                text: String(card.modelData.title)
                                                textFormat: Text.PlainText
                                                font.pixelSize: Theme.fontMd
                                                color: Theme.ink
                                                elide: Text.ElideRight
                                            }

                                            Text {
                                                objectName: "trashMeta-" + card.modelData.id
                                                Layout.fillWidth: true
                                                text: TrashFormat.metaText(card.modelData, root.today)
                                                textFormat: Text.PlainText
                                                // 次要文字用 inkSoft：inkMuted 压在浮起面上不到 4.5:1。
                                                font.pixelSize: Theme.fontXs
                                                color: Theme.inkSoft
                                                elide: Text.ElideRight
                                            }
                                        }

                                        PageActionButton {
                                            objectName: "trashRestoreButton-" + card.modelData.id
                                            implicitHeight: root.controlHeight
                                            text: qsTr("恢复")
                                            enabled: card.modelData.restorable !== false
                                            Accessible.name: qsTr("恢复「%1」").arg(String(card.modelData.title))
                                            onClicked: root.restore(card.modelData)
                                        }

                                        PageActionButton {
                                            objectName: "trashDeleteButton-" + card.modelData.id
                                            implicitHeight: root.controlHeight
                                            text: qsTr("删除")
                                            Accessible.name: qsTr("彻底删除「%1」").arg(String(card.modelData.title))
                                            onClicked: root.requestDelete(card.modelData)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // 空状态只在读取成功且确实没有项时出现；读取失败由上面的提示条说明，不能被说成「是空的」。
            Text {
                objectName: "trashEmptyStateText"
                anchors.centerIn: parent
                visible: root.loaded && root.loadError.length === 0 && !root.hasItems
                text: qsTr("废纸篓是空的")
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontMd
                color: Theme.inkSoft
            }
        }
    }

    // 两个确认弹层都照备忘录的删除确认：焦点先落在「取消」（回车、空格不会误删），Esc 关闭。
    Popup {
        id: deleteConfirm
        objectName: "trashDeleteConfirm"

        property int pendingId: -1
        property string pendingTitle: ""

        parent: root
        anchors.centerIn: parent
        width: Math.min(360, root.width - Theme.space24 * 2)
        padding: Theme.space24
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape
        // 用弹窗自己的焦点理由，鼠标打开时不画焦点环，按 Tab 才出现。
        onOpened: deleteCancelButton.forceActiveFocus(Qt.PopupFocusReason)
        onAboutToHide: pendingId = -1
        Overlay.modal: Rectangle {
            color: Theme.dialogScrim
        }
        background: Rectangle {
            color: Theme.surface
            radius: Theme.radiusLg
            border.color: Theme.border
            border.width: 1
        }
        contentItem: ColumnLayout {
            spacing: Theme.space12

            Text {
                Layout.fillWidth: true
                text: qsTr("彻底删除这一项？")
                textFormat: Text.PlainText
                color: Theme.inkStrong
                font.pixelSize: Theme.fontLg
                font.bold: true
            }

            Text {
                objectName: "trashDeleteConfirmText"
                Layout.fillWidth: true
                text: deleteConfirm.pendingTitle
                textFormat: Text.PlainText
                color: Theme.inkSoft
                font.pixelSize: Theme.fontSm
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space8

                Item {
                    Layout.fillWidth: true
                }

                PageActionButton {
                    id: deleteCancelButton
                    objectName: "trashDeleteCancel"
                    implicitHeight: root.controlHeight
                    text: qsTr("取消")
                    onClicked: deleteConfirm.close()
                }

                PageActionButton {
                    objectName: "trashDeleteConfirmButton"
                    implicitHeight: root.controlHeight
                    text: qsTr("删除")
                    primary: true
                    onClicked: root.confirmDelete()
                }
            }
        }
    }

    Popup {
        id: emptyConfirm
        objectName: "trashEmptyConfirm"

        // 打开时列表里各项的编号和项数：弹层开着期间列表可能被同步刷新，确认框上写的数字以打开那一刻为准，
        // 服务也只删这些编号（连同同一原记录的行），确认期间新同步进来的项不会被一起删掉。
        property var pendingIds: []
        property int pendingCount: 0
        onAboutToHide: pendingIds = []

        parent: root
        anchors.centerIn: parent
        width: Math.min(360, root.width - Theme.space24 * 2)
        padding: Theme.space24
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape
        onOpened: emptyCancelButton.forceActiveFocus(Qt.PopupFocusReason)
        Overlay.modal: Rectangle {
            color: Theme.dialogScrim
        }
        background: Rectangle {
            color: Theme.surface
            radius: Theme.radiusLg
            border.color: Theme.border
            border.width: 1
        }
        contentItem: ColumnLayout {
            spacing: Theme.space12

            Text {
                objectName: "trashEmptyConfirmTitle"
                Layout.fillWidth: true
                text: qsTr("彻底删除废纸篓里的 %1 项？").arg(emptyConfirm.pendingCount)
                textFormat: Text.PlainText
                color: Theme.inkStrong
                font.pixelSize: Theme.fontLg
                font.bold: true
                wrapMode: Text.Wrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space8

                Item {
                    Layout.fillWidth: true
                }

                PageActionButton {
                    id: emptyCancelButton
                    objectName: "trashEmptyCancel"
                    implicitHeight: root.controlHeight
                    text: qsTr("取消")
                    onClicked: emptyConfirm.close()
                }

                PageActionButton {
                    objectName: "trashEmptyConfirmButton"
                    implicitHeight: root.controlHeight
                    text: qsTr("清空")
                    primary: true
                    onClicked: root.confirmEmpty()
                }
            }
        }
    }
}
