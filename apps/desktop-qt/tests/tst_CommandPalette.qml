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
