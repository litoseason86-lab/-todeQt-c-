import QtQuick

FocusScope {
    id: root

    objectName: "settingsDataPage"
    property var appSettingsRef: null
    property bool compact: false
    signal routineRequested
    signal categoryRequested
    signal exportRequested
}
