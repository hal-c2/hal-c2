import QtQuick
import QtQuick.Controls.Basic
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

Item {
    id: root
    width: 1200
    height: 100

    Component {
        id: workspaceComponent
        Workspace {
            width: 1100
            height: 52
        }
    }

    TestCase {
        name: "WorkspaceTests"
        when: windowShown

        function cleanup() {
            Shell.reset();
        }

        // Scenario: The thread title uses the room it has (features/navigation/layout.feature)
        function test_titleUsesAvailableSpace_data() {
            return [
                {
                    tag: "draft",
                    title: qsTr("New thread")
                },
                {
                    tag: "thread",
                    title: qsTr("Fix TUI Readability Issue")
                },
                {
                    tag: "long",
                    title: qsTr("Review the desktop shell and its shared widgets")
                }
            ];
        }

        function test_titleUsesAvailableSpace(data) {
            Shell.state = {
                workspace: {
                    projectTitle: qsTr("Project"),
                    threadTitle: data.title,
                    isDraft: false,
                    renameRequestId: 0,
                    scripts: [],
                    editors: []
                }
            };
            let workspace = createTemporaryObject(workspaceComponent, root);
            verify(!!workspace, "Component exists");
            let label = findChild(workspace, "threadLabel");
            verify(!!label, "Object exists");
            verify(waitForRendering(workspace));
            compare(label.truncated, false);
            workspace.width = 160;
            tryCompare(label, "truncated", true);
            workspace.width = 1100;
            tryCompare(label, "truncated", false);
        }

        // Scenario: The thread title uses the room it has, and Scenario: The full
        // thread title is a hover away (features/navigation/layout.feature)
        function test_tightHeaderKeepsTheTitleReadable() {
            Shell.state = {
                workspace: {
                    projectTitle: qsTr("positron-experiments"),
                    threadTitle: qsTr("Isolated Maude Critical Behaviour"),
                    isDraft: false,
                    renameRequestId: 0,
                    scripts: [],
                    editors: []
                }
            };
            let workspace = createTemporaryObject(workspaceComponent, root);
            verify(!!workspace, "Component exists");
            let label = findChild(workspace, "threadLabel");
            let project = findChild(workspace, "projectLabel");
            let slot = findChild(workspace, "titleSlot");
            // Hardly any room: the title still shows more than an ellipsis.
            workspace.width = 150;
            tryCompare(label, "truncated", true);
            verify(label.width >= 40, "title is " + label.width + " wide");
            verify(project.truncated);
            // The whole names are a hover away.
            mouseMove(slot, 10, slot.height / 2);
            tryCompare(slot.ToolTip, "visible", true);
            compare(slot.ToolTip.text, "Isolated Maude Critical Behaviour");
            mouseMove(project, 4, project.height / 2);
            tryCompare(project.ToolTip, "visible", true);
            compare(project.ToolTip.text, "positron-experiments");
            // A title that fits needs no tooltip.
            workspace.width = 1100;
            tryCompare(label, "truncated", false);
            mouseMove(slot, 10, slot.height / 2);
            wait(600);
            verify(!slot.ToolTip.visible);
        }
        // Scenario: A tight header drops actions before anything overlaps
        // (features/navigation/layout.feature)
        function test_tightHeaderNeverOverlaps_data() {
            return [
                { tag: "beside a docked panel", width: 360, inset: 0 },
                { tag: "under the window buttons", width: 480, inset: 104 },
                { tag: "half a screen", width: 704, inset: 104 }
            ];
        }

        function test_tightHeaderNeverOverlaps(data) {
            Shell.state = {
                workspace: {
                    projectTitle: qsTr("positron-experiments"),
                    threadTitle: qsTr("Isolated Maude Critical Behaviour"),
                    isDraft: false,
                    renameRequestId: 0,
                    scripts: [{ id: "test", name: "Test", icon: "play" }],
                    preferredScriptId: null,
                    editors: [{ id: "zed", label: "Zed" }],
                    preferredEditorId: "zed"
                },
                git: {
                    available: true, isRepo: true, busy: false, isDefaultRef: false,
                    quickAction: { kind: "run_action", label: "Commit", disabledReason: null },
                    files: [], menu: [], hints: [], canPublish: false, pendingDefaultBranch: null
                }
            };
            let workspace = createTemporaryObject(workspaceComponent, root, {
                panelToggle: false,
                detailsToggle: false,
                windowControls: false,
                trailingInset: data.inset
            });
            verify(!!workspace, "Component exists");
            workspace.width = data.width;
            verify(waitForRendering(workspace));
            const names = ["projectLabel", "titleSlot", "runActionButton", "openEditorButton", "gitActions", "terminalToggle", "threadDetailsToggle", "panelToggle"];
            let end = 0;
            let shown = [];
            for (const name of names) {
                const item = findChild(workspace, name);
                verify(!!item, name);
                if (!item.visible)
                    continue;
                shown.push(name);
                const left = item.mapToItem(workspace, 0, 0).x;
                verify(left >= end, name + " starts at " + left + ", over what ends at " + end);
                end = left + item.width;
            }
            // All of it inside the strip, clear of the window's buttons.
            verify(end <= data.width - Math.max(20, data.inset), "ends at " + end);
            verify(findChild(workspace, "threadLabel").width >= 40);
            verify(shown.indexOf("panelToggle") >= 0 && shown.indexOf("threadDetailsToggle") >= 0 && shown.indexOf("gitActions") >= 0);
            // The pills are the first to go, and are back with room.
            compare(shown.indexOf("openEditorButton") >= 0, workspace.room >= 520);
            workspace.width = 1100;
            tryCompare(findChild(workspace, "openEditorButton"), "visible", true);
            verify(findChild(workspace, "runActionButton").visible);
        }

        // Scenario: A narrow header drops action labels (features/navigation/layout.feature)
        function test_narrowHeaderDropsActionLabels() {
            Shell.state = {
                workspace: {
                    projectTitle: qsTr("Project"),
                    threadTitle: qsTr("Thread"),
                    isDraft: false,
                    renameRequestId: 0,
                    scripts: [{ id: "test", name: "Test", icon: "play" }],
                    preferredScriptId: null,
                    editors: [{ id: "zed", label: "Zed" }],
                    preferredEditorId: "zed"
                }
            };
            let workspace = createTemporaryObject(workspaceComponent, root);
            verify(!!workspace, "Component exists");
            let run = findChild(findChild(workspace, "runActionButton"), "splitAction");
            let open = findChild(findChild(workspace, "openEditorButton"), "splitAction");
            verify(!!run && !!open, "Header actions exist");
            compare(run.text, "Run Test");
            compare(open.text, "Open");
            workspace.width = 719;
            tryCompare(run, "text", "");
            compare(open.text, "");
            // They keep their names for assistive technology.
            compare(run.Accessible.name, "Run Test");
            compare(open.Accessible.name, "Open");
            workspace.width = 720;
            tryCompare(run, "text", "Run Test");
            compare(open.text, "Open");
        }
    }
}
