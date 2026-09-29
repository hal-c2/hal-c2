.pragma library

// The right panel's native tabs, by kind. A kind listed here is drawn by its
// brick (<brick>.qml in this module, given the controller's body object as
// `source`); every other kind is still the page's, shown in its embed. Moving
// a tab to QML is a line here plus the kind in RightPanelController::nativeKinds.
var tabs = {
    diff: { label: "Diff", icon: "file-diff", brick: "DiffPanel", source: "diff" },
    files: { label: "Files", icon: "files", brick: "FilesPanel", source: "files" },
    agents: { label: "Agents", icon: "bot", brick: "AgentsPanel", source: "agents" }
};

function brickOf(kind) {
    return tabs[kind] ? tabs[kind].brick : "";
}
