import QtQuick
import QtQuick.Controls.Basic
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

TestCase {
    id: testCase
    name: "ShellMenuTests"
    width: 700
    height: 500
    when: windowShown

    Component {
        id: shortMenu
        ShellMenu {
            ShellMenuItem {
                text: "Pin"
            }
        }
    }

    Component {
        id: longMenu
        ShellMenu {
            ShellMenuItem {
                text: "A very long entry that names a project, a branch and a worktree path all at once"
            }
        }
    }

    Component {
        id: richMenu
        ShellMenu {
            ShellMenuItem {
                text: "New thread"
                iconName: "message-square-plus"
                shortcut: "Ctrl+N"
            }
            ShellMenuItem {
                text: "Rename"
            }
            ShellMenuItem {
                text: "Dark"
                current: true
            }
            ShellMenu {
                title: "Move to"
                ShellMenuItem {
                    text: "Project A"
                }
            }
        }
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

    function openMenu(component) {
        const menu = createTemporaryObject(component, testCase);
        menu.popup(20, 20);
        tryVerify(() => menu.opened);
        return menu;
    }

    function test_width_stays_between_220_and_360() {
        const narrow = openMenu(shortMenu);
        compare(narrow.width, 220);
        narrow.close();
        const wide = openMenu(longMenu);
        compare(wide.width, 360);
    }

    function test_rows_are_one_control_tall() {
        const menu = openMenu(richMenu);
        for (let i = 0; i < menu.count; ++i)
            compare(menu.itemAt(i).height, Theme.control.md);
    }

    function test_labels_line_up_whether_or_not_a_row_has_an_icon() {
        const menu = openMenu(richMenu);
        const iconed = findNamed(menu.itemAt(0), "menuItemLabel");
        const plain = findNamed(menu.itemAt(1), "menuItemLabel");
        compare(plain.mapToItem(menu.contentItem, 0, 0).x, iconed.mapToItem(menu.contentItem, 0, 0).x);
    }

    function test_the_right_column_holds_the_shortcut_chevron_or_check() {
        const menu = openMenu(richMenu);
        const withShortcut = menu.itemAt(0);
        const shortcut = findNamed(withShortcut, "menuItemShortcut");
        verify(shortcut.visible);
        compare(shortcut.text, "Ctrl+N");
        const label = findNamed(withShortcut, "menuItemLabel");
        verify(shortcut.mapToItem(withShortcut, 0, 0).x > label.mapToItem(withShortcut, 0, 0).x + label.width - 1);
        verify(!findNamed(withShortcut, "menuItemChevron").visible);
        verify(!findNamed(menu.itemAt(1), "menuItemShortcut").visible);
        // The current choice is checked; the others are not.
        verify(findNamed(menu.itemAt(2), "menuItemCheck").visible);
        verify(!findNamed(menu.itemAt(1), "menuItemCheck").visible);
        // A submenu's row shows its chevron.
        const submenuRow = menu.itemAt(3);
        verify(submenuRow.subMenu !== null);
        verify(findNamed(submenuRow, "menuItemChevron").visible);
        // ...and only that one: the style's own arrow, tinted with the
        // window palette, would cover it.
        compare(submenuRow.arrow, null);
    }

    function test_closing_is_instant() {
        const menu = openMenu(richMenu);
        menu.close();
        verify(!menu.visible);
    }

    function test_menus_draw_on_the_popover_surface() {
        Theme.colors = {
            surfaceOverlay: "#101820"
        };
        const menu = openMenu(shortMenu);
        compare(findNamed(menu.background, "popoverFrame").color, Qt.color("#101820"));
        Theme.colors = {};
    }

    // The glass opacity thins surfaceOverlay for the composer; a menu stays solid.
    function test_menus_are_opaque_whatever_the_glass() {
        Theme.colors = {
            surfaceOverlay: "#66101820"
        };
        const menu = openMenu(shortMenu);
        const fill = findNamed(menu.background, "popoverFrame").color;
        compare(fill.a, 1);
        compare(fill, Qt.color("#101820"));
        Theme.colors = {};
    }
}
