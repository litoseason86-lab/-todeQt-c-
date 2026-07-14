import QtQuick

FocusScope {
    id: root

    objectName: "settingsGeneralPage"
    property var appSettingsRef: null
    property bool compact: false

    function commitPendingEdits() {
        return true
    }
}
