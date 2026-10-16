pragma Singleton
import QtQuick

// Stands in for ShellRuntime (desktop-qt/src/ShellRuntime.h).
QtObject {
    readonly property string configDir: ""
    readonly property string userShellPath: ""
    readonly property bool usingUserShell: false
    readonly property string lastError: ""
    readonly property int generation: 0
    readonly property bool hotReloadEnabled: false
    readonly property string appVersion: "0.0.0-ljos"
    function reload() {}
}
