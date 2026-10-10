pragma Singleton
import QtQuick

// ThemeController as state a test sets directly; `calls` records what the
// bricks asked for.
QtObject {
    property string mode: "system"
    property bool editorOpen: false
    property string themeId: ""
    property var halves: ({})
    property string resolvedId: "hal-c2"
    property var available: []
    property var standardSwatch: []
    property var roles: ["canvas", "accent"]
    property var families: [{ title: "Foundation", roles: ["canvas"] }, { title: "Brand & content", roles: ["accent"] }]
    // The editor's draft, and what an import waits on.
    property var editing: ({})
    property bool inspecting: false
    property var picked: ({})
    property string importError: ""
    property var importConflicts: []
    property var calls: []
    // restoreDefaults fails, as a device that cannot save does.
    property bool failSaves: false

    function record(name, args) {
        calls = calls.concat([{ name: name, args: args }]);
        return true;
    }
    function setMode(next) {
        mode = next;
        return record("setMode", [next]);
    }
    function choose(id) {
        themeId = id;
        resolvedId = id || "hal-c2";
        return record("choose", [id]);
    }
    function chooseHalf(appearance, id) {
        return record("chooseHalf", [appearance, id]);
    }
    // The active theme here is one of this device's own, so its draft carries its id.
    function draft(id) {
        record("draft", [id]);
        return { id: id || "active-custom", label: "HAL-C2", appearance: "dark", colors: { canvas: "#000000", accent: "#ffffff" } };
    }
    function edit(next) {
        editing = next;
        editorOpen = true;
        return record("edit", [next]);
    }
    function setEditing(next) {
        editing = next;
    }
    function derive(canvas, accent) {
        return ({});
    }
    function pick(color) {
        inspecting = false;
        picked = { color: color, role: "", roles: [], count: 0 };
    }
    function requestRemoveMany(ids) {
        return record("requestRemoveMany", [ids]);
    }
    function requestRemove(id) {
        return record("requestRemove", [id]);
    }
    function clearImport() {
        importError = "";
        importConflicts = [];
    }
    function saveCustom(theme) {
        record("saveCustom", [theme]);
        return "saved";
    }
    function duplicate(id) {
        record("duplicate", [id]);
        return id + "-copy";
    }
    function removeCustom(id) {
        return record("removeCustom", [id]);
    }
    function restoreDefaults() {
        record("restoreDefaults", []);
        if (failSaves) return false;
        mode = "system";
        themeId = "";
        halves = {};
        return true;
    }
    function clear() {
        failSaves = false;
        mode = "system";
        themeId = "";
        halves = {};
        resolvedId = "hal-c2";
        available = [];
        editing = {};
        editorOpen = false;
        calls = [];
    }
}
