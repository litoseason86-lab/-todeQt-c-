import QtQuick
import QtQuick.Layouts
import "."
import "components"
import "views"

Item {
    id: root

    property string currentView: "today"
    property string pendingView: "today"
    // 淡入淡出期间只保留最后一次视图请求，避免动画队列堆积。
    property string queuedView: ""
    property bool isSwitching: false
    property var countdownServiceRef: typeof countdownService === "undefined" ? null : countdownService
    property var appSettingsRef: typeof appSettings === "undefined" ? null : appSettings

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
            // 当前切换完全结束后，再启动下一次切换。
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
        case "countdown":
            return 5;
        case "today":
        default:
            return 0;
        }
    }

    function startFocusForTask(taskId, taskTitle) {
        // 已有自由专注、番茄工作或休息阶段时，不启动第二个会话；直接带用户去专注页处理当前状态。
        if (focusTimer.hasActiveSession || focusTimer.phase !== 0) {
            root.switchToView("focus");
            return;
        }

        // 上次使用番茄：进入待机并预载任务，不能偷跑计时，用户还需要机会调整时长。
        if (root.appSettingsRef && root.appSettingsRef.lastMode === 1) {
            focusView.enterPomodoroWithTask(taskId, taskTitle);
            root.switchToView("focus");
            return;
        }

        if (focusTimer.startFocus(taskId, taskTitle)) {
            if (root.appSettingsRef) {
                root.appSettingsRef.lastMode = 0;
            }
            root.switchToView("focus");
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
            focusTimerRef: focusTimer

            onItemClicked: function (viewName) {
                root.switchToView(viewName);
            }

            onCategoryManagementRequested: categoryDialog.open()
            onDailyRoutineRequested: routineDialog.open()
            onDataExportRequested: exportDialog.open()
        }

        Rectangle {
            objectName: "mainContentDivider"

            Layout.preferredWidth: 1
            Layout.fillHeight: true
            color: Theme.border
            opacity: 0.8
        }

        Rectangle {
            objectName: "mainContentBackground"

            Layout.fillWidth: true
            Layout.fillHeight: true
            color: Theme.surface

            Image {
                objectName: "paperTextureLayer"

                anchors.fill: parent
                z: 0
                visible: true
                opacity: 0.03
                fillMode: Image.Tile
                source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'><filter id='noise'><feTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/></filter><rect width='100%' height='100%' filter='url(%23noise)'/></svg>"
            }

            StackLayout {
                id: stackLayout
                objectName: "mainViewStack"

                anchors.fill: parent
                z: 1
                currentIndex: root.viewIndex(root.currentView)

                TodayTaskView {
                    categoryManagerRef: categoryManager
                    countdownServiceRef: root.countdownServiceRef

                    onStartFocus: function (taskId, taskTitle) {
                        root.startFocusForTask(taskId, taskTitle);
                    }

                    onCountdownRequested: root.switchToView("countdown")
                }

                FocusView {
                    id: focusView
                    objectName: "focusViewPage"
                    timer: focusTimer
                    settings: root.appSettingsRef

                    onFocusEnded: {
                        root.switchToView("today");
                    }
                }

                WeekPlanView {
                    categoryManagerRef: categoryManager

                    onStartFocus: function (taskId, taskTitle) {
                        root.startFocusForTask(taskId, taskTitle);
                    }
                }

                MonthGoalView {
                    categoryManagerRef: categoryManager

                    onStartFocus: function (taskId, taskTitle) {
                        root.startFocusForTask(taskId, taskTitle);
                    }
                }

                StatisticsView {
                    categoryManagerRef: categoryManager
                }

                CountdownView {
                    countdownServiceRef: root.countdownServiceRef
                }
            }

            SequentialAnimation {
                id: viewFade

                OpacityAnimator {
                    objectName: "viewFadeOut"
                    target: stackLayout
                    from: 1.0
                    to: 0.96
                    duration: 70
                    easing.type: Easing.OutQuad
                }

                ScriptAction {
                    // 在透明度最低时切换页面，隐藏 StackLayout 的硬切。
                    script: root.currentView = root.pendingView
                }

                OpacityAnimator {
                    objectName: "viewFadeIn"
                    target: stackLayout
                    from: 0.96
                    to: 1.0
                    duration: 70
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

    RoutineDialog {
        id: routineDialog

        parent: root
        routineManagerRef: typeof routineManager === "undefined" ? null : routineManager
        categoryManagerRef: categoryManager
    }

    ExportDialog {
        id: exportDialog

        parent: root
        exportServiceRef: exportService
    }
}
