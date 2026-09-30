.pragma library

// The route kinds and the brick that draws each one's centre (<brick>.qml in
// this module).
var views = [
    { kind: "thread", brick: "ThreadView" },
    { kind: "draft", brick: "ThreadView" },
    { kind: "pullRequests", brick: "PullRequestsPage" },
    { kind: "home", brick: "HomePage" },
    { kind: "usage", brick: "UsagePage" },
];

// The brick for a route kind, or "" for one no view draws.
function brickFor(kind) {
    for (var i = 0; i < views.length; ++i) {
        if (views[i].kind === kind)
            return views[i].brick;
    }
    return "";
}
