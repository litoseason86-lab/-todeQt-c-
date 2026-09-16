import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "."

ApplicationWindow {
    id: root

    // 数据目录：数据库和迁移快照（pomodoro_backup_*.db）都在这里。
    // 由 main.cpp 在加载时注入；拿不到可写位置时为空串。
    property string dataDirectory: ""

    visible: true
    width: 560
    height: 340
    minimumWidth: 460
    minimumHeight: 300
    title: qsTr("番茄Todo 无法启动")
    color: Theme.surface

    // 数据库未就绪时独立加载，不能实例化会读写业务服务的 MainWindow。
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space24
        spacing: Theme.space16
        Label {
            Layout.fillWidth: true
            text: qsTr("无法打开应用数据")
            color: Theme.inkStrong
            font.pixelSize: Theme.fontXl
        }
        Label {
            Layout.fillWidth: true
            text: qsTr("数据库初始化失败，应用已停止启动。请检查磁盘空间、数据目录权限，或联系维护者检查启动日志。不要删除数据库或备份文件。")
            color: Theme.ink
            wrapMode: Text.WordWrap
        }
        Label {
            Layout.fillWidth: true
            visible: root.dataDirectory.length > 0
            text: qsTr("数据目录（数据库与迁移快照 pomodoro_backup_*.db 都在这里）：")
            color: Theme.inkSoft
            wrapMode: Text.WordWrap
        }
        // 只读但可选中：用户要做的第一件事通常就是把这条路径贴给别人或贴进访达。
        TextArea {
            objectName: "startupErrorDataDirectory"

            Layout.fillWidth: true
            visible: root.dataDirectory.length > 0
            text: root.dataDirectory
            readOnly: true
            selectByMouse: true
            wrapMode: TextArea.WrapAnywhere
            color: Theme.inkStrong
            background: Rectangle {
                color: Theme.surfaceSunken
                radius: Theme.radiusSm
                border.color: Theme.border
            }
        }
        Item { Layout.fillHeight: true }
        Button {
            Layout.alignment: Qt.AlignRight
            text: qsTr("退出")
            onClicked: root.close()
        }
    }
}
