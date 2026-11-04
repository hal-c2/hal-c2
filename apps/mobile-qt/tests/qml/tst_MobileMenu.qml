import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml/HalC2/Mobile"
import HalC2.Shell

// The phone's menu sheet over the fake `Shell`: which request it shows and
// what it answers. The rows are looked for in the window's overlay, where an
// open sheet's content is and a closed one's is not.
Item {
    id: root

    width: 390
    height: 800

    Component {
        id: menuComponent

        MobileMenu {}
    }

    function request(id, items) {
        return { requestId: id, surfaceId: "main", x: 0, y: 0, items: items };
    }

    function selections() {
        return Shell.dispatchedActions.filter(action => action.action === "menu.select").map(action => action.payload);
    }

    // The row for `id` on screen, or null.
    function row(id) {
        const found = test.findChild(root.Overlay.overlay, "mobileMenuItem:" + id);
        return found !== null && found.visible ? found : null;
    }

    TestCase {
        id: test

        name: "MobileMenu"
        when: windowShown

        function init() {
            Shell.reset();
            Shell.state = {};
        }

        function cleanup() {
            Shell.state = {};
            Shell.reset();
        }

        // A thread's "Move to another machine…" opens the machine choice: the
        // second request arrives while the first is still on its way out.
        function test_a_request_arriving_while_the_last_closes_stays_open() {
            const sheet = createTemporaryObject(menuComponent, root);
            Shell.state = { menu: request("r1", [{ id: "move", label: "Move to another machine…" }]) };
            tryVerify(() => sheet.opened);
            mouseClick(row("move"));
            compare(selections(), [{ requestId: "r1", id: "move" }]);
            Shell.state = { menu: null };
            tryVerify(() => sheet.opacity < 1);
            verify(sheet.visible);
            Shell.state = { menu: request("r2", [{ id: "m1", label: "ai-beast" }]) };
            tryVerify(() => sheet.opened);
            verify(row("move") === null);
            verify(row("m1") !== null);
            compare(selections(), [{ requestId: "r1", id: "move" }]);
            // A request gone always closes it, and answers nothing.
            Shell.state = { menu: null };
            tryVerify(() => !sheet.visible);
            verify(row("m1") === null);
            compare(selections(), [{ requestId: "r1", id: "move" }]);
        }

        function test_dismissing_the_sheet_answers_for_its_request() {
            const sheet = createTemporaryObject(menuComponent, root);
            Shell.state = { menu: request("r1", [{ id: "pin", label: "Pin" }]) };
            tryVerify(() => sheet.opened);
            keyClick(Qt.Key_Escape);
            tryVerify(() => !sheet.visible);
            compare(selections(), [{ requestId: "r1", id: null }]);
        }
    }
}
