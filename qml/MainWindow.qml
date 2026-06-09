import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "components"
import "views"

Item {
    id: root

    property string currentView: "today"

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
                currentIndex: root.currentView === "focus" ? 1 : 0

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
            }
        }
    }
}
