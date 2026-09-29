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
    property var roles: ["canvas", "accent"]
    property var calls: []

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
    function clear() {
        mode = "system";
        themeId = "";
        halves = {};
        resolvedId = "hal-c2";
        available = [];
        calls = [];
    }
}
