import QtQuick
import QtQuick.Controls.Basic
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

    // A layout with a button that has a tooltip.
    Component {
        id: tipWindowComponent
        ShellWindow {
            ShellButton {
                objectName: "tipButton"
                x: 40
                y: 50
                text: qsTr("Rename")
                toolTip: qsTr("Rename the thread")
            }
        }
    }

    // A control that is not a ShellButton, with its own tooltip.
    Component {
        id: plainTipWindowComponent
        ShellWindow {
            Button {
                objectName: "plainTip"
                x: 40
                y: 50
                text: "Collapse"
                hoverEnabled: true
                ToolTip.visible: hovered
                ToolTip.text: "Collapse all folders"
            }
        }
    }

    // Pressing "Open panel" puts "Add panel" where the pointer rests.
    Component {
        id: movingTipWindowComponent
        ShellWindow {
            ShellButton {
                objectName: "opener"
                x: 40
                y: 50
                width: 120
                text: "Open panel"
                onClicked: {
                    visible = false;
                    adder.x = 40;
                }
            }
            Button {
                id: adder
                objectName: "adder"
                x: 400
                y: 50
                width: 120
                text: "Add panel"
                hoverEnabled: true
                ToolTip.visible: hovered
                ToolTip.text: "Add panel"
                ToolTip.delay: 0
            }
        }
    }

    TestCase {
        name: "ShellWindowTests"
        when: windowShown

        function cleanup() {
            Shell.reset();
            Theme.colors = {};
        }

        // Scenario: Tooltips follow the theme (features/desktop/themed-controls.feature)
        // Every attached tooltip shares one look: the popover's overlay fill,
        // solid, a strong hairline, the meta type step and a small radius. It
        // hides at once, and a press still puts it away.
        function test_toolTipsShareThePopoverLook() {
            // QML colours carry their alpha first: a translucent overlay.
            Theme.colors = { surfaceOverlay: "#cc18181b", borderStrong: "#3f3f46", text: "#eeeeee" };
            const window = createTemporaryObject(tipWindowComponent, null);
            verify(waitForRendering(window.contentItem));
            const button = findChild(window, "tipButton");
            const tip = window.contentItem.ToolTip.toolTip;
            mouseMove(button, button.width / 2, button.height / 2);
            tryVerify(() => tip.visible);
            compare(tip.text, "Rename the thread");
            compare(tip.background.objectName, "toolTipSurface");
            verify(Qt.colorEqual(tip.background.color, "#18181b"));
            verify(Qt.colorEqual(tip.background.border.color, "#3f3f46"));
            compare(tip.background.radius, Theme.radiusSm);
            // Drawn in the tip, not left where the look declared it.
            compare(tip.contentItem.parent, tip.background.parent);
            verify(tip.contentItem.visible);
            compare(tip.contentItem.font.pixelSize, Theme.type.meta.size);
            verify(Qt.colorEqual(tip.contentItem.color, "#eeeeee"));
            compare(tip.exit, null);

            Theme.colors = { surfaceOverlay: "#ffffff", borderStrong: "#d4d4d8", text: "#111111" };
            verify(Qt.colorEqual(tip.background.color, "#ffffff"));
            verify(Qt.colorEqual(tip.background.border.color, "#d4d4d8"));
            verify(Qt.colorEqual(tip.contentItem.color, "#111111"));

            mousePress(button, button.width / 2, button.height / 2);
            tryVerify(() => !tip.visible);
            mouseRelease(button, button.width / 2, button.height / 2);
        }

        // Scenario: A press hides any control's tooltip (features/desktop/themed-controls.feature)
        function test_aPressHidesAnyControlsToolTip() {
            const window = createTemporaryObject(plainTipWindowComponent, null);
            verify(waitForRendering(window.contentItem));
            const button = findChild(window, "plainTip");
            const tip = window.contentItem.ToolTip.toolTip;
            mouseMove(button, button.width / 2, button.height / 2);
            tryVerify(() => tip.visible);
            compare(tip.text, "Collapse all folders");
            mousePress(button, button.width / 2, button.height / 2);
            verify(!tip.visible);
            mouseRelease(button, button.width / 2, button.height / 2);
            verify(waitForRendering(window.contentItem));
            verify(!tip.visible);
        }

        // Scenario: A control that moves under a resting pointer shows no tooltip
        // (features/desktop/themed-controls.feature)
        function test_aControlMovingUnderARestingPointerShowsNoTip() {
            const window = createTemporaryObject(movingTipWindowComponent, null);
            verify(waitForRendering(window.contentItem));
            const opener = findChild(window, "opener");
            const adder = findChild(window, "adder");
            const tip = window.contentItem.ToolTip.toolTip;
            mouseMove(opener, 20, 10);
            mouseClick(opener, 20, 10);
            compare(adder.x, 40);
            tryVerify(() => adder.hovered);
            verify(!tip.visible);
            // Once the pointer moves over it, it is the control's to show.
            mouseMove(adder, 30, 12);
            tryVerify(() => tip.visible);
            compare(tip.text, "Add panel");
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

        // The layout fits the sidebar to the room the content has, the
        // window's width over the zoom: a zoom changes it as a resize does.
        function test_reportsTheRoomOnZoom() {
            const window = createTemporaryObject(windowComponent, null);
            verify(waitForRendering(window.contentItem));
            const reported = () => {
                const sent = Shell.dispatchedActions.filter(entry => entry.action === "layout.window");
                return sent[sent.length - 1].payload.width;
            };
            compare(reported(), window.width);
            Shell.state = Object.assign({}, Shell.state, { layout: { sidebarCollapsed: false, zoom: 1.5 } });
            tryCompare({ get value() { return reported(); } }, "value", Math.round(window.width / 1.5));
            Shell.state = Object.assign({}, Shell.state, { layout: { sidebarCollapsed: false, zoom: 1 } });
            tryCompare({ get value() { return reported(); } }, "value", window.width);
        }

        // The layout answers a report at once, as LayoutController does, and
        // that answer republishes the zoom: no binding loop.
        function test_zoomAnswerIsNoBindingLoop() {
            failOnWarning(/Binding loop/);
            const window = createTemporaryObject(windowComponent, null);
            verify(waitForRendering(window.contentItem));
            const answer = action => {
                if (action === "layout.window") {
                    Shell.state = Object.assign({}, Shell.state, { layout: Object.assign({}, Shell.state.layout) });
                }
            };
            Shell.actionRequested.connect(answer);
            Shell.state = Object.assign({}, Shell.state, { layout: { sidebarCollapsed: false, zoom: 1.5 } });
            wait(0);
            Shell.state = Object.assign({}, Shell.state, { layout: { sidebarCollapsed: false, zoom: 1 } });
            wait(0);
            Shell.actionRequested.disconnect(answer);
            compare(window.zoom, 1);
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
