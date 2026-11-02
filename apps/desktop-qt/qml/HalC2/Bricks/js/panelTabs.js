.pragma library

// The right panel's tabs, by kind: each is drawn by its brick (<brick>.qml in
// this module, given the controller's body object as `source`). A new tab is a
// line here plus the kind in RightPanelController::nativeKinds. A kind can
// have many tabs (terminal: one per `terminal:<group>`, pull-request: one per
// `pull-request:<key>`, device: the picker and one per `device:<host>:<id>`).
//
// Bodies live in one pool (PanelBodies.qml) that the side panel and each of
// the stage's panes borrow from: a body moves between them (reparented, never
// made again), so it keeps its scroll, what it loaded and its session. By
// default a kind has one body, shown for whichever of its tabs shows first
// (Shell.state.panel.shownTabs); another place showing a tab of that kind at
// the same time says where it is. A kind marked `perTab: true` gets a body
// per tab instead, made when its tab first shows and dropped when the tab
// goes. Every body is given `source` (Panel[<source>], or null) and, if it
// declares one, `tabId`: the tab it shows. A per-tab kind's controller tells
// its tabs apart by that id (browser: one body per `browser:<tab>`, one
// page each).
var tabs = {
    diff: { label: "Diff", icon: "file-diff", brick: "DiffPanel", source: "diff" },
    files: { label: "Files", icon: "files", brick: "FilesPanel", source: "files" },
    agents: { label: "Agents", icon: "bot", brick: "AgentsPanel", source: "agents" },
    terminal: { label: "Terminal", icon: "terminal", brick: "TerminalPanel", source: "" },
    "pull-requests": { label: "Pull requests", icon: "link-2", brick: "PullRequestsPanel", source: "pullRequests" },
    previews: { label: "Previews", icon: "monitor", brick: "PreviewsPanel", source: "previews" },
    "pull-request": { label: "Pull request review", icon: "git-pull-request-arrow", brick: "PullRequestReviewPanel", source: "review" },
    device: { label: "Device", icon: "smartphone", brick: "DevicePanel", source: "device", perTab: true },
    browser: { label: "Browser", icon: "globe", brick: "BrowserPanel", source: "previews", perTab: true }
};

// A tab's kind: its id up to the first ":".
function kindOf(id) {
    const colon = id.indexOf(":");
    return colon < 0 ? id : id.slice(0, colon);
}

// The pool's key for the body showing tab `id`: the tab itself for a per-tab
// kind, else its kind.
function bodyOf(id) {
    const kind = kindOf(id);
    return tabs[kind] && tabs[kind].perTab ? id : kind;
}

function brickOf(kind) {
    return tabs[kind] ? tabs[kind].brick : "";
}
