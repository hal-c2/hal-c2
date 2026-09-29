.pragma library

// The routes whose centre the shell draws itself, and the brick that draws
// it (<brick>.qml in this module). Any other route still shows the embedded
// page. Taking a route from the page is one line here.
var views = [
    { kind: "thread", brick: "ThreadView" },
    { kind: "draft", brick: "ThreadView" },
    { kind: "pullRequests", brick: "PullRequestsPage" },
    { kind: "home", brick: "HomePage" },
];

// The brick for a route kind, or "" while the page draws it.
function brickFor(kind) {
    for (var i = 0; i < views.length; ++i) {
        if (views[i].kind === kind)
            return views[i].brick;
    }
    return "";
}
