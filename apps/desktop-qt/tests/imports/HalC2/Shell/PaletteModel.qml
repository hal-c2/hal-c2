pragma Singleton
import QtQuick

// PaletteModel, the command palette (CommandPaletteController), without its
// node: closed and empty unless a test appends rows ({title, description,
// group, shortcut, kind}). `ran` records the rows run.
ListModel {
    property bool open: false
    property string query: ""
    property int highlighted: 0
    property string emptyText: ""
    property var ran: []

    function setSettingsSections(sections) {}
    function show() { open = true; }
    function toggle() { open = !open; }
    function dismiss() { open = false; }
    function move(delta) { highlighted = Math.max(0, Math.min(count - 1, highlighted + delta)); }
    function run(row) {
        ran.push(row);
        open = false;
        return true;
    }
    function runHighlighted() { return run(highlighted); }
}
