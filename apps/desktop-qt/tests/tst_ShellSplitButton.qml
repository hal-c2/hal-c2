import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

Item {
    id: root
    width: 400
    height: 200

    Component {
        id: splitComponent
        ShellSplitButton {
            width: 160
            height: 24
        }
    }

    TestCase {
        name: "ShellSplitButtonTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        // Two split buttons in one header are told apart by their action, not both "More options".
        function test_each_menu_half_names_its_own_action() {
            const open = createTemporaryObject(splitComponent, root, { text: "Open" });
            const commit = createTemporaryObject(splitComponent, root, { text: "Commit" });
            compare(findChild(open, "menu").Accessible.name, "More Open options");
            compare(findChild(commit, "menu").Accessible.name, "More Commit options");
        }

        // A caller whose label changes with its state gives the menu one stable name.
        function test_a_caller_can_name_the_menu() {
            const commit = createTemporaryObject(splitComponent, root, { text: "Pushing 3s", menuName: "More Git options" });
            compare(findChild(commit, "menu").Accessible.name, "More Git options");
        }
    }
}
