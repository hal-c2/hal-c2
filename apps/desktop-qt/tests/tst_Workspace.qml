import QtQuick
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
