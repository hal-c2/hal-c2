pragma Singleton
import QtQuick

// Stands in for ThemeController (desktop-qt/src/native/ThemeController.h).
QtObject {
    readonly property string mode: "system"
    readonly property string themeId: ""
    readonly property string resolvedId: ""
    readonly property string appearance: "dark"
    readonly property var halves: ({})
    readonly property var available: []
    readonly property var standardSwatch: []
    readonly property var families: []
    property bool editorOpen: false
    readonly property var editing: ({})
    property bool inspecting: false
    readonly property var picked: ({})
    readonly property string importError: ""
    readonly property var importConflicts: []
    function setMode(mode) { return false; }
    function choose(id) { return false; }
    function chooseHalf(appearance, id) { return false; }
    function restoreDefaults() { return false; }
    function draft(id) { return ({}); }
    function saveCustom(theme) { return ""; }
    function duplicate(id) { return ""; }
    function requestRemove(id) {}
    function requestRemoveMany(ids) {}
    function edit(draft) {}
    function setEditing(draft) {}
    function pick(color) {}
    function derive(canvas, accent) { return ({}); }
    function importText(json) { return false; }
    function importFiles(paths) {}
    function resolveImport(choice) {}
    function clearImport() {}
    function exportTheme(id, path) { return false; }
}
