pragma Singleton
import QtQuick

// Stands in for CommandPaletteController (desktop-qt/src/native/CommandPaletteController.h).
QtObject {
    readonly property bool open: false
    readonly property string mode: ""
    readonly property string submenu: ""
    readonly property string placeholder: ""
    property string query: ""
    property int highlighted: 0
    readonly property int count: 0
    readonly property string emptyText: ""
    readonly property string status: ""
    readonly property string submitLabel: ""
    readonly property string submitShortcut: ""
    function show() {}
    function dismiss() {}
    function back() {}
    function leaveSubmenu() { return false; }
    function move(delta) {}
    function run(row) { return false; }
    function runHighlighted() { return false; }
    function addBrowsedFolder() { return false; }
    function setSettingsSections(sections) {}
}
