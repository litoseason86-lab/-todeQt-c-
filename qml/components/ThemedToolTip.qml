import QtQuick
import QtQuick.Controls.Basic
import ".."

// 跟随主题的悬停提示。Basic 样式自带的提示是白底、深灰描边、黑字，不随主题变化，
// 浮在玻璃面板上像一块没上色的白框（夜间更刺眼）。这里只换底色、描边和文字，
// 弹出位置（所属控件正上方居中）、关闭规则沿用 Basic 的 ToolTip。
ToolTip {
    id: control

    // 悬停半秒才出现，和应用里其它提示一致；鼠标只是划过时不打扰。
    delay: 500
    // 科目名最长 30 个字，超过这个宽度就折行，不让提示条横跨半个窗口。
    width: Math.min(implicitWidth, 240)
    // 宽度被限住后按实际宽度居中（Basic 按折行前的自然宽度算，折行后会往左偏）。
    x: parent ? (parent.width - width) / 2 : 0
    leftPadding: Theme.space8
    rightPadding: Theme.space8
    topPadding: Theme.space4
    bottomPadding: Theme.space4
    font.pixelSize: Theme.fontSm

    contentItem: Text {
        text: control.text
        // 提示里放的是用户起的名字，按纯文本显示，不让「<b>」这类字符被当成格式。
        textFormat: Text.PlainText
        font: control.font
        color: Theme.ink
        wrapMode: Text.Wrap
    }

    // 与下拉框弹出面板同一套：浮起面底色加一圈主题描边，不用实时模糊，提示只是一行字。
    background: Rectangle {
        color: Theme.surfaceRaised
        border.width: 1
        border.color: Theme.border
        radius: Theme.radiusMd
    }

    enter: Transition {
        NumberAnimation {
            property: "opacity"
            from: 0
            to: 1
            duration: Theme.reduceMotion ? 0 : 120
            easing.type: Easing.OutQuad
        }
    }
    exit: Transition {
        NumberAnimation {
            property: "opacity"
            from: 1
            to: 0
            duration: Theme.reduceMotion ? 0 : 120
            easing.type: Easing.OutQuad
        }
    }
}
