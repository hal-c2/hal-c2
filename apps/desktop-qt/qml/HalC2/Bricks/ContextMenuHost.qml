pragma ComponentBehavior: Bound

import QtQuick
import HalC2.Shell

// Shows MenuController's pending context menu when it targets this host's
// surface, in window coordinates (one host per window), and reports the
// choice back.
Item {
    id: host

    required property string surfaceId

    readonly property var request: Shell.state.menu ?? null
    readonly property bool mine: request !== null && request.surfaceId === surfaceId
    property string shownRequestId: ""
    readonly property alias menu: menu
    // Everything built for the current request, destroyed with the next one.
    property var built: []

    anchors.fill: parent

    function choose(id) {
        if (host.request === null) {
            return;
        }
        const requestId = host.request.requestId;
        Shell.dispatch("menu.select", {
            requestId: requestId,
            id: id
        });
    }

    onRequestChanged: {
        // Not `mine`: its binding may not have seen this request yet.
        if (request === null || request.surfaceId !== surfaceId) {
            if (menu.visible) {
                menu.close();
            }
            return;
        }
        if (request.requestId === shownRequestId) {
            return;
        }
        shownRequestId = request.requestId;
        menu.chosen = false;
        rebuild();
        menu.popup(Math.min(request.x, host.width - menu.implicitWidth - 8), Math.min(request.y, host.height - menu.implicitHeight - 8));
    }

    ShellMenu {
        id: menu

        objectName: "contextMenu"
        property bool chosen: false

        onClosed: {
            if (!chosen && host.mine) {
                host.choose(null);
            }
        }
    }

    Component {
        id: itemComponent

        ShellMenuItem {
            id: row

            required property var entry

            text: entry.label
            enabled: entry.disabled !== true && entry.enabled !== false
            destructive: entry.destructive === true
            current: entry.checked === true
            iconName: entry.icon ?? ""
            onTriggered: {
                menu.chosen = true;
                host.choose(entry.id);
            }
        }
    }

    Component {
        id: submenuComponent

        ShellMenu {}
    }

    Component {
        id: separatorComponent

        ShellMenuSeparator {}
    }

    // Fills `target` from the request's entries; a group with children is a
    // submenu reached through one row, and `separatorBefore` is a hairline.
    function fill(target, items) {
        for (const entry of items) {
            if (entry.separatorBefore === true && target.count > 0) {
                const line = separatorComponent.createObject(null);
                built.push(line);
                target.addItem(line);
            }
            if (entry.children && entry.children.length > 0) {
                const sub = submenuComponent.createObject(null, {
                    title: entry.label
                });
                built.push(sub);
                fill(sub, entry.children);
                target.addMenu(sub);
                continue;
            }
            const row = itemComponent.createObject(null, {
                entry: entry
            });
            built.push(row);
            target.addItem(row);
        }
    }

    function rebuild() {
        while (menu.count > 0) {
            menu.takeItem(0);
        }
        for (const object of built) {
            object.destroy();
        }
        built = [];
        if (request !== null) {
            fill(menu, request.items);
        }
    }
}
