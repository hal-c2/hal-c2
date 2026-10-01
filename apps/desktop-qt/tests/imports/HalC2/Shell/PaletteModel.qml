pragma Singleton
import QtQuick

// PaletteModel, the command palette (CommandPaletteController), without its
// MC: closed and empty unless a test appends rows ({title, description,
// group, shortcut, kind, enabled, current}). `ran` records the rows run,
// `calls` what else the brick asked for.
ListModel {
    property bool open: false
    property string mode: "command"
    property string submenu: ""
    property string placeholder: "Search commands, projects, and threads..."
    property string status: ""
    property bool caseSensitive: false
    property bool wholeWord: false
    property bool useRegex: false
    property var calls: []
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
    function back() {
        calls = calls.concat(["back"]);
        if (mode !== "command") mode = "command";
        else if (submenu.length > 0) submenu = "";
        else open = false;
    }
    function leaveSubmenu() {
        if (submenu.length === 0) return false;
        calls = calls.concat(["leaveSubmenu"]);
        submenu = "";
        return true;
    }
    function addBrowsedFolder() {
        calls = calls.concat(["addBrowsedFolder"]);
        return true;
    }
}
