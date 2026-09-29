import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// The right panel's bodies: a native tab draws its brick and keeps it while
// another tab shows; only a page tab shows the page. The Files viewer's wrap
// and the Diff tab's revert confirmation.
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

    // An AgentsModel: a running subagent, a finished one, a running command.
    Component {
        id: fakeAgents
        ListModel {
            ListElement {
                agentId: "task-tax"; kind: "subagent"; title: "Tax tests"; status: "running"; statusLabel: "Working"
                elapsed: "12s"; detail: "Writing cart tests"; modelName: "gpt-5.5"; childThreadKey: "env-a:thread-tax"
            }
            ListElement {
                agentId: "task-docs"; kind: "subagent"; title: "Docs"; status: "failed"; statusLabel: "Failed"
                elapsed: "1m 15s"; detail: "No docs folder"; modelName: ""; childThreadKey: "env-a:thread-docs"
            }
            ListElement {
                agentId: "turn-item:9"; kind: "command"; title: "bun test cart"; status: "running"; statusLabel: "Working"
                elapsed: "3s"; detail: ""; modelName: ""; childThreadKey: ""
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

    function panelState(activeId) {
        return {
            threadKey: "env-a:thread-1",
            isOpen: true,
            activeId: activeId,
            embedPath: "",
            canAdd: { diff: true, files: true, agents: true, terminal: true, pullRequest: false },
            tabs: [
                { id: "diff", kind: "diff", title: "Diff", native: true },
                { id: "files", kind: "files", title: "Files", native: true },
                { id: "terminal:default", kind: "terminal", title: "Terminal", native: false }
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

        function test_nativeTabsKeepTheirBodyAndOnlyPageTabsShowThePage() {
            Panel.diff = createTemporaryObject(fakeDiff, root);
            Panel.files = createTemporaryObject(fakeFiles, root);
            Shell.state = Object.assign({}, Shell.state, { panel: panelState("diff") });
            const panel = createTemporaryObject(panelComponent, root);
            const diff = findChild(panel, "panelBody-diff");
            const files = findChild(panel, "panelBody-files");
            const page = findChild(panel, "panelPage");
            verify(diff && files && page);
            tryCompare(diff, "status", Loader.Ready);
            compare(diff.item.source, Panel.diff);
            verify(diff.visible);
            compare(files.active, false, "a tab not yet shown is not made");
            compare(page.visible, false);

            Shell.state = Object.assign({}, Shell.state, { panel: panelState("files") });
            tryCompare(files, "status", Loader.Ready);
            verify(files.visible && !diff.visible);
            compare(diff.active, true, "a hidden native tab is kept");
            compare(page.visible, false);

            Shell.state = Object.assign({}, Shell.state, { panel: panelState("terminal:default") });
            verify(page.visible);
            verify(!diff.visible && !files.visible);
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
    }
}
