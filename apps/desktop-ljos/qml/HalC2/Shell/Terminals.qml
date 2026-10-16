pragma Singleton
import QtQuick

// Stands in for TerminalController (desktop-qt/src/native/TerminalController.h); no terminals here.
QtObject {
    readonly property bool supported: false
    readonly property bool available: false
    property bool open: false
    readonly property int height: 0
    readonly property string activeTerminalId: ""
    readonly property string activeGroup: ""
    readonly property var groupSizes: ({})
    readonly property var tabs: null
    function focusTerminal(terminalId) {}
}
