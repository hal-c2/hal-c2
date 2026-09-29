import QtQuick
import QtQuick.Window
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// The window every layout starts from (ShellWindow), as each window opens it:
// a new window (window.new) shows no thread yet.
Item {
    id: root
    width: 200
    height: 100

    Component {
        id: windowComponent
        ShellWindow {}
    }

    TestCase {
        name: "ShellWindowTests"
        when: windowShown

        function cleanup() {
            Shell.reset();
        }

        // Scenario: A window has a sensible title and size (features/navigation/windows.feature)
        function test_sensibleTitleAndSize() {
            Shell.state = Object.assign({}, Shell.state, { route: { kind: "home", title: null } });
            const window = createTemporaryObject(windowComponent, null);
            verify(!!window);
            verify(waitForRendering(window.contentItem));
            compare(window.title, "HAL-C2");
            compare(window.minimumWidth, 640);
            compare(window.minimumHeight, 400);
            verify(window.width >= 640 && window.height >= 400);
            // Once it shows a thread the title is the thread's.
            Shell.state = Object.assign({}, Shell.state, { route: { kind: "thread", title: "Tax line" } });
            compare(window.title, "Tax line — HAL-C2");
        }
    }
}
