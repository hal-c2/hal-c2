import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// The right panel's bodies: each tab draws its brick and keeps it while
// another tab shows. Its edge resizes it and its header button maximizes it.
// The Files viewer's wrap, the Diff tab's revert confirmation, and the Pull
// request review tab's conversation, offline and online.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: panelComponent
        RightPanel {
            width: 600
            height: 600
        }
    }

    Component {
        id: filesComponent
        FilesPanel {
            width: 400
            height: 600
        }
    }

    Component {
        id: diffComponent
        DiffPanel {
            width: 500
            height: 600
        }
    }

    Component {
        id: agentsComponent
        AgentsPanel {
            width: 400
            height: 600
        }
    }

    // An AgentsModel: a running subagent and a running command, then a finished subagent.
    Component {
        id: fakeAgents
        ListModel {
            ListElement {
                agentId: "task-tax"; kind: "subagent"; section: "active"; title: "Tax tests"; status: "running"; statusLabel: "Working"
                elapsed: "12s"; detail: "Writing cart tests"; modelName: "gpt-5.5"; childThreadKey: "env-a:thread-tax"; ended: ""
            }
            ListElement {
                agentId: "turn-item:9"; kind: "command"; section: "active"; title: "bun test cart"; status: "running"; statusLabel: "Working"
                elapsed: "3s"; detail: ""; modelName: ""; childThreadKey: ""; ended: ""
            }
            ListElement {
                agentId: "task-docs"; kind: "subagent"; section: "finished"; title: "Docs"; status: "failed"; statusLabel: "Failed"
                elapsed: "1m 15s"; detail: "No docs folder"; modelName: ""; childThreadKey: "env-a:thread-docs"; ended: "Failed at 9:41 AM"
            }
        }
    }

    // A WorkspaceFiles with one open file of one long line.
    Component {
        id: fakeFiles
        QtObject {
            property string root: "/work/shop"
            property string query: ""
            property bool searching: false
            property bool searchTruncated: false
            property string searchProblem: ""
            property string openPath: "src/app.ts"
            property string fileStatus: "ready"
            property string fileProblem: ""
            property string truncatedNotice: ""
            property bool fileEmpty: false
            property int revealLine: 0
            property bool wrap: false
            // WorkspaceFiles notifies both through renderedChanged.
            property bool rendered: false
            property bool editing: false
            property var tree: null
            property ListModel lines: ListModel {
                property int maxColumns: 400
                ListElement {
                    number: 1
                    text: "export const rates = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7];"
                }
            }
            signal revealRequested
        }
    }

    // A ThreadDiff with three turns and nothing loaded.
    Component {
        id: fakeDiff
        QtObject {
            property var choices: [{ value: -1, label: "Latest turn" }, { value: 0, label: "All changes" }]
            property int selection: -1
            property int latestTurn: 3
            property string status: "empty"
            property string message: "No net changes in this selection."
            property bool wrap: false
            property bool ignoreWhitespace: false
            property bool canRevert: true
            property bool reverting: false
            property int revertTurn: 0
            property var model: null
            property var confirmed: []
            property int cancelled: 0
            signal revealRow(int row)
            function requestRevert(turn) { revertTurn = turn > 0 ? turn : latestTurn; }
            function confirmRevert(restoreFiles) { confirmed.push(restoreFiles); revertTurn = 0; }
            function cancelRevert() { cancelled += 1; revertTurn = 0; }
            function select(value) { selection = value; }
            function reload() {}
        }
    }

    Component {
        id: pullRequestsComponent
        PullRequestsPanel {
            width: 400
            height: 600
        }
    }

    Component {
        id: previewsComponent
        PreviewsPanel {
            width: 400
            height: 600
        }
    }

    // A ThreadPullRequests with one open pull request.
    Component {
        id: fakePullRequests
        ListModel {
            property bool online: true
            property bool linkOpen: false
            property bool linking: false
            property bool refreshing: false
            property string problem: ""
            property int openCount: 1
            property var calls: []
            function link(text) { calls.push("link " + text); }
            function open(key) { calls.push("open " + key); }
            function refresh() { calls.push("refresh"); }
            function unlink(key) { calls.push("unlink " + key); }
            function copyLink(key) { calls.push("copy " + key); }
            ListElement {
                linkKey: "github.com/acme/shop#42"; repository: "acme/shop"; number: 42; title: "Tax line fix"
                state: "open"; stateLabel: "Open"; checks: "passing"; checksLabel: "Checks passing"
                review: "review-required"; reviewLabel: "Review required"; conflicting: false
                branches: "tax-fix → main"; sourceLabel: "Linked by you"; unlinkLabel: "Unlink"
            }
        }
    }

    Component {
        id: reviewComponent
        PullRequestReviewPanel {
            width: 500
            height: 600
        }
    }

    // A PullRequestReview of pull request 42, read, with one remark.
    Component {
        id: fakeReview
        QtObject {
            property var model: null
            property int number: 42
            property bool online: true
            property string status: "ready"
            property string message: ""
            property bool busy: false
            property string problem: ""
            property var detail: ({ title: "Tax line fix", body: "Rounds the tax line.", url: "https://github.com/acme/shop/pull/42", author: "octocat", state: "open", stateLabel: "Open", branches: "feature/tax → main", labels: [], reviewers: [], mergeability: "mergeable", behindBy: 0, checks: [{ name: "test", status: "success", description: "", url: "" }] })
            property var conversation: [{ id: "c1", kind: "comment", author: "ada", body: "Why round up?", createdAt: "", reviewState: "", path: "" }]
            property var reviewThreads: []
            property string codeStatus: "ready"
            property string codeMessage: ""
            property var viewedPaths: []
            property int viewedCount: 0
            property var calls: []
            function reload() { calls.push("reload"); }
            function comment(body) { calls.push("comment " + body); return true; }
            function submitReview(verdict, body) { calls.push(verdict + " " + body); return true; }
            function copyNumber() { calls.push("copy"); }
            function openOnHost() { calls.push("host"); }
            function setViewed(path, viewed) {}
            function setThreadResolved(id, resolved) {}
        }
    }

    // A ThreadPreviews with one loaded tab.
    Component {
        id: fakePreviews
        ListModel {
            property string status: "ready"
            property string message: ""
            property var calls: []
            function open(tabId) { calls.push("open " + tabId); }
            function close(tabId) { calls.push("close " + tabId); }
            function reload() { calls.push("reload"); }
            ListElement { tabId: "tab-1"; url: "http://localhost:5173"; title: "Vite"; status: "loaded"; problem: "" }
        }
    }

    function panelState(activeId) {
        return {
            threadKey: "env-a:thread-1",
            isOpen: true,
            activeId: activeId,
            width: 540,
            maximized: false,
            canAdd: { diff: true, files: true, agents: true, terminal: true },
            tabs: [
                { id: "diff", kind: "diff", title: "Diff" },
                { id: "files", kind: "files", title: "Files" }
            ]
        };
    }

    TestCase {
        name: "RightPanelTests"
        when: windowShown

        function cleanup() {
            Shell.reset();
            Panel.diff = null;
            Panel.files = null;
            Panel.agents = null;
        }

        function test_tabsKeepTheirBody() {
            Panel.diff = createTemporaryObject(fakeDiff, root);
            Panel.files = createTemporaryObject(fakeFiles, root);
            Shell.state = Object.assign({}, Shell.state, { panel: panelState("diff") });
            const panel = createTemporaryObject(panelComponent, root);
            const diff = findChild(panel, "panelBody-diff");
            const files = findChild(panel, "panelBody-files");
            verify(diff && files);
            tryCompare(diff, "status", Loader.Ready);
            compare(diff.item.source, Panel.diff);
            verify(diff.visible);
            compare(files.active, false, "a tab not yet shown is not made");

            Shell.state = Object.assign({}, Shell.state, { panel: panelState("files") });
            tryCompare(files, "status", Loader.Ready);
            verify(files.visible && !diff.visible);
            compare(diff.active, true, "a hidden tab is kept");
        }

        function test_edgeDragsToAWidthTheLayoutAllows() {
            Shell.state = Object.assign({}, Shell.state, { panel: panelState("diff") });
            const panel = createTemporaryObject(panelComponent, root, { x: 450, maximumWidth: 700 });
            compare(panel.implicitWidth, 540);
            const edge = findChild(panel, "panelEdge");
            verify(edge.visible);
            mousePress(edge, 3, 100);
            mouseMove(edge, -97, 100);
            compare(panel.implicitWidth, 640, "the panel follows the drag");
            compare(Shell.dispatchedActions.length, 0, "the width is kept once the drag ends");
            mouseMove(edge, -440, 100);
            compare(panel.implicitWidth, 700, "the thread keeps its room");
            mouseRelease(edge, -440, 100);
            compare(Shell.dispatchedActions.length, 1);
            compare(Shell.dispatchedActions[0].action, "rightPanel.resize");
            compare(Shell.dispatchedActions[0].payload.width, 700);
            mouseDoubleClickSequence(edge, 3, 100);
            compare(Shell.dispatchedActions[Shell.dispatchedActions.length - 1].action, "rightPanel.resize");
            verify(Shell.dispatchedActions[Shell.dispatchedActions.length - 1].payload.width === undefined, "a double click resets it");
        }

        function test_maximizeIsOfferedOnlyWhereTheLayoutHidesTheThread() {
            Shell.state = Object.assign({}, Shell.state, { panel: panelState("diff") });
            const panel = createTemporaryObject(panelComponent, root);
            const button = findChild(panel, "panelMaximize");
            verify(!button.visible);
            panel.canMaximize = true;
            verify(button.visible);
            mouseClick(button);
            compare(Shell.dispatchedActions[Shell.dispatchedActions.length - 1].action, "rightPanel.toggleMaximized");
            const maximized = panelState("diff");
            maximized.maximized = true;
            Shell.state = Object.assign({}, Shell.state, { panel: maximized });
            verify(panel.maximized);
            verify(!findChild(panel, "panelEdge").visible, "a maximized panel has no edge to drag");
        }

        // Scenario: Right panel contents survive a visit to settings
        // (features/navigation/layout.feature): off the thread there is no
        // panel, and coming back shows the same body, scrolled where it was.
        function test_nativeBodySurvivesSettings() {
            Panel.diff = createTemporaryObject(fakeDiff, root);
            Shell.state = Object.assign({}, Shell.state, { panel: panelState("diff") });
            const panel = createTemporaryObject(panelComponent, root);
            const diff = findChild(panel, "panelBody-diff");
            tryCompare(diff, "status", Loader.Ready);
            const body = diff.item;

            Shell.state = Object.assign({}, Shell.state, { panel: null });
            verify(!panel.open);
            verify(!diff.visible);
            compare(diff.item, body, "the body is kept while settings show");

            Shell.state = Object.assign({}, Shell.state, { panel: panelState("diff") });
            verify(diff.visible);
            compare(diff.item, body);
        }

        function test_agentsOpenTheirThreadAndCommandsDoNot() {
            const agents = createTemporaryObject(agentsComponent, root, { source: createTemporaryObject(fakeAgents, root) });
            const tax = findChild(agents, "agentRow-task-tax");
            const command = findChild(agents, "agentRow-turn-item:9");
            tryVerify(() => tax !== null && command !== null);
            verify(!findChild(agents, "agentsEmpty").visible);
            mouseClick(tax);
            compare(Shell.dispatchedActions.length, 1);
            compare(Shell.dispatchedActions[0].action, "rightPanel.openThread");
            compare(Shell.dispatchedActions[0].payload.threadKey, "env-a:thread-tax");
            mouseClick(command);
            compare(Shell.dispatchedActions.length, 1, "a command has no thread to open");
        }

        function test_agentsTabSaysWhenThereIsNothing() {
            const agents = createTemporaryObject(agentsComponent, root, { source: createTemporaryObject(fakeAgents, root) });
            agents.source.clear();
            tryVerify(() => findChild(agents, "agentsEmpty").visible);
        }

        function test_fileViewerWrapsOrScrollsSideways() {
            const source = createTemporaryObject(fakeFiles, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const lines = findChild(files, "fileLines");
            verify(lines);
            tryVerify(() => lines.visible);
            verify(lines.contentWidth > lines.width, "an unwrapped long line scrolls sideways");
            source.wrap = true;
            compare(lines.contentWidth, lines.width);
            compare(lines.flickableDirection, Flickable.VerticalFlick);
        }

        function test_revertAsksFirstAndCanKeepOrRestoreTheFiles() {
            const source = createTemporaryObject(fakeDiff, root);
            const diff = createTemporaryObject(diffComponent, root, { source: source });
            const dialog = findChild(diff, "revertDialog");
            verify(dialog);
            mouseClick(findChild(diff, "diffRevert"));
            compare(source.revertTurn, 3);
            tryVerify(() => dialog.opened);
            compare(source.confirmed.length, 0, "nothing is reverted before the user confirms");
            mouseClick(findChild(dialog.contentItem, "revertCancel"));
            tryVerify(() => !dialog.visible);
            compare(source.cancelled, 1);
            compare(source.confirmed.length, 0);

            mouseClick(findChild(diff, "diffRevert"));
            tryVerify(() => dialog.opened);
            mouseClick(findChild(dialog.contentItem, "revertKeepFiles"));
            compare(source.confirmed, [false]);
            tryVerify(() => !dialog.visible);

            mouseClick(findChild(diff, "diffRevert"));
            tryVerify(() => dialog.opened);
            mouseClick(findChild(dialog.contentItem, "revertFiles"));
            compare(source.confirmed, [false, true]);
            tryVerify(() => !dialog.visible);
        }

        function test_pullRequestsOpenInTheBrowserAndLinkFromTheField() {
            const source = createTemporaryObject(fakePullRequests, root);
            const panel = createTemporaryObject(pullRequestsComponent, root, { source: source });
            const row = findChild(panel, "pullRequestRow-42");
            tryVerify(() => row !== null && row.visible);
            verify(!findChild(panel, "pullRequestsEmpty").visible);
            mouseClick(row);
            compare(source.calls, ["open github.com/acme/shop#42"]);

            mouseClick(findChild(panel, "pullRequestsLink"));
            verify(source.linkOpen);
            const field = findChild(panel, "pullRequestsLinkField");
            tryVerify(() => field.visible && field.activeFocus);
            keySequence("#");
            keySequence("7");
            keyClick(Qt.Key_Return);
            compare(source.calls[1], "link #7");
            keyClick(Qt.Key_Escape);
            verify(!source.linkOpen, "Escape closes the field");
        }

        function test_pullRequestsOfAnUnreachableEnvironmentStayButOfferNothing() {
            const source = createTemporaryObject(fakePullRequests, root, { online: false });
            const panel = createTemporaryObject(pullRequestsComponent, root, { source: source });
            tryVerify(() => findChild(panel, "pullRequestRow-42") !== null);
            verify(findChild(panel, "pullRequestsOffline").visible);
            verify(!findChild(panel, "pullRequestsLink").enabled);
            verify(!findChild(panel, "pullRequestsRefresh").enabled);
        }

        function test_reviewCommentsFromItsConversationAndCopiesItsNumber() {
            const source = createTemporaryObject(fakeReview, root);
            const panel = createTemporaryObject(reviewComponent, root, { source: source });
            compare(findChild(panel, "reviewTitle").text, "Tax line fix");
            verify(findChild(panel, "reviewOverview").visible);
            mouseClick(findChild(panel, "reviewCopyNumber"));
            compare(source.calls, ["copy"]);

            mouseClick(findChild(panel, "reviewSection-conversation"));
            const reply = findChild(panel, "reviewReply");
            tryVerify(() => reply.visible);
            verify(!findChild(panel, "reviewComment").enabled, "nothing to send yet");
            mouseClick(reply);
            keySequence("o");
            keySequence("k");
            mouseClick(findChild(panel, "reviewComment"));
            compare(source.calls[1], "comment ok");
            compare(reply.text, "", "a sent comment leaves the field");

            mouseClick(findChild(panel, "reviewSection-code"));
            verify(findChild(panel, "reviewCode").visible);
        }

        function test_reviewOfAnUnreachableEnvironmentStaysButSendsNothing() {
            const source = createTemporaryObject(fakeReview, root, { online: false });
            const panel = createTemporaryObject(reviewComponent, root, { source: source });
            verify(findChild(panel, "reviewOffline").visible);
            verify(!findChild(panel, "reviewReload").enabled);
            compare(findChild(panel, "reviewTitle").text, "Tax line fix");
            panel.section = "conversation";
            verify(!findChild(panel, "reviewReply").enabled);
            verify(!findChild(panel, "reviewSubmit").enabled);
        }

        function test_previewsOpenInTheBrowserAndCloseFromTheRow() {
            const source = createTemporaryObject(fakePreviews, root);
            const panel = createTemporaryObject(previewsComponent, root, { source: source });
            const row = findChild(panel, "previewRow-tab-1");
            tryVerify(() => row !== null && row.visible);
            mouseClick(row);
            compare(source.calls, ["open tab-1"]);
            mouseClick(findChild(row, "previewClose"));
            compare(source.calls, ["open tab-1", "close tab-1"], "closing does not open the page");
            source.clear();
            tryVerify(() => findChild(panel, "previewsEmpty").visible);
        }
    }
}
