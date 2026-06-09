import QtQuick
import QtQuick.Layouts
import "components"
import "views"

Item {
    id: root

    property string currentView: "today"

    function viewIndex(viewName) {
        switch (viewName) {
        case "focus":
            return 1
        case "week":
            return 2
        case "month":
            return 3
        case "stats":
            return 4
        case "today":
        default:
            return 0
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        Sidebar {
            Layout.preferredWidth: 208
            Layout.fillHeight: true
            currentView: root.currentView

            onItemClicked: function(viewName) {
                root.currentView = viewName
            }
        }

        Rectangle {
            Layout.preferredWidth: 1
            Layout.fillHeight: true
            color: "#e8dfc8"
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#fffef9"

            StackLayout {
                anchors.fill: parent
                currentIndex: root.viewIndex(root.currentView)

                TodayTaskView {
                    onStartFocus: function(taskId, taskTitle) {
                        root.currentView = "focus"
                    }
                }

                FocusView {
                    onFocusEnded: {
                        root.currentView = "today"
                    }
                }

                WeekPlanView {
                    onStartFocus: function(taskId, taskTitle) {
                        root.currentView = "focus"
                    }
                }

                MonthGoalView {
                    onStartFocus: function(taskId, taskTitle) {
                        root.currentView = "focus"
                    }
                }

                StatisticsView {
                }
            }
        }
    }
}
