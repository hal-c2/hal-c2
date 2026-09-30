pragma Singleton
import QtQuick

// ShellRuntime: the shell loaded without errors.
QtObject {
    property string lastError: ""
    property bool usingUserShell: false
    property int generation: 1
    property string userShellPath: ""
}
