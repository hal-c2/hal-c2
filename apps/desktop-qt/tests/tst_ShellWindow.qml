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

    // A layout whose content asks for the shell's menu where the user
    // right-clicks, as the sidebar's rows do (point.scenePosition), and the
    // shell (MenuController) answers with `menu` at that point.
    Component {
        id: menuWindowComponent
        ShellWindow {
            Item {
                objectName: "content"
                anchors.fill: parent

                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onPressedChanged: {
                        if (pressed) {
                            Shell.state = Object.assign({}, Shell.state, {
                                menu: {
                                    requestId: "menu:1",
                                    surfaceId: "shell",
                                    x: point.scenePosition.x,
                                    y: point.scenePosition.y,
                                    items: [{ id: "rename", label: "Rename" }]
                                }
                            });
                        }
                    }
                }
            }
        }
    }

    // A layout with a select in its zoomed content.
    Component {
        id: comboWindowComponent
        ShellWindow {
            ShellComboBox {
                objectName: "combo"
                x: 40
                y: 50
                width: 200
                model: ["Alpha", "Beta"]
            }
        }
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

        // Scenario Outline: Zooming the app (features/navigation/windows.feature):
        // the content draws larger and lays out in the smaller room it leaves.
        function test_zoomScalesTheBody() {
            Shell.state = Object.assign({}, Shell.state, { layout: { sidebarCollapsed: false, zoom: 1.25 } });
            const window = createTemporaryObject(windowComponent, null);
            verify(waitForRendering(window.contentItem));
            const body = findChild(window.contentItem, "shellBody");
            compare(body.scale, 1.25);
            fuzzyCompare(body.width * body.scale, window.width, 0.01);
            fuzzyCompare(body.height * body.scale, window.height, 0.01);
            Shell.state = Object.assign({}, Shell.state, { layout: { sidebarCollapsed: false, zoom: 1 } });
            compare(body.scale, 1);
            compare(body.width, window.width);
        }

        // Scenario: Context menus follow the zoomed app (features/navigation/windows.feature)
        function test_menuAtThePointerWhenZoomed() {
            Shell.state = Object.assign({}, Shell.state, { layout: { sidebarCollapsed: false, zoom: 1.5 } });
            const window = createTemporaryObject(menuWindowComponent, null);
            verify(waitForRendering(window.contentItem));
            const content = findChild(window.contentItem, "content");
            // (200, 120) in the zoomed content is (300, 180) in the window.
            mousePress(content, 200, 120, Qt.RightButton);
            mouseRelease(content, 200, 120, Qt.RightButton);
            const menu = findChild(findChild(window.contentItem, "shellMenuHost"), "contextMenu");
            tryVerify(() => menu.visible);
            // Where it shows in the window, whatever its host's transform.
            const shown = menu.parent.mapToItem(null, menu.x, menu.y);
            fuzzyCompare(shown.x, 300, 1);
            fuzzyCompare(shown.y, 180, 1);
            menu.close();
        }

        // Every window menu is the shell's own: a menu the hidden page asks
        // for never shows.
        function test_pageMenusDoNotShow() {
            const window = createTemporaryObject(menuWindowComponent, null);
            verify(waitForRendering(window.contentItem));
            Shell.state = Object.assign({}, Shell.state, {
                contextMenu: { requestId: "page:1", surfaceId: "shell", x: 20, y: 20, items: [{ id: "rename", label: "Rename" }] }
            });
            wait(0);
            const menu = findChild(findChild(window.contentItem, "shellMenuHost"), "contextMenu");
            verify(!menu.visible);
            Shell.state = Object.assign({}, Shell.state, { contextMenu: null });
        }

        // Where an item draws in the window: its scene rect, whatever the
        // transforms (the body's, a popup's own) between.
        function sceneRect(item) {
            const topLeft = item.mapToItem(null, 0, 0);
            const bottomRight = item.mapToItem(null, item.width, item.height);
            return Qt.rect(topLeft.x, topLeft.y, bottomRight.x - topLeft.x, bottomRight.y - topLeft.y);
        }

        // Popups follow the zoom as the body does: a select's list opens
        // under it at its zoomed width.
        function test_selectPopupFollowsTheZoom() {
            Shell.state = Object.assign({}, Shell.state, { layout: { sidebarCollapsed: false, zoom: 2 } });
            const window = createTemporaryObject(comboWindowComponent, null);
            verify(waitForRendering(window.contentItem));
            const combo = findChild(window.contentItem, "combo");
            combo.popup.open();
            tryVerify(() => combo.popup.opened);
            const field = sceneRect(combo);
            const list = sceneRect(combo.popup.background);
            fuzzyCompare(field.width, 400, 1);
            fuzzyCompare(list.width, field.width, 1);
            fuzzyCompare(list.x, field.x, 1);
            fuzzyCompare(list.y, field.y + field.height + 8, 1);
            combo.popup.close();
        }

        // ...and a dialog in the overlay draws at the zoom, still centred.
        function test_dialogFollowsTheZoom() {
            Shell.state = Object.assign({}, Shell.state, { layout: { sidebarCollapsed: false, zoom: 2 } });
            const window = createTemporaryObject(windowComponent, null);
            verify(waitForRendering(window.contentItem));
            Shell.state = Object.assign({}, Shell.state, {
                confirmation: { requestId: "confirm:1", title: "Delete thread?", description: "", confirmLabel: "Delete" }
            });
            const dialog = findChild(window, "confirmDialog");
            tryVerify(() => dialog.opened);
            const shown = sceneRect(dialog.background);
            fuzzyCompare(shown.width, dialog.width * 2, 1);
            verify(shown.width <= window.width);
            fuzzyCompare(shown.x + shown.width / 2, window.width / 2, 1);
            fuzzyCompare(shown.y + shown.height / 2, window.height / 2, 1);
            Shell.state = Object.assign({}, Shell.state, { confirmation: null });
            tryVerify(() => !dialog.visible);
        }
    }
}
