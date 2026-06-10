import QtQuick
import QtQuick.Layouts
import "components"
import "views"

Item {
    id: root

    property string currentView: "today"
    property string pendingView: "today"
    property string queuedView: ""
    property bool isSwitching: false

    function switchToView(viewName) {
        if (root.isSwitching) {
            root.queuedView = viewName;
            return;
        }

        if (root.currentView === viewName) {
            return;
        }

        root.isSwitching = true;
        root.pendingView = viewName;
        root.queuedView = "";
        viewFade.restart();
    }

    function finishViewSwitch() {
        root.isSwitching = false;

        if (root.queuedView.length > 0 && root.queuedView !== root.currentView) {
            var nextView = root.queuedView;
            root.queuedView = "";
            root.switchToView(nextView);
            return;
        }

        root.queuedView = "";
    }

    function viewIndex(viewName) {
        switch (viewName) {
        case "focus":
            return 1;
        case "week":
            return 2;
        case "month":
            return 3;
        case "stats":
            return 4;
        case "today":
        default:
            return 0;
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

            onItemClicked: function (viewName) {
                root.switchToView(viewName);
            }

            onCategoryManagementRequested: categoryDialog.open()
            onDataExportRequested: exportDialog.open()
        }

        Rectangle {
            objectName: "mainContentDivider"

            Layout.preferredWidth: 1
            Layout.fillHeight: true
            color: "#e8dfc8"
            opacity: 0.8
        }

        Rectangle {
            objectName: "mainContentBackground"

            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#fffef9"

            StackLayout {
                id: stackLayout
                objectName: "mainViewStack"

                anchors.fill: parent
                currentIndex: root.viewIndex(root.currentView)

                TodayTaskView {
                    categoryManagerRef: categoryManager

                    onStartFocus: function (taskId, taskTitle) {
                        root.switchToView("focus");
                    }
                }

                FocusView {
                    onFocusEnded: {
                        root.switchToView("today");
                    }
                }

                WeekPlanView {
                    categoryManagerRef: categoryManager

                    onStartFocus: function (taskId, taskTitle) {
                        root.switchToView("focus");
                    }
                }

                MonthGoalView {
                    categoryManagerRef: categoryManager

                    onStartFocus: function (taskId, taskTitle) {
                        root.switchToView("focus");
                    }
                }

                StatisticsView {
                    categoryManagerRef: categoryManager
                }
            }

            SequentialAnimation {
                id: viewFade

                OpacityAnimator {
                    objectName: "viewFadeOut"
                    target: stackLayout
                    from: 1.0
                    to: 0.85
                    duration: 180
                    easing.type: Easing.OutQuad
                }

                ScriptAction {
                    script: root.currentView = root.pendingView
                }

                OpacityAnimator {
                    objectName: "viewFadeIn"
                    target: stackLayout
                    from: 0.85
                    to: 1.0
                    duration: 180
                    easing.type: Easing.OutQuad
                }

                ScriptAction {
                    script: root.finishViewSwitch()
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
