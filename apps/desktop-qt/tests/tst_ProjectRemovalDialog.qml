import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

Item {
    id: root
    width: 600
    height: 400

    Component {
        id: dialogComponent
        ProjectRemovalDialog {}
    }

    TestCase {
        name: "ProjectRemovalDialogTests"
        when: windowShown

        function cleanup() {
            Shell.reset();
        }

        function ask() {
            Shell.state = {
                projectRemoval: {
                    projectKey: "env-a:p1",
                    title: "shop",
                    workspaceRoot: "/work/shop",
                    threadCount: 2
                }
            };
        }

        function test_opensForTheShellsQuestionAndClosesWithIt() {
            const dialog = createTemporaryObject(dialogComponent, root);
            verify(!dialog.visible);
            ask();
            tryVerify(() => dialog.opened);
            Shell.state = {
                projectRemoval: null
            };
            tryVerify(() => !dialog.visible);
            compare(Shell.dispatchedActions.length, 0);
        }

        function test_confirmAndCancelAnswerTheShell() {
            const dialog = createTemporaryObject(dialogComponent, root);
            ask();
            tryVerify(() => dialog.opened);
            mouseClick(findChild(dialog.contentItem, "projectRemovalConfirm"));
            mouseClick(findChild(dialog.contentItem, "projectRemovalCancel"));
            compare(Shell.dispatchedActions.map(entry => entry.action), ["project.remove.confirm", "project.remove.cancel"]);
        }
    }
}
