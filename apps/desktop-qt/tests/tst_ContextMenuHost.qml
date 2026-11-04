import QtQuick
import QtQuick.Controls.Basic
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

TestCase {
    id: testCase
    name: "ContextMenuHostTests"
    width: 600
    height: 500
    when: windowShown

    Component {
        id: hostComponent
        ContextMenuHost {
            surfaceId: "main"
        }
    }

    function request(items, id) {
        return {
            requestId: id ?? "r1",
            surfaceId: "main",
            x: 20,
            y: 20,
            items: items
        };
    }

    function cleanup() {
        Shell.state = {};
        Shell.reset();
    }

    function open(items, id) {
        const host = createTemporaryObject(hostComponent, testCase);
        Shell.state = {
            menu: request(items, id)
        };
        verify(host.menu.visible || host.menu.opened || host.menu.count > 0);
        return host;
    }

    function rowTexts(menu) {
        const out = [];
        for (let i = 0; i < menu.count; ++i) {
            const item = menu.itemAt(i);
            out.push(item instanceof MenuSeparator ? "-" : item.text);
        }
        return out;
    }

    function test_separators_are_drawn_between_groups() {
        const host = open([
            {id: "a", label: "Rename"},
            {id: "b", label: "Pin", separatorBefore: true},
            {id: "c", label: "Delete", separatorBefore: true, destructive: true}
        ]);
        compare(rowTexts(host.menu), ["Rename", "-", "Pin", "-", "Delete"]);
    }

    function test_a_group_with_children_is_one_submenu_row() {
        const host = open([
            {id: "a", label: "Rename"},
            {id: "m", label: "Move to", children: [{id: "m1", label: "Project A"}, {id: "m2", label: "Project B"}]}
        ]);
        compare(rowTexts(host.menu), ["Rename", "Move to"]);
        const row = host.menu.itemAt(1);
        verify(row.subMenu !== null);
        compare(rowTexts(row.subMenu), ["Project A", "Project B"]);
        verify(host.menu.itemAt(0).subMenu === null);
    }

    function test_choosing_a_nested_item_reports_its_id() {
        const host = open([
            {id: "m", label: "Move to", children: [{id: "m1", label: "Project A"}]}
        ]);
        host.menu.itemAt(0).subMenu.itemAt(0).triggered();
        compare(Shell.dispatchedActions.length, 1);
        compare(Shell.dispatchedActions[0].payload.id, "m1");
    }

    function test_a_short_menu_keeps_the_usual_width() {
        const host = open([{id: "a", label: "Pin"}]);
        compare(host.menu.implicitWidth, 200);
    }

    function test_the_menu_fits_a_long_label_up_to_a_limit() {
        const host = open([{id: "a", label: "Move this thread to the project called something rather long"}]);
        verify(host.menu.implicitWidth > 200);
        verify(host.menu.implicitWidth <= 360);
        const huge = open([{id: "a", label: "x".repeat(200)}], "r2");
        compare(huge.menu.implicitWidth, 360);
    }

    function selections() {
        return Shell.dispatchedActions.filter(action => action.action === "menu.select").map(action => action.payload);
    }

    // A choice in one menu opening the next (Move to another machine…): the
    // second request arrives while the first menu is still on its way out.
    function test_a_request_arriving_while_the_last_menu_closes_stays_open() {
        const host = open([{id: "move", label: "Move to another machine…"}], "r1");
        const first = host.menu;
        tryVerify(() => first.opened);
        first.itemAt(0).triggered();
        compare(selections(), [{requestId: "r1", id: "move"}]);
        Shell.state = {menu: null};
        Shell.state = {menu: request([{id: "m1", label: "ai-beast"}], "r2")};
        const second = host.menu;
        verify(second !== first);
        compare(rowTexts(second), ["ai-beast"]);
        // The first menu finishes leaving without answering for the second.
        tryVerify(() => !first || !first.visible);
        tryVerify(() => second.opened);
        verify(second.visible);
        compare(selections(), [{requestId: "r1", id: "move"}]);
        Shell.state = {menu: null};
        compare(host.menu, null);
        tryVerify(() => !second || !second.visible);
    }

    function test_back_to_back_requests_show_the_second() {
        const host = open([{id: "a", label: "Pin"}], "r1");
        const first = host.menu;
        Shell.state = {menu: request([{id: "b", label: "Rename"}], "r2")};
        compare(rowTexts(host.menu), ["Rename"]);
        tryVerify(() => !first || !first.visible);
        tryVerify(() => host.menu !== null && host.menu.opened);
        compare(selections(), []);
    }

    function test_dismissing_a_menu_answers_for_its_request() {
        const host = open([{id: "a", label: "Pin"}], "r1");
        const menu = host.menu;
        tryVerify(() => menu.opened);
        menu.close();
        tryVerify(() => selections().length === 1);
        compare(selections(), [{requestId: "r1", id: null}]);
        compare(host.menu, null);
    }
}
