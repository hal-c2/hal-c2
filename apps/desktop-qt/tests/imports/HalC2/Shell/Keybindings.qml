pragma Singleton
import QtQuick

// The shell's keymap (KeybindingController), as state a test sets directly:
// no shortcuts, and presses and edits are recorded. The native layout tests
// register this file too (qmlRegisterSingletonType).
QtObject {
    property var shortcuts: []
    property var bindings: []
    property bool saving: false
    property var pressed: []
    property var saved: []

    function press(sequence, focus) {
        pressed.push(sequence);
        return true;
    }
    function shortcutLabel(command) {
        return "";
    }
    function recordKey(key, modifiers) {
        return "";
    }
    function keyLabel(key) {
        return key;
    }
    function commandLabel(command) {
        return command;
    }
    function whenError(expression) {
        return "";
    }
    function unknownVariables(expression) {
        return [];
    }
    function conflicts(rowId, key, when) {
        return [];
    }
    function commandOptions() {
        return [];
    }
    function save(command, key, when, replacing) {
        saved.push({ command: command, key: key, when: when });
    }
    function remove(row) {
    }
    function reset(row) {
    }
}
