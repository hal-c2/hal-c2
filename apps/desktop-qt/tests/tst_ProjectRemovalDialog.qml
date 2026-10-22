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

        function ask(threadCount = 2) {
            Shell.state = {
                projectRemoval: {
                    projectKey: "env-a:p1",
                    title: "shop",
                    workspaceRoot: "/work/shop",
                    threadCount: threadCount
                }
            };
        }

        // No translation is loaded, so the text has to spell out each count itself.
        function test_theThreadCountIsSpelledOutForEachCount_data() {
            return [
                {
                    tag: "none",
                    count: 0,
                    text: "It has no threads."
                },
                {
                    tag: "one",
                    count: 1,
                    text: "Its 1 thread and its conversation history will be cleared permanently."
                },
                {
                    tag: "many",
                    count: 3,
                    text: "Its 3 threads and their conversation history will be cleared permanently."
                }
            ];
        }

        function test_theThreadCountIsSpelledOutForEachCount(data) {
            const dialog = createTemporaryObject(dialogComponent, root);
            ask(data.count);
            tryVerify(() => dialog.opened);
            compare(findChild(dialog.contentItem, "projectRemovalThreads").text, data.text);
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
