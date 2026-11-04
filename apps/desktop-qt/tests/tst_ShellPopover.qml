import QtQuick
import QtQuick.Controls.Basic
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

TestCase {
    id: testCase
    name: "ShellPopoverTests"
    width: 400
    height: 300
    when: windowShown

    Component {
        id: popoverComponent
        ShellPopover {
            x: 20
            y: 20
            width: 200
            height: 120
        }
    }

    function cleanup() {
        Theme.colors = {};
        Theme.appearance = "dark";
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

    function test_closing_leaves_nothing_over_the_window() {
        const popover = createTemporaryObject(popoverComponent, testCase);
        popover.open();
        tryVerify(() => popover.opened);
        popover.close();
        // No fade out: gone the moment it closes, so the next click lands on what is under it.
        verify(!popover.visible);
    }

    function test_the_surface_takes_the_theme_overlay_and_strong_border() {
        Theme.colors = {
            surfaceOverlay: "#123456",
            borderStrong: "#abcdef"
        };
        const popover = createTemporaryObject(popoverComponent, testCase);
        popover.open();
        tryVerify(() => popover.opened);
        const frame = findNamed(popover.background, "popoverFrame");
        verify(frame !== null);
        compare(frame.color, Qt.color("#123456"));
        compare(frame.border.color, Qt.color("#abcdef"));
        // A theme that only has the older name still draws the overlay.
        Theme.colors = {
            popover: "#222222"
        };
        compare(frame.color, Qt.color("#222222"));
    }

    function test_the_corner_follows_the_theme_radius() {
        const popover = createTemporaryObject(popoverComponent, testCase);
        popover.open();
        tryVerify(() => popover.opened);
        const frame = findNamed(popover.background, "popoverFrame");
        const radius = Theme.radius;
        Theme.radius = 4;
        compare(frame.radius, 6);
        Theme.radius = 8;
        compare(frame.radius, 12);
        Theme.radius = radius;
    }
}
