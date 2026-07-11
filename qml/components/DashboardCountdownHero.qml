import QtQuick
import QtQuick.Layouts
import ".."
import "../views/DashboardFormat.js" as DashboardFormat

// 仪表盘倒计时横幅：主目标的天/时/分/秒实时倒数。
// 与 CountdownBanner 的区别：这里是秒级跳动的“英雄位”，只出现在仪表盘。
GlassPanel {
    id: root

    property var primaryGoal: null
    readonly property bool hasGoal: primaryGoal !== null && primaryGoal !== undefined
                                    && primaryGoal.name !== undefined
    // 剩余段整体存对象：天/时/分/秒同一拍更新，避免四个绑定各自跳动。
    property var segments: null

    signal clicked()
    signal addRequested()

    readonly property var quotes: [
        "乾坤未定，你我皆是黑马。",
        "星光不问赶路人，时光不负有心人。",
        "日拱一卒，功不唐捐。",
        "念念不忘，必有回响。"
    ]

    implicitHeight: 96

    onPrimaryGoalChanged: root.updateSegments()
    Component.onCompleted: root.updateSegments()

    function targetIso() {
        // QDate 直接进 JS 会落在 UTC 零点，先格式化成本地日期字符串再解析。
        return root.hasGoal ? Qt.formatDate(root.primaryGoal.targetDate, "yyyy-MM-dd") : ""
    }

    function updateSegments() {
        root.segments = root.hasGoal
                ? DashboardFormat.countdownSegments(root.targetIso(), new Date())
                : null
    }

    function activate() {
        // 点击与测试共用同一入口：有目标看详情，无目标进新建。
        root.hasGoal ? root.clicked() : root.addRequested()
    }

    Timer {
        // 秒级跳动只在横幅可见且有目标时运行，切走页面立即停表。
        interval: 1000
        repeat: true
        running: root.visible && root.hasGoal
        onTriggered: root.updateSegments()
    }

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 4
        radius: root.radius
        color: Theme.accent
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.space24
        anchors.rightMargin: Theme.space24
        spacing: Theme.space16

        Rectangle {
            Layout.preferredWidth: 48
            Layout.preferredHeight: 48
            radius: Theme.radiusLg
            color: Theme.glassAccent
            border.color: Theme.glassBorder
            border.width: 1

            Text {
                anchors.centerIn: parent
                text: "⏳"
                font.pixelSize: Theme.fontXl
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.space4

            Text {
                objectName: "countdownHeroTitle"

                Layout.fillWidth: true
                text: root.hasGoal ? "距" + root.primaryGoal.name + "还有" : "还没有目标倒计时"
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontMd
                font.weight: Font.Medium
                color: Theme.inkSoft
                elide: Text.ElideRight
            }

            RowLayout {
                visible: root.hasGoal && root.segments !== null && !(root.segments && root.segments.expired)
                spacing: Theme.space4

                Repeater {
                    // 数字与单位成对排布；天不补零，时/分/秒补零对齐防止宽度抖动。
                    model: root.segments && !root.segments.expired ? [
                        { value: String(root.segments.days), unit: "天" },
                        { value: DashboardFormat.two(root.segments.hours), unit: "时" },
                        { value: DashboardFormat.two(root.segments.minutes), unit: "分" },
                        { value: DashboardFormat.two(root.segments.seconds), unit: "秒" }
                    ] : []

                    RowLayout {
                        id: segmentItem

                        required property var modelData

                        spacing: 2

                        Text {
                            text: segmentItem.modelData.value
                            textFormat: Text.PlainText
                            font.pixelSize: Theme.fontXxl
                            font.family: Theme.fontFamilyData
                            font.weight: Font.Bold
                            color: Theme.inkStrong
                        }

                        Text {
                            text: segmentItem.modelData.unit
                            textFormat: Text.PlainText
                            font.pixelSize: Theme.fontSm
                            color: Theme.inkSoft
                            Layout.alignment: Qt.AlignBottom
                            Layout.bottomMargin: Theme.space4
                        }
                    }
                }
            }

            Text {
                objectName: "countdownHeroFallback"

                visible: !root.hasGoal || (root.segments !== null && root.segments.expired)
                text: root.hasGoal
                      ? "已过期 " + (root.segments ? root.segments.expiredDays : 0) + " 天"
                      : "把最重要的日期钉在仪表盘上。"
                textFormat: Text.PlainText
                font.pixelSize: root.hasGoal ? Theme.fontXl : Theme.fontMd
                font.weight: root.hasGoal ? Font.Bold : Font.Normal
                color: root.hasGoal ? Theme.danger : Theme.inkMuted
            }
        }

        Text {
            visible: root.hasGoal
            text: DashboardFormat.dailyPick(root.quotes, new Date())
            textFormat: Text.PlainText
            font.pixelSize: Theme.fontMd
            color: Theme.inkSoft
        }

        Text {
            text: root.hasGoal ? "›" : "＋"
            font.pixelSize: Theme.fontXl
            color: Theme.inkMuted
        }
    }

    MouseArea {
        objectName: "countdownHeroHitArea"

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activate()
    }
}
