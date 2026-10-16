pragma Singleton
import QtQuick

// Stands in for KeybindingController (desktop-qt/src/native/KeybindingController.h).
QtObject {
    readonly property var commands: null
    readonly property var shortcuts: []
    readonly property var bindings: []
    readonly property int customCount: 0
    readonly property bool saving: false
    property bool modelPickerOpen: false
    readonly property string filePath: ""
    function press(sequence, focus) { return false; }
    function shortcutLabel(command) { return ""; }
    function recordKey(key, modifiers) { return ""; }
    function keyLabel(key) { return key; }
    function commandLabel(command) { return command; }
    function whenError(expression) { return ""; }
    function unknownVariables(expression) { return []; }
    function conflicts(rowId, key, when) { return []; }
    function commandOptions() { return []; }
    function save(command, key, when, row) {}
    function remove(row) {}
    function reset(row) {}
    function resetAll() {}
    function openFile() {}
}
