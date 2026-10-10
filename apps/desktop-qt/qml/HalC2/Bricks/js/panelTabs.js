.pragma library

// The right panel's tabs, by kind: each is drawn by its brick (<brick>.qml in
// this module, given the controller's body object as `source`). A new tab is a
// line here plus the kind in RightPanelController::nativeKinds. A kind can
// have many tabs (terminal: one per `terminal:<group>`, pull-request: one per
// `pull-request:<key>`, device: the picker and one per `device:<host>:<id>`);
// its body shows for any of them.
var tabs = {
    diff: { label: "Diff", icon: "file-diff", brick: "DiffPanel", source: "diff" },
    files: { label: "Files", icon: "files", brick: "FilesPanel", source: "files" },
    agents: { label: "Agents", icon: "bot", brick: "AgentsPanel", source: "agents" },
    terminal: { label: "Terminal", icon: "terminal", brick: "TerminalPanel", source: "" },
    "pull-requests": { label: "Pull requests", icon: "link-2", brick: "PullRequestsPanel", source: "pullRequests" },
    previews: { label: "Previews", icon: "monitor", brick: "PreviewsPanel", source: "previews" },
    "pull-request": { label: "Pull request review", icon: "git-pull-request-arrow", brick: "PullRequestReviewPanel", source: "review" },
    device: { label: "Device", icon: "smartphone", brick: "DevicePanel", source: "device" }
};

function brickOf(kind) {
    return tabs[kind] ? tabs[kind].brick : "";
}
