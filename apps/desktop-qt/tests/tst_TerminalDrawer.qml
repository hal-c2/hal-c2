import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

TestCase {
    id: testCase
    name: "TerminalDrawerTests"
    width: 800
    height: 400
    when: windowShown

    // Surfaces in the real themes: `muted` is a surface (shadcn --muted), nearly
    // the canvas; the ink roles are the text ones.
    readonly property var roles: ({
            canvas: "#fcfcfc",
            muted: "#fafafa",
            text: "#18181b",
            textMuted: "#71717a"
        })

    Component {
        id: drawerComponent
        TerminalDrawer {
            width: 800
            height: 300
        }
    }

    function init() {
        Theme.colors = roles;
        Terminals.reset();
        Terminals.available = true;
        Terminals.open = true;
        Terminals.addTab("a", "one");
        Terminals.addTab("b", "two");
        Terminals.activeGroup = "b";
        Terminals.activeTerminalId = "b";
        Terminals.groupSizes = {
            a: 1,
            b: 1
        };
    }

    function cleanup() {
        Theme.colors = {};
        Terminals.reset();
    }

    function findChild(item, objectName) {
        if (item.objectName === objectName)
            return item;
        for (const child of item.children) {
            const hit = findChild(child, objectName);
            if (hit)
                return hit;
        }
        return null;
    }

    function findAll(item, objectName, out) {
        if (item.objectName === objectName)
            out.push(item);
        for (const child of item.children)
            findAll(child, objectName, out);
        return out;
    }

    function luminance(c) {
        const lin = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    }

    function contrast(a, b) {
        const la = luminance(a), lb = luminance(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    function test_toolbarIconsAreReadableAgainstTheCanvas() {
        const drawer = createTemporaryObject(drawerComponent, testCase);
        verify(drawer);
        for (const name of ["terminalSplit", "terminalSplitVertical", "terminalNew", "terminalClose"]) {
            const button = findChild(drawer, name);
            verify(button, name);
            verify(contrast(button.iconTint, Qt.color(roles.canvas)) >= 3, name + " icon is invisible: " + button.iconTint);
        }
    }

    function test_inactiveTabIsReadableAgainstTheCanvas() {
        const drawer = createTemporaryObject(drawerComponent, testCase);
        const tabs = findAll(drawer, "terminalTab", []);
        verify(tabs.length > 0);
        for (const tab of tabs)
            verify(contrast(tab.tint, Qt.color(roles.canvas)) >= 3, tab.text + " label is invisible: " + tab.tint);
    }
}
