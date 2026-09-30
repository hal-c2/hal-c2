import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

Item {
    id: root
    width: 700
    height: 600
    Component { id: component; GitActions { width: 300; height: 32 } }
    TestCase {
        name: "GitActionsTests"
        when: windowShown
        function init() {
            Shell.reset();
            Shell.state = { git: {
                available: true, isRepo: true, busy: false, isDefaultRef: false,
                quickAction: { kind: "run_action", label: "Commit", disabledReason: null },
                files: [{ path: "a.txt", insertions: 1, deletions: 0 }],
                menu: [], hints: [], canPublish: false, pendingDefaultBranch: null
            } };
        }
        function cleanup() { Shell.reset(); }
        // The first item under `item` whose text is `text`.
        function withText(item, text) {
            if (item.text === text) return item;
            for (const child of item.children) {
                const found = withText(child, text);
                if (found) return found;
            }
            return null;
        }
        function openCommitDialog() {
            let git = createTemporaryObject(component, root);
            verify(!!git, "Component exists");
            let dialog = findChild(git, "commitDialog");
            verify(!!dialog, "Object exists");
            dialog.open();
            tryCompare(dialog, "opened", true);
            return dialog;
        }
        // Scenario: Leaving every file out disables committing (features/source-control/commit-and-generated-messages.feature)
        function test_emptySelectionDisablesBothCommitActions() {
            let git = createTemporaryObject(component, root);
            verify(!!git, "Component exists");
            let dialog = findChild(git, "commitDialog");
            verify(!!dialog, "Object exists");
            dialog.open();
            tryVerify(() => findChild(dialog.contentItem, "fileCheck-a.txt") !== null);
            let checkbox = findChild(dialog.contentItem, "fileCheck-a.txt");
            verify(!!checkbox, "Object exists");
            let commit = findChild(dialog.contentItem, "commitSelected");
            verify(!!commit, "Object exists");
            let branch = findChild(dialog.contentItem, "commitNewBranch");
            verify(!!branch, "Object exists");
            mouseClick(checkbox);
            tryCompare(commit, "enabled", false);
            tryCompare(branch, "enabled", false);
            mouseClick(checkbox);
            tryCompare(commit, "enabled", true);
            tryCompare(branch, "enabled", true);
            mouseClick(commit);
            tryCompare(Shell, "dispatchCount", 1);
            tryCompare(Shell.dispatchedActions[0], "action", "git.commit");
        }
        // Scenario: Cancelling the commit leaves everything as it was (features/source-control/commit-and-generated-messages.feature)
        function test_cancellingTheCommitSendsNothing() {
            let dialog = openCommitDialog();
            let cancel = withText(dialog.contentItem, "Cancel");
            verify(!!cancel, "Cancel exists");
            mouseClick(cancel);
            tryCompare(dialog, "opened", false);
            compare(Shell.dispatchCount, 0);
        }
        // Scenario: Committing on the default branch carries a warning (features/source-control/commit-and-generated-messages.feature)
        function test_commitOnTheDefaultBranchWarns() {
            Shell.state = { git: Object.assign({}, Shell.state.git, { isDefaultRef: true, branch: "main" }) };
            let dialog = openCommitDialog();
            let warning = withText(dialog.contentItem, "Warning: committing on the default branch main");
            verify(!!warning, "the warning exists");
            verify(warning.visible, "the warning is shown");
        }
    }
}
