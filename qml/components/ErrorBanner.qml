pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import ".."

// 页面里的出错提示条，和倒计时页的错误横幅同一套：危险色描边加「!」，不只靠红色表达出错；
// 说明文字用正文色放在浮起面上，读得清楚，太长就折行，不截断（数据库报错往往很长，截掉就看不出原因）。
// 备忘录页、知识缺口页共用。
Rectangle {
    id: banner

    property string message: ""
    // 里面那行说明文字的 objectName。同一页有两条提示条时各用各的名字，测试才分得清找到的是哪一条。
    property string messageName: ""
    // 为真时多一个「重试」（读取失败时用）。保存失败这类不放：再改一下内容就会重新保存。
    property bool retryable: false
    property bool touchUi: false
    signal retryRequested

    implicitHeight: bannerRow.implicitHeight + Theme.space8 * 2
    radius: Theme.radiusMd
    // 底色用 surfaceRaised：危险色的字压在沉底色上日间只有 4.44:1，不到正文 4.5:1。
    color: Theme.surfaceRaised
    border.color: Theme.dangerBorder
    border.width: 1

    RowLayout {
        id: bannerRow
        anchors.fill: parent
        anchors.leftMargin: Theme.space12
        anchors.rightMargin: Theme.space12
        anchors.topMargin: Theme.space8
        anchors.bottomMargin: Theme.space8
        spacing: Theme.space8

        // 「!」对齐说明文字的第一行；这一块整体再和「重试」按钮上下居中。
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space8

            Text {
                Layout.alignment: Qt.AlignTop
                text: "!"
                textFormat: Text.PlainText
                color: Theme.danger
                font.pixelSize: Theme.fontMd
                font.weight: Font.Bold
                Accessible.ignored: true
            }

            Text {
                objectName: banner.messageName
                Layout.fillWidth: true
                text: banner.message
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: Theme.ink
                font.pixelSize: Theme.fontSm
            }
        }

        PageActionButton {
            objectName: banner.objectName + "Retry"
            visible: banner.retryable
            implicitHeight: banner.touchUi ? 44 : Theme.controlHeightMd
            text: qsTr("重试")
            onClicked: banner.retryRequested()
        }
    }
}
