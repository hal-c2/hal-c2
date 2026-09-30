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
    // The commands the shell runs (CommandRegistry): add and run by id.
    property QtObject commands: QtObject {
        property var entries: ({})
        function add(command, title, callback, owner) {
            const next = Object.assign({}, entries);
            next[command] = { title: title, run: callback };
            entries = next;
        }
        function remove(command) {
            const next = Object.assign({}, entries);
            delete next[command];
            entries = next;
        }
        function contains(command) {
            return entries[command] !== undefined;
        }
        function run(command) {
            if (!contains(command))
                return false;
            entries[command].run();
            return true;
        }
    }

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
