import QtQuick
import QtQuick.Window
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// The frameless window's own buttons (WindowControls), and the header strip
// that doubles as its title bar (Workspace).
Item {
    id: root
    width: 200
    height: 100

    Component {
        id: windowComponent
        Window {
            id: window
            property alias controls: controls
            width: 480
            height: 320
            visible: true
            flags: Qt.Window | Qt.FramelessWindowHint
            WindowControls {
                id: controls
                anchors.right: parent.right
                window: window
            }
        }
    }

    Component {
        id: headerComponent
        Window {
            id: window
            property alias header: header
            width: 900
            height: 320
            visible: true
            flags: Qt.Window | Qt.FramelessWindowHint
            Workspace {
                id: header
                width: parent.width
                height: 52
                window: window
            }
        }
    }

    // A window that counts the system moves it is asked for: a real one
    // hands the pointer to the window manager, which an offscreen test lacks.
    Component {
        id: movingHeaderComponent
        Window {
            id: window
            property alias header: header
            property int moves: 0
            function startSystemMove() {
                moves += 1;
                return true;
            }
            width: 900
            height: 320
            visible: true
            flags: Qt.Window | Qt.FramelessWindowHint
            Workspace {
                id: header
                width: parent.width
                height: 52
                window: window
            }
        }
    }

    TestCase {
        name: "WindowControlsTests"
        when: windowShown

        function cleanup() {
            Shell.reset();
            Theme.frameless = false;
        }

        function control(window, name) {
            const row = window.controls;
            for (let i = 0; i < row.children.length; ++i) {
                if (row.children[i].text === name) {
                    return row.children[i];
                }
            }
            return null;
        }

        function names(window) {
            const row = window.controls;
            const found = [];
            for (let i = 0; i < row.children.length; ++i) {
                if (row.children[i].text !== undefined) {
                    found.push(row.children[i].text);
                }
            }
            return found;
        }

        function shown() {
            // Top-level, not transient for the test's window: each is active on its own.
            const window = createTemporaryObject(windowComponent, null);
            verify(!!window);
            verify(waitForRendering(window.contentItem));
            tryVerify(() => control(window, "Close") !== null);
            return window;
        }

        // Scenario: The window controls act on the window (features/navigation/windows.feature)
        function test_minimize() {
            const window = shown();
            mouseClick(control(window, "Minimize"));
            tryCompare(window, "visibility", Window.Minimized);
        }

        function test_maximize() {
            const window = shown();
            mouseClick(control(window, "Maximize"));
            tryCompare(window, "visibility", Window.Maximized);
        }

        function test_close() {
            const window = shown();
            mouseClick(control(window, "Close"));
            tryCompare(window, "visible", false);
        }

        // Scenario: Maximize restores a maximized window (features/navigation/windows.feature)
        function test_maximizeRestores() {
            const window = shown();
            window.showMaximized();
            tryCompare(window, "visibility", Window.Maximized);
            mouseClick(control(window, "Maximize"));
            tryCompare(window, "visibility", Window.Windowed);
        }

        // Scenario: Window controls follow the platform's order and side
        // (features/navigation/windows.feature), for the platform the test
        // runs on.
        function test_platformOrder() {
            const window = shown();
            compare(names(window), Qt.platform.os === "osx" ? ["Close", "Minimize", "Maximize"] : ["Minimize", "Maximize", "Close"]);
        }

        // Scenario: Window controls are announced by name (features/navigation/focus.feature)
        function test_announcedByName() {
            const window = shown();
            for (const name of ["Close", "Minimize", "Maximize"]) {
                const button = control(window, name);
                compare(button.Accessible.name, name);
                compare(button.Accessible.role, Accessible.Button);
            }
        }

        // The side of that Scenario Outline: the header's own controls end it,
        // except on macOS, where the system draws them on the left.
        function test_headerControlsSide() {
            Theme.frameless = true;
            Shell.state = {
                workspace: {
                    projectTitle: "Project",
                    threadTitle: "Thread",
                    isDraft: false,
                    renameRequestId: 0,
                    scripts: [],
                    editors: []
                }
            };
            const window = createTemporaryObject(headerComponent, null);
            verify(waitForRendering(window.contentItem));
            const controls = findChild(window.header, "windowControls");
            if (Qt.platform.os === "osx") {
                verify(!controls.visible);
                return;
            }
            verify(controls.visible);
            const right = controls.mapToItem(window.header, controls.width, 0).x;
            verify(right > window.header.width - 40, "controls end at " + right);
        }

        // A layout that draws the window's buttons itself (DefaultLayout): the
        // header has none, and keeps the corner they are in clear.
        function test_headerLeavesTheCornerToTheLayout() {
            Theme.frameless = true;
            Shell.state = {
                workspace: {
                    projectTitle: "Project",
                    threadTitle: "Thread",
                    isDraft: false,
                    renameRequestId: 0,
                    scripts: [],
                    editors: []
                }
            };
            const window = createTemporaryObject(headerComponent, null);
            window.header.windowControls = false;
            window.header.trailingInset = 104;
            window.header.panelToggle = false;
            verify(waitForRendering(window.contentItem));
            verify(!findChild(window.header, "windowControls").visible);
            const toggle = findChild(window.header, "panelToggle");
            verify(toggle.visible);
            tryVerify(() => Math.round(toggle.mapToItem(window.header, toggle.width, 0).x) === window.header.width - 104);
        }

        function test_trafficLightsShowSymbolsOnHover() {
            const window = shown();
            window.controls.trafficLights = true;
            const close = control(window, "Close");
            verify(!close.contentItem.children[0].visible);
            mouseMove(close);
            tryVerify(() => close.contentItem.children[0].visible);
            mouseMove(window.contentItem, 10, window.height - 10);
            tryVerify(() => !close.contentItem.children[0].visible);
        }

        // Scenario: macOS controls turn grey in an inactive window (features/navigation/windows.feature)
        function test_trafficLightsGreyWhenInactive() {
            const window = shown();
            window.controls.trafficLights = true;
            window.requestActivate();
            tryVerify(() => window.active);
            const close = control(window, "Close");
            compare(close.light, Qt.color("#ff5f57"));
            const other = createTemporaryObject(windowComponent, null);
            verify(waitForRendering(other.contentItem));
            other.requestActivate();
            tryVerify(() => other.active);
            tryVerify(() => !window.active);
            compare(close.light, Qt.color("#5b5b60"));
            window.requestActivate();
            tryVerify(() => window.active);
            compare(close.light, Qt.color("#ff5f57"));
        }

        // Scenario: Dragging the header asks the window system to move the window (features/navigation/windows.feature)
        function test_dragHeaderMovesWindow() {
            Theme.frameless = true;
            const window = createTemporaryObject(movingHeaderComponent, null);
            verify(waitForRendering(window.contentItem));
            // An empty part of the strip hands the drag to the system.
            mouseDrag(window.header, window.header.width / 2, 4, 60, 20);
            tryCompare(window, "moves", 1);
            // A framed window leaves it to the system's title bar.
            Theme.frameless = false;
            mouseDrag(window.header, window.header.width / 2, 4, 60, 20);
            compare(window.moves, 1);
        }

        // Scenario: Double-clicking the header toggles maximize (features/navigation/windows.feature)
        function test_doubleClickHeaderToggleMaximize() {
            Theme.frameless = true;
            Shell.state = {
                workspace: {
                    projectTitle: "Project",
                    threadTitle: "Thread",
                    isDraft: false,
                    renameRequestId: 0,
                    scripts: [],
                    editors: []
                }
            };
            const window = createTemporaryObject(headerComponent, null);
            verify(waitForRendering(window.contentItem));
            compare(window.visibility, Window.Windowed);
            // QtTest adds a double-click interval after every synthetic
            // release, so two clicks never reach a TapHandler as a double
            // tap. Drive the header's own handler instead, with the point a
            // real single tap on it hands over.
            const tap = findChild(window.header, "titleTap");
            verify(tap.enabled);
            let point = null;
            const capture = eventPoint => point = eventPoint;
            tap.tapped.connect(capture);
            mouseClick(window.header, window.header.width / 2, window.header.height / 2);
            tap.tapped.disconnect(capture);
            verify(point !== null);
            compare(window.visibility, Window.Windowed);
            tap.doubleTapped(point, Qt.LeftButton);
            tryCompare(window, "visibility", Window.Maximized);
            tap.doubleTapped(point, Qt.LeftButton);
            tryCompare(window, "visibility", Window.Windowed);
            // A framed window leaves it to the system's title bar.
            Theme.frameless = false;
            tryVerify(() => !tap.enabled);
        }
    }
}
