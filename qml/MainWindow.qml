import QtQuick
import QtQuick.Layouts
import "components"
import "views"

Item {
    id: root

    property string currentView: "today"
    property string pendingView: "today"

    function switchToView(viewName) {
        if (root.currentView === viewName) {
            return
        }

        root.pendingView = viewName
        viewFade.restart()
    }

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
            categoryManagerRef: categoryManager
            exportServiceRef: exportService

            onItemClicked: function(viewName) {
                root.switchToView(viewName)
            }

            onCategoryManagementRequested: categoryDialog.open()
            onDataExportRequested: exportDialog.open()
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
                id: stackLayout

                anchors.fill: parent
                currentIndex: root.viewIndex(root.currentView)

                TodayTaskView {
                    categoryManagerRef: categoryManager

                    onStartFocus: function(taskId, taskTitle) {
                        root.switchToView("focus")
                    }
                }

                FocusView {
                    onFocusEnded: {
                        root.switchToView("today")
                    }
                }

                WeekPlanView {
                    categoryManagerRef: categoryManager

                    onStartFocus: function(taskId, taskTitle) {
                        root.switchToView("focus")
                    }
                }

                MonthGoalView {
                    categoryManagerRef: categoryManager

                    onStartFocus: function(taskId, taskTitle) {
                        root.switchToView("focus")
                    }
                }

                StatisticsView {
                    categoryManagerRef: categoryManager
                }
            }

            SequentialAnimation {
                id: viewFade

                OpacityAnimator {
                    target: stackLayout
                    from: 1.0
                    to: 0.72
                    duration: 150
                    easing.type: Easing.InOutQuad
                }

                ScriptAction {
                    script: root.currentView = root.pendingView
                }

                OpacityAnimator {
                    target: stackLayout
                    from: 0.72
                    to: 1.0
                    duration: 150
                    easing.type: Easing.InOutQuad
                }
            }
        }
    }

    CategoryDialog {
        id: categoryDialog

        parent: root
        manager: categoryManager
    }

    ExportDialog {
        id: exportDialog

        parent: root
        exportServiceRef: exportService
    }
}
