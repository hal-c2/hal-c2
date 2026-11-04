import QtQuick
import QtQuick.Layouts
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// The right panel's bodies: each tab draws its brick and keeps it while
// another tab shows. Its edge resizes it and its header button opens the
// active tab in the thread's centre.
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
        id: menuItemComponent
        ShellMenuItem {
            width: 200
            text: "Commit"
            enabled: false
            reason: "No uncommitted changes in this branch at all."
        }
    }

    Component {
        id: detailsComponent
        ThreadDetailsPanel {
            width: 280
            height: 700
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
            property string renderKind: ""
            property string renderedText: ""
            property bool editing: false
            property var tree: null
            property ListModel lines: ListModel {
                property int maxColumns: 400
                property color background
                property int columnLimit: 2000
                ListElement {
                    number: 1
                    styled: ""
                    text: "export const rates = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7];"
                }
            }
            property int closed: 0
            property bool outsideProject: false
            function closeFile() { closed += 1; }
            property var opened: []
            function openFile(path, line) { opened = opened.concat([path]); }
            signal revealRequested
        }
    }

    // A one-entry file tree for focus tests through a real delegate.
    Component {
        id: fakeTree
        ListModel {
            property string rootStatus: "ready"
            property bool allExpanded: false
            property string selectedPath: ""
            function toggle(path) {}
            function retry(path) {}
            function collapseAll() { allExpanded = false; }
            function expandAll() { allExpanded = true; }
            function rowOf(path) { return path === "src/app.ts" ? 0 : -1; }
            ListElement {
                path: "src/app.ts"; name: "app.ts"; depth: 0; kind: "file"; expanded: false; ignored: false; problem: ""; selected: false
            }
        }
    }

    // A folder and a file at the root, keeping which folders were toggled.
    Component {
        id: fakeFolderTree
        ListModel {
            property string rootStatus: "ready"
            property bool allExpanded: false
            property string selectedPath: ""
            property var toggled: []
            function toggle(path) { toggled = toggled.concat([path]); }
            function retry(path) {}
            function collapseAll() {}
            function expandAll() {}
            function rowOf(path) { return -1; }
            ListElement {
                path: "src"; name: "src"; depth: 0; kind: "directory"; expanded: false; ignored: false; problem: ""; selected: false
            }
            ListElement {
                path: "README.md"; name: "README.md"; depth: 0; kind: "file"; expanded: false; ignored: false; problem: ""; selected: false
            }
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

    // A thread's ThreadDiff with its rows loaded; its lines can be commented on.
    Component {
        id: reviewedDiff
        QtObject {
            property var choices: [{ value: -1, label: "Latest turn" }, { value: 0, label: "All changes" }]
            property int selection: 0
            property string status: "ready"
            property bool wrap: false
            property bool reviewing: false
            property var model: null
            signal revealRow(int row)
        }
    }

    // A DiffModel with one hunk of a file: a kept, a removed and an added line.
    Component {
        id: fakeDiffRows
        ListModel {
            property bool split: false
            property int fileCount: 1
            property int additions: 1
            property int deletions: 1
            property int maxColumns: 40
            property bool allExpanded: true
            function path(file) { return "src/cart.ts"; }
            function tree() { return []; }
            function toggle(file) {}

            Component.onCompleted: {
                const row = { file: 0, path: "", previousPath: "", change: "modified", binary: false, additions: 0, deletions: 0, expanded: true, text: "", sign: "", oldLine: 0, newLine: 0, rightText: "", rightSign: "", state: "", note: "", partial: false };
                append(Object.assign({}, row, { kind: "file", path: "src/cart.ts", additions: 1, deletions: 1 }));
                append(Object.assign({}, row, { kind: "hunk", path: "@@ -1017,6 +1018,13 @@ defmodule HalC2.Codex.ThreadRuntime do a header far wider than the panel it is shown in" }));
                append(Object.assign({}, row, { kind: "line", sign: " ", text: "kept", oldLine: 1017, newLine: 1018 }));
                append(Object.assign({}, row, { kind: "line", sign: "-", text: "removed", oldLine: 1018 }));
                append(Object.assign({}, row, { kind: "line", sign: "+", text: "added", newLine: 1019 }));
            }
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
            property string reference: ""
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
                host: "github.com"; linkedNote: "Linked by you · 1h ago"; depth: 0; stackSize: 0; stackNote: ""
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
            Theme.fontScale = 1;
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

        function test_theKeyboardMovesTheEdgeWithinTheLayoutsRoom() {
            Shell.state = Object.assign({}, Shell.state, { panel: panelState("diff") });
            const panel = createTemporaryObject(panelComponent, root, { x: 450, maximumWidth: 550 });
            const edge = findChild(panel, "panelEdge");
            edge.forceActiveFocus();
            keyClick(Qt.Key_Left);
            compare(Shell.dispatchedActions[Shell.dispatchedActions.length - 1].payload.width, 550, "Left widens the panel, as far as the thread's room");
            keyClick(Qt.Key_Right);
            compare(Shell.dispatchedActions[Shell.dispatchedActions.length - 1].payload.width, 524, "Right narrows it");
            keyClick(Qt.Key_Return);
            verify(Shell.dispatchedActions[Shell.dispatchedActions.length - 1].payload.width === undefined, "Enter resets it");
        }

        // Scenario: The panel's tab opens in the thread's centre
        // (features/desktop/stage.feature).
        function test_openInCentreMovesTheActiveTabToTheStage() {
            Shell.state = Object.assign({}, Shell.state, { panel: panelState("diff") });
            const panel = createTemporaryObject(panelComponent, root);
            const button = findChild(panel, "panelMaximize");
            verify(button.visible);
            compare(button.Accessible.name, "Open in centre");
            mouseClick(button);
            const last = Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
            compare(last.action, "rightPanel.dock");
            compare(last.payload.id, "diff");
            compare(last.payload.dock, "stage");
            compare(last.payload.focus, true);
            const closed = panelState("diff");
            closed.isOpen = false;
            Shell.state = Object.assign({}, Shell.state, { panel: closed });
            verify(!button.visible, "a closed panel offers nothing to move");
        }

        // Tabs on the stage leave the panel's strip.
        function test_stagedTabsLeaveTheStrip() {
            const state = panelState("files");
            state.tabs = [{ id: "diff", kind: "diff", title: "Diff", dock: "stage" }, { id: "files", kind: "files", title: "Files" }];
            Shell.state = Object.assign({}, Shell.state, { panel: state });
            const panel = createTemporaryObject(panelComponent, root);
            compare(panel.docked.length, 1);
            compare(panel.docked[0].id, "files");
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

        function test_menuItemShowsItsReasonInFull() {
            const item = createTemporaryObject(menuItemComponent, root);
            const reason = findChild(item, "menuItemReason");
            verify(reason && reason.visible);
            compare(reason.text, item.reason);
            verify(reason.lineCount > 1, "the reason wraps instead of eliding");
            verify(item.implicitHeight >= 28 + reason.contentHeight, "the row grows to hold it");
            verify(reason.width <= item.width);
            item.reason = "";
            verify(!reason.visible);
            compare(item.implicitHeight, 28);
        }

        function test_unavailablePullRequestKindsSayWhy() {
            const state = panelState("diff");
            state.canAdd = { diff: true, files: true, agents: true, terminal: true, pullRequests: false, pullRequest: false };
            state.addReasons = { pullRequests: "No linked pull requests are available for this thread.", pullRequest: "This thread's branch has no pull request yet." };
            Shell.state = Object.assign({}, Shell.state, { panel: state });
            const panel = createTemporaryObject(panelComponent, root);
            mouseClick(findChild(panel, "panelAdd"));
            const list = findChild(panel, "panelAddPullRequests");
            const review = findChild(panel, "panelAddPullRequest");
            verify(list && review);
            verify(!list.enabled && !review.enabled);
            compare(findChild(list, "menuItemReason").text, state.addReasons.pullRequests);
            compare(findChild(review, "menuItemReason").text, state.addReasons.pullRequest);
            verify(list.iconName !== review.iconName, "the two kinds have their own icons");
        }

        function test_panelHasALeadingBorder() {
            Shell.state = Object.assign({}, Shell.state, { panel: panelState("diff") });
            const panel = createTemporaryObject(panelComponent, root);
            const border = findChild(panel, "panelBorder");
            verify(border && border.visible);
            compare(border.x, 0);
            compare(border.width, 1);
            compare(border.color, Theme.palette.color("border", "#27272a"));
        }

        function test_tabsThatDoNotFitScrollAndKeepTheActiveOneInView() {
            const state = panelState("diff");
            state.tabs = ["Diff", "Files", "Agents", "Previews", "Terminal with a long name", "Device"].map((title, i) => ({ id: "t" + i, kind: "diff", title: title }));
            state.activeId = "t0";
            Shell.state = Object.assign({}, Shell.state, { panel: state });
            const panel = createTemporaryObject(panelComponent, root, { width: 420 });
            const scroll = findChild(panel, "panelScrollTabs");
            tryVerify(() => scroll.visible, 1000, "overflowing tabs get scroll buttons");
            compare(findChild(panel, "panelScrollLeft").enabled, false);
            verify(findChild(panel, "panelScrollRight").enabled);

            const next = panelState("t5");
            next.tabs = state.tabs;
            Shell.state = Object.assign({}, Shell.state, { panel: next });
            const close = findChild(panel, "panelClose-t5");
            verify(close);
            const strip = findChild(panel, "panelTab-t5").parent.parent;
            tryVerify(() => {
                const p = close.mapToItem(strip.parent, close.width, 0).x;
                return p <= scroll.x + 1 && close.mapToItem(strip.parent, 0, 0).x >= strip.x;
            }, 1000, "the active tab and its close button are in view");
            verify(findChild(panel, "panelScrollLeft").enabled);
            const title = findChild(panel, "panelTab-t4");
            verify(title.width <= 112 + 13 + 20 + 2 * Theme.space.sm + 16, "a long title is capped");
        }

        function test_finishedSubagentsFoldUnderPreviousAgentsWithAFailedCount() {
            const relations = [{ threadKey: "e:fork", title: "A fork", relation: "Fork", status: "finished" },
                               { threadKey: "e:run", title: "Running one", relation: "Subagent", status: "running" }];
            for (let i = 0; i < 8; ++i)
                relations.push({ threadKey: "e:done" + i, title: "Done " + i, relation: "Subagent", status: i < 2 ? "failed" : "finished" });
            const details = createTemporaryObject(detailsComponent, root, { details: { environment: "e", online: true, project: "p", folder: "", checkout: "Local", branch: "", relations: relations } });
            compare(details.leading.length, 2);
            compare(details.previous.length, 8);
            compare(details.failedCount, 2);
            const previous = findChild(details, "threadDetailsPrevious");
            verify(previous.visible);
            verify(previous.text.indexOf("(8)") >= 0);
            compare(findChild(details, "threadDetailsFailed").text, "2 failed");
            verify(!findChild(details, "threadDetailsShowMore").visible, "closed, the two rows fit the first page");
            mouseClick(previous);
            compare(details.previousOpen, true);
            verify(findChild(details, "threadDetailsShowMore").visible, "6 rows, the rest behind Show more");
            compare(details.hiddenCount, 4);
            mouseClick(findChild(details, "threadDetailsShowMore"));
            compare(details.hiddenCount, 0);
            verify(!findChild(details, "threadDetailsShowMore").visible);
        }

        // An action whose name is longer than the column wraps onto a
        // second line rather than being cut, and its row grows to hold it.
        function test_detailsActionsWrapInsteadOfCutting() {
            Shell.reset();
            Shell.state = { projectActions: { projectKey: "p", file: "ok",
                scripts: [{ id: "s1", name: "Run the whole release build for every target", setup: false, shortcut: "Ctrl+Shift+R" }],
                imports: [{ name: "Setup Worktree" }] } };
            const details = createTemporaryObject(detailsComponent, root, { details: { environment: "e", online: true, project: "p", folder: "", checkout: "Local", branch: "", relations: [] } });
            const imported = findChild(details, "threadDetailsImport-Setup Worktree");
            const script = findChild(details, "threadDetailsAction-s1");
            verify(imported && script);
            for (const row of [imported, script]) {
                const label = findChild(row, "actionRowLabel");
                tryVerify(() => label.width > 0 && label.contentWidth <= label.width, 2000, row.text + " fits its row");
                verify(!label.truncated, "and is never cut");
                tryVerify(() => label.height >= label.implicitHeight && row.height >= label.implicitHeight + row.topPadding + row.bottomPadding, 2000, "inside its row");
                verify(row.mapToItem(details, row.width, 0).x <= details.width, "inside the column");
            }
            compare(imported.text, "Import Setup Worktree from hal-c2.json");
            // Just too narrow for the file name, which moves down whole
            // rather than breaking at its hyphen.
            const importLabel = findChild(imported, "actionRowLabel");
            const upToHyphen = Qt.createQmlObject("import QtQuick; TextMetrics {}", details);
            upToHyphen.font = importLabel.font;
            upToHyphen.text = "Import Setup Worktree from hal-";
            details.width += upToHyphen.advanceWidth + 2 - importLabel.width;
            tryVerify(() => Math.abs(importLabel.width - upToHyphen.advanceWidth - 2) < 1, 2000, "the label has room up to the hyphen");
            tryVerify(() => importLabel.lineCount === 2, 2000, "and wraps");
            // Its widest line is then short of "…from hal": no part of the
            // name stayed on the first line.
            upToHyphen.text = "Import Setup Worktree from hal";
            verify(importLabel.contentWidth < upToHyphen.advanceWidth, "hal-c2.json moved down whole; the widest line is " + importLabel.contentWidth + "px");
            const scriptLabel = findChild(script, "actionRowLabel");
            verify(scriptLabel.lineCount >= 2, "the long name takes a second line");
            tryVerify(() => script.height > Theme.control.md, 2000, "and its row grows to hold it");
            Shell.reset();
        }

        function test_relationRowsCentreTheirLabels() {
            const details = createTemporaryObject(detailsComponent, root, { details: { environment: "e", online: true, project: "p", folder: "", checkout: "Local", branch: "",
                relations: [{ threadKey: "e:fork", title: "A fork", relation: "Fork", status: "running" }] } });
            const row = findChild(details, "threadDetailsRelation");
            verify(row);
            const labels = row.contentItem.children[1];
            const top = labels.mapToItem(row, 0, 0).y;
            fuzzyCompare(top + labels.height / 2, row.height / 2, 1, "the two lines sit in the middle of the row");
            verify(top >= 0 && top + labels.height <= row.height, "and inside it");
        }

        function test_renderedPageLinksOpenOnCtrlClickAndOfferTheirMenu() {
            Shell.reset();
            const source = createTemporaryObject(fakeFiles, root, {
                rendered: true,
                renderKind: "html",
                renderedText: "<p>See <a href=\"https://example.com/docs\">the pricing docs</a> now.</p>"
            });
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const page = findChild(files, "fileRenderedPage");
            verify(page);
            tryVerify(() => page.visible && page.width > 0);
            let x = 0;
            const y = page.contentHeight / 2;
            while (x < page.width && page.linkAt(x, y) === "")
                x += 2;
            compare(page.linkAt(x + 4, y), "https://example.com/docs");
            mouseClick(page, x + 4, y);
            compare(Shell.openedExternally, [], "a plain click opens nothing");
            mouseClick(page, x + 4, y, Qt.LeftButton, Qt.ControlModifier);
            compare(Shell.openedExternally, ["https://example.com/docs"]);
            mouseClick(page, x + 4, y, Qt.RightButton);
            const menu = Shell.dispatchedActions.filter(a => a.action === "link.menu");
            compare(menu.length, 1);
            compare(menu[0].payload.url, "https://example.com/docs");
        }

        // The web's layout: the file beside the tree, not under it, and the tree can be hidden.
        function test_openFileSitsBesideTheTreeAndTheTreeCanBeHidden() {
            const source = createTemporaryObject(fakeFiles, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const viewer = findChild(files, "fileViewer");
            const explorer = findChild(files, "filesExplorer");
            const lines = findChild(files, "fileLines");
            verify(viewer && explorer && lines);
            tryVerify(() => viewer.visible);
            compare(viewer.height, files.height, "the file has the tab's whole height");
            compare(explorer.height, files.height);
            verify(viewer.x < explorer.x, "the tree is the side column");
            verify(viewer.width > explorer.width, "viewer " + viewer.width + " tree " + explorer.width);
            // Both columns stay inside a narrow tab: the tree is never wider than 46% of it.
            verify(explorer.width <= files.width * 0.46 + 1, "tree " + explorer.width + " of " + files.width);
            verify(viewer.x + viewer.width <= explorer.x && explorer.x + explorer.width <= files.width + 1, "viewer " + viewer.x + "+" + viewer.width + " tree " + explorer.x + "+" + explorer.width);
            verify(lines.height > 100, "lines " + lines.height);

            const toggle = findChild(files, "fileExplorerToggle");
            verify(toggle && toggle.checkable && toggle.checked, "the shown tree is a pressed toggle");
            mouseClick(toggle);
            verify(!explorer.visible);
            verify(!toggle.checked, "a hidden tree is an unpressed one");
            tryCompare(viewer, "width", files.width, 5000, "a hidden tree gives the file the whole tab");
            mouseClick(toggle);
            verify(explorer.visible);
            verify(toggle.checked, "a shown tree is pressed again");

            // The checked binding is live, not a click coincidence: setting
            // the preference directly moves the toggle too.
            files.explorerOpen = false;
            verify(!toggle.checked && !explorer.visible, "a programmatic hide unpresses the toggle");
            files.explorerOpen = true;
            verify(toggle.checked && explorer.visible, "a programmatic show presses the toggle");

            // Hiding is a preference: the next file opens with the tree still hidden.
            tryVerify(() => viewer.x + viewer.width <= explorer.x, 5000, "the file settles beside the tree before the next click");
            mouseClick(toggle);
            verify(!explorer.visible);
            const path = source.openPath;
            source.openPath = "";
            tryVerify(() => !viewer.visible);
            tryCompare(explorer, "width", files.width, 5000, "with no file the tree is the whole tab");
            source.openPath = path;
            tryVerify(() => viewer.visible);
            verify(!explorer.visible, "the tree stays hidden for the next file");
            mouseClick(toggle);
            verify(explorer.visible);
        }

        // In a phone-wide tab the header's buttons are the file's minimum: the tree gives
        // way, so none of them ends up under it. An editor installed adds its button.
        function test_theHeaderButtonsStayInTheFileInANarrowTab() {
            Shell.state = Object.assign({}, Shell.state, { workspace: { editors: [{ id: "vscode", label: "VS Code" }] } });
            const source = createTemporaryObject(fakeFiles, root);
            source.renderKind = "markdown";
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const viewer = findChild(files, "fileViewer");
            const explorer = findChild(files, "filesExplorer");
            verify(viewer && explorer);
            tryVerify(() => viewer.visible);
            // A phone-wide tab derived from the header's own minimum, so the
            // width does not depend on today's label lengths or font.
            tryVerify(() => viewer.Layout.minimumWidth > 0);
            verify(viewer.Layout.minimumWidth > 50 && viewer.Layout.minimumWidth < 400, "the header minimum is a sane width, not inflated by a stray child: " + viewer.Layout.minimumWidth);
            files.width = Math.ceil(viewer.Layout.minimumWidth) + 1 + files.explorerMinimum + 48;
            tryVerify(() => explorer.visible && viewer.x + viewer.width <= explorer.x + 0.5, 5000, "the file settles beside the tree");
            verify(files.explorerShare < files.width * 0.46 - 1, "the header, not the cap, limits the tree: share " + files.explorerShare + " of " + files.width);
            const names = ["fileRender", "fileEdit", "fileOpenInEditor", "fileWrap", "fileExplorerToggle", "fileClose"];
            for (const name of names) {
                const button = findChild(files, name);
                verify(button && button.visible, name);
                if (!button)
                    continue;
                const end = button.mapToItem(files, button.width, 0).x;
                verify(end <= explorer.x + 0.5, name + " ends at " + end + " but the tree starts at " + explorer.x);
            }
            tryVerify(() => explorer.x + explorer.width <= files.width + 0.5, 5000, "the tree settles inside the tab");
            verify(explorer.x + explorer.width <= files.width + 0.5, "tree " + explorer.x + "+" + explorer.width + " of " + files.width + ", file " + viewer.x + "+" + viewer.width);
            const close = findChild(files, "fileClose");
            mouseClick(close);
            compare(source.closed, 1, "the close button is reachable");
        }

        // A font scale can make the text buttons wider than the tab: they move into a
        // menu that does what they do, and the way out of the file stays on screen.
        function test_aLargeFontMovesTheHeaderTextButtonsIntoAMenu() {
            Shell.state = Object.assign({}, Shell.state, { workspace: { editors: [{ id: "vscode", label: "VS Code" }] } });
            const source = createTemporaryObject(fakeFiles, root);
            source.renderKind = "markdown";
            const files = createTemporaryObject(filesComponent, root, { source: source, width: 360 });
            const viewer = findChild(files, "fileViewer");
            const explorer = findChild(files, "filesExplorer");
            const textButtons = ["fileRender", "fileEdit", "fileWrap"].map(name => findChild(files, name));
            const menuButton = findChild(files, "fileHeaderMenu");
            tryVerify(() => viewer.visible);
            verify(textButtons.every(button => button.visible), "the buttons fit at the ordinary font");
            verify(!menuButton.visible);
            compare(files.headerFullWidth, viewer.Layout.minimumWidth, "the measure agrees with what the layout asks for");

            textButtons[2].forceActiveFocus();
            tryVerify(() => textButtons[2].activeFocus, 5000, "the Wrap button has focus before the font grows");
            Theme.fontScale = 4;
            tryVerify(() => files.headerFullWidth > 360, 5000, "the text outgrew the tab: " + files.headerFullWidth);
            tryVerify(() => menuButton.visible);
            verify(textButtons.every(button => !button.visible), "no text button is left to overflow");
            tryVerify(() => menuButton.activeFocus, 5000, "focus moves from a button that left to the menu that holds it");
            verify(!explorer.visible, "the tree still waits for the room the full header needs");
            for (const name of ["fileCopy", "fileOpenInEditor", "fileHeaderMenu", "fileExplorerToggle", "fileClose"]) {
                const button = findChild(files, name);
                verify(button.visible, name);
                tryVerify(() => button.mapToItem(files, button.width, 0).x <= files.width + 0.5, 5000, name + " stays inside the tab");
            }

            mouseClick(menuButton);
            const wrapItem = findChild(menuButton, "fileWrapItem");
            tryVerify(() => wrapItem && wrapItem.visible && wrapItem.height > 0);
            const wrapped = source.wrap;
            wrapItem.clicked();
            compare(source.wrap, !wrapped, "the menu does what the button did");

            mouseClick(findChild(files, "fileClose"));
            compare(source.closed, 1, "the close button is reachable");

            // The way back: the ordinary font brings the buttons out again.
            Theme.fontScale = 1;
            tryVerify(() => textButtons.every(button => button.visible) && !menuButton.visible);
        }

        // When the buttons come back, the ⋯ button leaves: focus on it, or in its open
        // menu, moves to a button still on screen rather than stay on the hidden one.
        function test_theHeaderMenuLeavingKeepsFocusOnAShownButton_data() {
            return [
                { tag: "on the button", menuOpen: false, outsideProject: false, home: "fileExplorerToggle" },
                { tag: "in the open menu", menuOpen: true, outsideProject: false, home: "fileExplorerToggle" },
                { tag: "no toggle outside the project", menuOpen: false, outsideProject: true, home: "fileClose" },
                { tag: "open menu, no toggle", menuOpen: true, outsideProject: true, home: "fileClose" }
            ];
        }
        function test_theHeaderMenuLeavingKeepsFocusOnAShownButton(data) {
            const source = createTemporaryObject(fakeFiles, root);
            source.outsideProject = data.outsideProject;
            source.renderKind = "markdown";
            const files = createTemporaryObject(filesComponent, root, { source: source, width: 360 });
            const menuButton = findChild(files, "fileHeaderMenu");
            const home = findChild(files, data.home);
            tryVerify(() => findChild(files, "fileViewer").visible);
            Theme.fontScale = 4;
            tryVerify(() => menuButton.visible);
            menuButton.forceActiveFocus();
            tryVerify(() => menuButton.activeFocus);
            const wrapItem = findChild(menuButton, "fileWrapItem");
            if (data.menuOpen) {
                mouseClick(menuButton);
                tryVerify(() => wrapItem.visible && wrapItem.height > 0, 5000, "the menu opened");
            }
            Theme.fontScale = 1;
            tryVerify(() => !menuButton.visible);
            tryVerify(() => !wrapItem.visible, 5000, "an open menu closes with its button");
            tryVerify(() => home.visible && home.activeFocus, 5000, "focus on " + files.Window.activeFocusItem);
        }

        // A tab too narrow to leave the tree room beside the header's buttons shows the
        // file alone: no sliver of a tree that still takes focus.
        function test_aTabTooNarrowForTheTreeShowsTheFileAlone() {
            const source = createTemporaryObject(fakeFiles, root);
            source.renderKind = "markdown";
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const viewer = findChild(files, "fileViewer");
            const explorer = findChild(files, "filesExplorer");
            tryVerify(() => viewer.visible);
            // Just under the panel's own threshold (the file's minimum plus
            // the divider plus the tree's floor), independent of the header's
            // label lengths or the test font.
            tryVerify(() => viewer.Layout.minimumWidth > 0);
            files.width = Math.floor(viewer.Layout.minimumWidth) + files.explorerMinimum;
            tryVerify(() => !explorer.visible, 5000, "the tree gives way to the file");
            verify(files.explorerShare < files.explorerMinimum, "share " + files.explorerShare);
            const searchField = findChild(files, "filesSearch");
            verify(searchField && searchField.visible === false, "the search field is not reachable");
            const toggle = findChild(files, "fileExplorerToggle");
            verify(toggle && files.explorerOpen, "the preference to show the tree is kept");
            verify(toggle && !toggle.checked, "the toggle presents the hidden tree, not the preference");
            verify(toggle && toggle.toolTip.length > 0, "the toggle says why the tree cannot come back yet");
            verify(toggle && toggle.Accessible.description === toggle.toolTip, "the widen hint reaches keyboard and screen-reader users, not only hover");
            compare(toggle.Accessible.name, "File explorer", "the name is stable; checked carries the state");
            // Clicking while auto-hidden must not desync checked or clear
            // the preference: checked snaps back and the tree still returns.
            mouseClick(toggle);
            verify(!toggle.checked && files.explorerOpen, "first auto-hidden click keeps the preference and unpresses");
            mouseClick(toggle);
            verify(!toggle.checked && files.explorerOpen, "second auto-hidden click still keeps the preference");
            files.width = 600;
            tryVerify(() => explorer.visible && explorer.width >= files.explorerMinimum, 5000, "a wider tab brings the tree back");
            verify(toggle.checked, "the toggle presents the tree again once it is back");
        }

        // Hiding by choice first, then narrowing: clicking the toggle while
        // auto-hidden must not leave it pressed over a hidden tree.
        function test_clickingTheToggleWhileAutoHiddenFromAChosenHideStaysHonest() {
            const source = createTemporaryObject(fakeFiles, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const viewer = findChild(files, "fileViewer");
            const explorer = findChild(files, "filesExplorer");
            const toggle = findChild(files, "fileExplorerToggle");
            verify(viewer && explorer && toggle);
            tryVerify(() => viewer.visible && explorer.visible);
            mouseClick(toggle);
            verify(!explorer.visible && !toggle.checked && !files.explorerOpen, "a chosen hide unpresses the toggle");
            tryVerify(() => viewer.Layout.minimumWidth > 0);
            files.width = Math.floor(viewer.Layout.minimumWidth) + files.explorerMinimum;
            tryVerify(() => !explorer.visible, 5000, "the tree stays hidden as the tab narrows");
            mouseClick(toggle);
            verify(!toggle.checked && files.explorerOpen, "the click asks for the tree without presenting it as shown");
            files.width = 600;
            tryVerify(() => explorer.visible && explorer.width >= files.explorerMinimum, 5000, "a wider tab brings the tree back");
            verify(toggle.checked, "the toggle presents the tree again once it is back");
        }

        // Narrowing the tab under the focused search field gives focus to
        // the toggle that brings the tree back, not to nowhere.
        function test_narrowingTheTabMovesFocusFromTheTreeToTheToggle() {
            const source = createTemporaryObject(fakeFiles, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const viewer = findChild(files, "fileViewer");
            const explorer = findChild(files, "filesExplorer");
            const search = findChild(files, "filesSearch");
            const toggle = findChild(files, "fileExplorerToggle");
            verify(viewer && explorer && search && toggle);
            tryVerify(() => viewer.visible && explorer.visible);
            search.forceActiveFocus();
            tryVerify(() => search.activeFocus, 5000, "the search field has focus before the tab narrows");
            tryVerify(() => viewer.Layout.minimumWidth > 0);
            files.width = Math.floor(viewer.Layout.minimumWidth) + files.explorerMinimum;
            tryVerify(() => !explorer.visible, 5000, "the tree gives way to the file");
            tryVerify(() => toggle.activeFocus, 5000, "focus lands on the toggle that brings the tree back");
        }

        // Same rescue when focus sits on a tree entry delegate, whose
        // parent chain reaches the explorer through the ListView.
        function test_narrowingTheTabMovesFocusFromATreeEntryToTheToggle() {
            const source = createTemporaryObject(fakeFiles, root);
            source.tree = createTemporaryObject(fakeTree, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const viewer = findChild(files, "fileViewer");
            const explorer = findChild(files, "filesExplorer");
            const entry = findChild(files, "filesEntry-src/app.ts");
            const toggle = findChild(files, "fileExplorerToggle");
            verify(viewer && explorer && entry && toggle);
            tryVerify(() => viewer.visible && explorer.visible && entry.visible);
            entry.forceActiveFocus();
            tryVerify(() => entry.activeFocus, 5000, "the tree entry has focus before the tab narrows");
            tryVerify(() => viewer.Layout.minimumWidth > 0);
            files.width = Math.floor(viewer.Layout.minimumWidth) + files.explorerMinimum;
            tryVerify(() => !explorer.visible, 5000, "the tree gives way to the file");
            tryVerify(() => toggle.activeFocus, 5000, "focus lands on the toggle that brings the tree back");
        }

        // The tree's floor is in font metrics, not px: it holds a row's icon and about
        // ten characters at the user's font size, so a larger font asks for more room.
        function test_theTreeMinimumFollowsTheFontScale() {
            const source = createTemporaryObject(fakeFiles, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const before = files.explorerMinimum;
            verify(before > 72, "room for ten characters, not a 72px sliver: " + before);
            try {
                Theme.fontScale = 2;
                tryVerify(() => files.explorerMinimum > before + 40, 5000, "a doubled font asks for more room: " + files.explorerMinimum);
            } finally {
                Theme.fontScale = 1;
            }
            tryVerify(() => files.explorerMinimum === before);
        }

        // A name the narrow tree elides is still reachable in full: the entry's
        // accessible description carries the path (the hover tooltip shows it when elided).
        function test_aTreeEntryCarriesItsFullPathForAssistiveTech() {
            const source = createTemporaryObject(fakeFiles, root);
            source.tree = createTemporaryObject(fakeTree, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const entry = findChild(files, "filesEntry-src/app.ts");
            tryVerify(() => entry && entry.visible);
            compare(entry.Accessible.name, "app.ts");
            compare(entry.Accessible.description, "src/app.ts");
        }

        // A mouse press held past the hold interval is still a click: it opens
        // the folder or the file it was on, and no menu.
        function test_aSlowClickOnATreeEntryStillOpensIt() {
            const source = createTemporaryObject(fakeFiles, root);
            source.tree = createTemporaryObject(fakeFolderTree, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const menu = findChild(files, "fileEntryMenu");
            tryVerify(() => findChild(files, "filesEntry-src")?.visible && findChild(files, "filesEntry-README.md")?.visible);
            const folder = findChild(files, "filesEntry-src");
            const file = findChild(files, "filesEntry-README.md");
            const held = Qt.styleHints.mousePressAndHoldInterval + 200;
            mousePress(folder);
            mouseRelease(folder, undefined, undefined, Qt.LeftButton, Qt.NoModifier, held);
            compare(source.tree.toggled, ["src"]);
            mousePress(file);
            mouseRelease(file, undefined, undefined, Qt.LeftButton, Qt.NoModifier, held);
            compare(source.opened, ["README.md"]);
            verify(!menu.visible, "a held mouse press opens no menu");
        }

        // A finger held on a file opens its menu, and lifting it doesn't open
        // the file as well; a tap still opens it.
        function test_aFingerHeldOnAFileOffersItsMenuInsteadOfOpeningIt() {
            const source = createTemporaryObject(fakeFiles, root);
            source.tree = createTemporaryObject(fakeFolderTree, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const menu = findChild(files, "fileEntryMenu");
            tryVerify(() => findChild(files, "filesEntry-README.md")?.visible);
            const file = findChild(files, "filesEntry-README.md");
            const touch = touchEvent(file);
            touch.press(0, file).commit();
            tryVerify(() => menu.visible, 3000, "the held file's menu opens");
            touch.release(0, file).commit();
            compare(menu.path, "README.md");
            compare(source.opened, []);
            menu.close();
            tryVerify(() => !menu.visible);
            touchEvent(file).press(0, file).commit().release(0, file).commit();
            compare(source.opened, ["README.md"]);
        }

        // A long press is skipped once, however the lift ends: a click with no
        // press before it (an accessibility press action) opens the file.
        function test_aClickAfterAHeldFingerStillOpensTheFile() {
            const source = createTemporaryObject(fakeFiles, root);
            source.tree = createTemporaryObject(fakeFolderTree, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const menu = findChild(files, "fileEntryMenu");
            tryVerify(() => findChild(files, "filesEntry-README.md")?.visible);
            const file = findChild(files, "filesEntry-README.md");
            const touch = touchEvent(file);
            touch.press(0, file).commit();
            tryVerify(() => menu.visible, 3000, "the held file's menu opens");
            touch.release(0, file).commit();
            menu.close();
            tryVerify(() => !menu.visible);
            compare(source.opened, []);
            // `click()` presses first; an accessibility press only clicks.
            file.clicked();
            compare(source.opened, ["README.md"]);
        }

        // A finger that slides off the held row before lifting doesn't click it,
        // and leaves nothing behind: its next press-less click opens the file.
        function test_aFingerSlidOffAHeldRowLeavesItClickable() {
            const source = createTemporaryObject(fakeFiles, root);
            source.tree = createTemporaryObject(fakeFolderTree, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const menu = findChild(files, "fileEntryMenu");
            tryVerify(() => findChild(files, "filesEntry-README.md")?.visible);
            const file = findChild(files, "filesEntry-README.md");
            const touch = touchEvent(file);
            touch.press(0, file).commit();
            tryVerify(() => menu.visible, 3000, "the held file's menu opens");
            touch.move(0, file, file.width / 2, file.height * 4).commit();
            touch.release(0, file, file.width / 2, file.height * 4).commit();
            menu.close();
            tryVerify(() => !menu.visible);
            compare(source.opened, []);
            file.clicked();
            compare(source.opened, ["README.md"]);
        }

        // Hiding the tree from its toggle (here through the preference the
        // toggle sets) under the focused search field rescues focus too.
        function test_hidingTheTreeMovesFocusFromTheTreeToTheToggle() {
            const source = createTemporaryObject(fakeFiles, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const explorer = findChild(files, "filesExplorer");
            const search = findChild(files, "filesSearch");
            const toggle = findChild(files, "fileExplorerToggle");
            verify(explorer && search && toggle);
            tryVerify(() => findChild(files, "fileViewer").visible && explorer.visible);
            search.forceActiveFocus();
            tryVerify(() => search.activeFocus, 5000, "the search field has focus before the tree hides");
            files.explorerOpen = false;
            tryVerify(() => !explorer.visible, 5000, "the tree hides");
            tryVerify(() => toggle.activeFocus, 5000, "focus lands on the toggle that brings the tree back");
        }

        // Opening a file while the hide preference is already set: the tree
        // was the whole tab, focused, and gives way as the file opens.
        function test_openingAFileWithTheTreeHiddenMovesFocusToTheToggle() {
            const source = createTemporaryObject(fakeFiles, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const viewer = findChild(files, "fileViewer");
            const explorer = findChild(files, "filesExplorer");
            const search = findChild(files, "filesSearch");
            const toggle = findChild(files, "fileExplorerToggle");
            verify(viewer && explorer && search && toggle);
            tryVerify(() => viewer.visible && explorer.visible);
            files.explorerOpen = false;
            tryVerify(() => !explorer.visible, 5000, "the tree hides for this file");
            const path = source.openPath;
            source.openPath = "";
            tryVerify(() => !viewer.visible && explorer.visible, 5000, "with no file the tree is the whole tab again");
            search.forceActiveFocus();
            tryVerify(() => search.activeFocus, 5000, "the search field has focus before the file opens");
            source.openPath = path;
            tryVerify(() => viewer.visible && !explorer.visible, 5000, "the file opens without the tree");
            tryVerify(() => toggle.activeFocus, 5000, "focus lands on the toggle that brings the tree back");
        }

        // Closing the file hides the viewer holding the toggle: focus goes
        // to the tree that is now the whole tab, not to nowhere.
        function test_closingTheFileMovesFocusFromTheViewerToTheTree() {
            const source = createTemporaryObject(fakeFiles, root);
            const files = createTemporaryObject(filesComponent, root, { source: source });
            const viewer = findChild(files, "fileViewer");
            const search = findChild(files, "filesSearch");
            const toggle = findChild(files, "fileExplorerToggle");
            verify(viewer && search && toggle);
            tryVerify(() => viewer.visible);
            toggle.forceActiveFocus();
            tryVerify(() => toggle.activeFocus, 5000, "the toggle has focus before the file closes");
            source.openPath = "";
            tryVerify(() => !viewer.visible, 5000, "the file closes");
            tryVerify(() => search.activeFocus, 5000, "focus lands on the tree's search field");
        }

        // Past the width where 46% would be more than the tree needs, the cap is 352px.
        function test_theTreeBesideAFileIsCappedInAWideTab() {
            const source = createTemporaryObject(fakeFiles, root);
            const files = createTemporaryObject(filesComponent, root, { source: source, width: 1200 });
            const explorer = findChild(files, "filesExplorer");
            tryVerify(() => findChild(files, "fileViewer").visible);
            tryCompare(explorer, "width", 352);
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

        // A line has no number on the side it is not on, the comment button
        // has its own column, and a long hunk header ends in view.
        function test_diffLinesNumberOnlyTheirOwnSide() {
            const source = createTemporaryObject(reviewedDiff, root, { model: createTemporaryObject(fakeDiffRows, root) });
            const diff = createTemporaryObject(diffComponent, root, { source: source, width: 360 });
            verify(diff.canComment);
            const view = findChild(diff, "diffRows");
            tryVerify(() => view.count === 5 && view.itemAtIndex(4) !== null);

            function numbers(index) {
                const line = view.itemAtIndex(index).item;
                return [findChild(line, "diffOldLine").text, findChild(line, "diffNewLine").text];
            }
            compare(numbers(2), ["1017", "1018"]);
            compare(numbers(3), ["1018", ""], "a removed line has no new number");
            compare(numbers(4), ["", "1019"], "an added line has no old number");

            const kept = view.itemAtIndex(2).item;
            const button = findChild(kept, "diffLineComment");
            const number = findChild(kept, "diffOldLine");
            const numberLeft = number.mapToItem(kept, 0, 0).x + number.width - number.contentWidth;
            verify(button.x + button.width <= numberLeft, "the comment button is left of the line number");

            const header = findChild(view.itemAtIndex(1).item, "diffHunkHeader");
            verify(header.truncated, "the header is elided");
            verify(header.mapToItem(view, header.width, 0).x <= view.width, "the header ends inside the panel");
        }

        // Wrapped, a long line's rest hangs under its own indentation;
        // unwrapped, the numbers and sign stay put while it scrolls sideways.
        function test_longDiffLinesKeepTheirShape() {
            const rows = createTemporaryObject(fakeDiffRows, root);
            const long = "        log: snapshot.state.thread_id, adopt: dir, offset: snapshot.offset, channel: snapshot.channel";
            rows.setProperty(2, "text", long);
            rows.maxColumns = long.length;
            const source = createTemporaryObject(reviewedDiff, root, { model: rows, wrap: true });
            const diff = createTemporaryObject(diffComponent, root, { source: source, width: 560, height: 300 });
            const view = findChild(diff, "diffRows");
            tryVerify(() => view.count === 5 && view.itemAtIndex(4) !== null);
            const line = view.itemAtIndex(2).item;
            const findWith = (item, property) => {
                if (item[property] !== undefined)
                    return item;
                for (let i = 0; i < item.children.length; ++i) {
                    const found = findWith(item.children[i], property);
                    if (found)
                        return found;
                }
                return null;
            };
            const text = findWith(line, "hang");
            verify(text.lineCount > 1, "the line wraps");
            verify(text.hang > 0, "under its indentation");
            compare(text.text, long.trim());
            compare(text.leftPadding, text.hang, "every line of it starts there, the wrapped rest too");
            compare(text.hang, 8 * (view.numbersWidth - Theme.space.sm) / 10, "eight spaces in");

            source.wrap = false;
            tryVerify(() => view.contentWidth > view.width, 2000, "unwrapped, the line is wider than the panel");
            const number = findChild(line, "diffOldLine");
            const before = number.mapToItem(view, 0, 0).x;
            view.contentX = view.originX + 120;
            compare(number.mapToItem(view, 0, 0).x, before, "the line numbers stay put");
            verify(text.mapToItem(view, 0, 0).x < view.gutter - 100, "while the line scrolls under them");
        }

        // Too narrow for about forty characters of code, the lines scroll
        // sideways whatever the setting says, and wrap again once wider.
        function test_aNarrowDiffScrollsInsteadOfWrapping() {
            const rows = createTemporaryObject(fakeDiffRows, root);
            const long = "        log: snapshot.state.thread_id, adopt: dir, offset: snapshot.offset, channel: snapshot.channel";
            rows.setProperty(2, "text", long);
            rows.maxColumns = long.length;
            const source = createTemporaryObject(reviewedDiff, root, { model: rows, wrap: true });
            const diff = createTemporaryObject(diffComponent, root, { source: source, width: 380, height: 300 });
            const view = findChild(diff, "diffRows");
            tryVerify(() => view.count === 5 && view.itemAtIndex(4) !== null);
            verify(diff.codeWidth < diff.wrapFloor, "a 380px sheet leaves too little room");
            verify(source.wrap && !diff.wrap, "the setting stays on, the lines do not wrap");
            verify(view.contentWidth > view.width, "the long line scrolls sideways");
            const number = findChild(view.itemAtIndex(2).item, "diffOldLine");
            const before = number.mapToItem(view, 0, 0).x;
            view.contentX = view.originX + 120;
            compare(number.mapToItem(view, 0, 0).x, before, "the line numbers stay put");
            // A thin bar along the bottom says they scroll...
            const bar = findChild(diff, "diffSidewaysBar");
            verify(bar.visible, "a bar shows the lines scroll sideways");
            verify(bar.height <= Theme.space.sm, "a thin one, not " + bar.height + "px");
            verify(Math.abs(bar.y + bar.height - view.height) < 0.5, "along the bottom");
            // ...and the code stops short of the edge: the last 8px of the
            // long line, cut mid-text, hold no ink.
            // Wherever it is scrolled to (a space can fill 8px by itself).
            const line = view.itemAtIndex(2).item;
            for (let step = 0; step < 4; ++step) {
                view.contentX = view.originX + 120 + step * Theme.space.xs;
                waitForRendering(diff);
                const shot = grabImage(diff);
                const origin = line.mapToItem(diff, 0, 0);
                const top = Math.ceil(origin.y);
                const right = Math.round(view.mapToItem(diff, view.width, 0).x);
                const blank = shot.pixel(right - 1, top + Math.floor(line.height / 2));
                let inked = 0;
                for (let x = right - 4 * Theme.space.sm; x < right; ++x) {
                    for (let y = top; y < top + Math.floor(line.height); ++y) {
                        if (x >= right - Theme.space.sm)
                            verify(Qt.colorEqual(shot.pixel(x, y), blank), "ink at " + x + "," + y + " of the end padding");
                        else if (!Qt.colorEqual(shot.pixel(x, y), blank))
                            ++inked;
                    }
                }
                verify(inked > 0, "the code runs up to the padding");
            }
            diff.width = 640;
            tryVerify(() => diff.wrap && view.contentWidth === view.width, 2000, "wide again, the lines wrap");
            verify(!bar.visible, "wrapped, nothing scrolls sideways");
            rows.split = true;
            verify(!diff.wrap, "a split half of 640px is too narrow as well");
        }

        // A turn with nothing to show names the turn and offers every change.
        function test_anEmptyTurnNamesItselfAndOffersAllChanges() {
            const source = createTemporaryObject(fakeDiff, root);
            const diff = createTemporaryObject(diffComponent, root, { source: source });
            const message = findChild(diff, "diffMessage");
            tryVerify(() => message.visible);
            compare(message.title, "No changes in the latest turn");
            compare(message.description, "No net changes in this selection.");
            compare(message.actionText, "Show all changes");
            message.actionTriggered();
            compare(source.selection, 0, "all changes are shown");
            compare(message.title, "No changes", "all of them have no turn to name");
            compare(message.actionText, "", "nor anything wider to offer");
            source.selection = 2;
            compare(message.title, "No changes in turn 2");
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
