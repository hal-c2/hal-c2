import QtQuick
import QtQuick.Controls.Basic
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

Item {
    id: root
    width: 600
    height: 400

TestCase {
    id: testCase
    name: "ShellEmptyStateTests"
    when: windowShown

    Component {
        id: emptyComponent
        ShellEmptyState {
            title: "No threads yet"
        }
    }

    SignalSpy {
        id: actionSpy
        signalName: "actionTriggered"
    }

    SignalSpy {
        id: secondarySpy
        signalName: "secondaryActionTriggered"
    }

    function findNamed(item, name) {
        if (item.objectName === name)
            return item;
        for (let i = 0; i < item.children.length; ++i) {
            const found = findNamed(item.children[i], name);
            if (found)
                return found;
        }
        return null;
    }

    function test_the_description_never_runs_past_two_lines() {
        const state = createTemporaryObject(emptyComponent, root, {
            description: "Start a thread from the composer below, or pick a project in the sidebar to see the threads it already has, and the ones that were archived, snoozed or moved here from another machine."
        });
        const description = findNamed(state, "emptyStateDescription");
        waitForRendering(state);
        verify(description.lineCount <= 2);
        verify(description.truncated);
    }

    function test_actions_show_only_when_named_and_report_which_ran() {
        const state = createTemporaryObject(emptyComponent, root);
        verify(!findNamed(state, "emptyStateAction").visible);
        verify(!findNamed(state, "emptyStateSecondaryAction").visible);
        state.actionText = "New thread";
        state.secondaryActionText = "Import";
        actionSpy.target = state;
        secondarySpy.target = state;
        actionSpy.clear();
        secondarySpy.clear();
        const action = findNamed(state, "emptyStateAction");
        const secondary = findNamed(state, "emptyStateSecondaryAction");
        verify(action.visible && secondary.visible);
        // The row lays the buttons out on the next polish.
        tryVerify(() => action.width > 0 && secondary.width > 0 && action.x !== secondary.x);
        mouseClick(action);
        compare(actionSpy.count, 1);
        compare(secondarySpy.count, 0);
        mouseClick(secondary);
        compare(secondarySpy.count, 1);
    }

    // Loading, empty and error share geometry, so nothing jumps between them.
    function test_loading_empty_and_error_keep_the_tile_and_title_in_place() {
        const state = createTemporaryObject(emptyComponent, root, { status: "loading", description: "Checking connected environments." });
        const icon = findNamed(state, "emptyStateIcon");
        const title = findNamed(state, "emptyStateTitle");
        waitForRendering(state);
        const iconY = icon.mapToItem(root, 0, 0).y;
        const titleY = title.mapToItem(root, 0, 0).y;
        for (const status of ["empty", "error"]) {
            state.status = status;
            state.actionText = status === "error" ? "Try again" : "";
            waitForRendering(state);
            compare(icon.mapToItem(root, 0, 0).y, iconY, status);
            compare(title.mapToItem(root, 0, 0).y, titleY, status);
            compare(icon.width, 40);
        }
    }
}
}
