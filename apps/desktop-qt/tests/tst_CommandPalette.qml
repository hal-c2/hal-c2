import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// The CommandPalette brick over the Palette mock: it follows `open`, takes the
// keyboard when it opens, and hands its keys to the palette.
Item {
    id: root
    width: 800
    height: 600

    Component { id: component; CommandPalette {} }

    TestCase {
        name: "CommandPaletteTests"
        when: windowShown

        function init() {
            PaletteModel.clear();
            for (let n = 1; n <= 3; ++n)
                PaletteModel.append({ title: "Entry " + n, description: "", group: "Actions", shortcut: "", kind: "action", runnable: true, current: false });
            PaletteModel.highlighted = 0;
            PaletteModel.query = "";
            PaletteModel.ran = [];
            PaletteModel.open = false;
            PaletteModel.mode = "command";
            PaletteModel.submitLabel = "";
            PaletteModel.submitShortcut = "";
            PaletteModel.submenu = "";
            PaletteModel.calls = [];
        }

        function opened() {
            const popup = createTemporaryObject(component, root);
            verify(!!popup);
            PaletteModel.show();
            tryCompare(popup, "opened", true);
            const field = findChild(popup.contentItem, "commandPaletteSearch");
            verify(!!field);
            tryVerify(() => field.activeFocus, 1000, "the search field has the keyboard");
            return popup;
        }

        function test_opensWithTheSearchFieldFocused() {
            opened();
        }

        function test_escapeDismisses() {
            const popup = opened();
            keyClick(Qt.Key_Escape);
            tryCompare(popup, "opened", false);
            compare(PaletteModel.open, false);
        }

        function test_escapeInAModeGoesBackToCommands() {
            const popup = opened();
            PaletteModel.mode = "files";
            keyClick(Qt.Key_Escape);
            compare(PaletteModel.mode, "command");
            compare(popup.opened, true);
        }

        function test_backspaceOnAnEmptyFieldLeavesTheSubmenu() {
            opened();
            PaletteModel.submenu = "Change theme";
            keyClick(Qt.Key_Backspace);
            compare(PaletteModel.submenu, "");
            compare(PaletteModel.calls, ["leaveSubmenu"]);
        }

        function test_theFieldFollowsTheQueryThePaletteMovesTo() {
            const popup = opened();
            const field = findChild(popup.contentItem, "commandPaletteSearch");
            PaletteModel.query = "~/code/";
            compare(field.text, "~/code/");
        }

        function test_modEnterAddsTheBrowsedFolder() {
            opened();
            keyClick(Qt.Key_Return, Qt.ControlModifier);
            compare(PaletteModel.calls, ["addBrowsedFolder"]);
        }

        function test_theBrowserNamesWhatEnterDoes() {
            const popup = opened();
            const submit = findChild(popup.contentItem, "commandPaletteSubmit");
            verify(!submit.visible, "nothing to add outside the folder browser");
            PaletteModel.mode = "browse";
            PaletteModel.submitLabel = "Create & Add";
            PaletteModel.submitShortcut = "Enter";
            verify(submit.visible);
            compare(submit.text, "Create & Add  Enter");
            PaletteModel.submitShortcut = "Ctrl+Enter";
            compare(submit.text, "Create & Add  Ctrl+Enter");
            mouseClick(submit);
            compare(PaletteModel.calls, ["addBrowsedFolder"]);
        }

        function test_typingSetsTheQuery() {
            opened();
            keyClick(Qt.Key_T);
            compare(PaletteModel.query, "t");
        }

        function test_arrowsAndEnterRunTheHighlight() {
            const popup = opened();
            keyClick(Qt.Key_Down);
            compare(PaletteModel.highlighted, 1);
            keyClick(Qt.Key_Return);
            compare(PaletteModel.ran, [1]);
            tryCompare(popup, "opened", false);
        }

        function test_onlyAPointerThatMovesTakesTheHighlight() {
            const popup = opened();
            const list = findChild(popup.contentItem, "commandPaletteList");
            verify(!!list);
            tryVerify(() => list.itemAtIndex(2) !== null);
            const at = list.itemAtIndex(2).mapToItem(list, 20, 10);
            mouseMove(list, at.x, at.y);
            mouseMove(list, at.x + 1, at.y);
            compare(PaletteModel.highlighted, 2);
            // New rows load under the resting pointer.
            PaletteModel.clear();
            for (let n = 1; n <= 3; ++n)
                PaletteModel.append({ title: "Folder " + n, description: "", group: "Directories", shortcut: "", kind: "action", runnable: true, current: false });
            PaletteModel.highlighted = 0;
            tryVerify(() => list.itemAtIndex(2) !== null);
            mouseMove(list, at.x + 1, at.y);
            compare(PaletteModel.highlighted, 0);
            mouseMove(list, at.x + 2, at.y);
            compare(PaletteModel.highlighted, 2);
            // The pointer moves over an empty list, and rows load under it there.
            PaletteModel.clear();
            PaletteModel.highlighted = -1;
            tryVerify(() => list.count === 0);
            mouseMove(list, at.x + 5, at.y);
            for (let n = 1; n <= 3; ++n)
                PaletteModel.append({ title: "Folder " + n, description: "", group: "Directories", shortcut: "", kind: "action", runnable: true, current: false });
            tryVerify(() => list.itemAtIndex(2) !== null);
            mouseMove(list, at.x + 5, at.y);
            compare(PaletteModel.highlighted, -1);
            mouseMove(list, at.x + 6, at.y);
            compare(PaletteModel.highlighted, 2);
        }

        function test_numberShortcutRunsTheNthEntry() {
            opened();
            keyClick(Qt.Key_3, Qt.ControlModifier);
            compare(PaletteModel.ran, [2]);
        }

        function test_closingTheShellPaletteClosesThePopup() {
            const popup = opened();
            PaletteModel.dismiss();
            tryCompare(popup, "opened", false);
        }
    }
}
