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
    // The menu showing the current request, or null. Each request gets a menu
    // of its own, so a menu still running its exit transition can never
    // close, or answer for, the request that replaced it.
    property ShellMenu menu: null

    anchors.fill: parent

    function choose(requestId, id) {
        Shell.dispatch("menu.select", {
            requestId: requestId,
            id: id
        });
    }

    onRequestChanged: {
        // Not `mine`: its binding may not have seen this request yet.
        const shown = request !== null && request.surfaceId === surfaceId;
        if (shown && menu !== null && menu.requestId === request.requestId) {
            return;
        }
        if (menu !== null) {
            const old = menu;
            menu = null;
            if (old.visible) {
                old.close();
            } else {
                old.destroyBuilt();
                old.destroy();
            }
        }
        if (!shown) {
            return;
        }
        const next = menuComponent.createObject(host, {
            parent: host,
            requestId: request.requestId
        });
        fill(next, next, request.items);
        menu = next;
        next.popup(Math.min(request.x, host.width - next.implicitWidth - 8), Math.min(request.y, host.height - next.implicitHeight - 8));
    }

    Component {
        id: menuComponent

        ShellMenu {
            id: shown

            objectName: "contextMenu"
            required property string requestId
            property bool chosen: false
            // Everything built for this menu, destroyed with it.
            property var built: []

            onClosed: {
                // Dismissed without a choice: answer for this menu's own
                // request, which the controller ignores once it is not
                // current.
                if (!chosen && host.request !== null && host.request.requestId === requestId) {
                    host.choose(requestId, null);
                }
                if (host.menu === shown) {
                    host.menu = null;
                }
                destroyBuilt();
                shown.destroy();
            }

            function destroyBuilt() {
                for (const object of built) {
                    object.destroy();
                }
                built = [];
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
            shortcut: entry.shortcut ?? ""
            required property var owner

            onTriggered: {
                owner.chosen = true;
                host.choose(owner.requestId, entry.id);
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

    // Fills `target` (a menu or one of `owner`'s submenus) from the
    // request's entries; a group with children is a submenu reached through
    // one row, and `separatorBefore` is a hairline.
    function fill(owner, target, items) {
        for (const entry of items) {
            if (entry.separatorBefore === true && target.count > 0) {
                const line = separatorComponent.createObject(null);
                owner.built.push(line);
                target.addItem(line);
            }
            if (entry.children && entry.children.length > 0) {
                const sub = submenuComponent.createObject(null, {
                    title: entry.label
                });
                owner.built.push(sub);
                fill(owner, sub, entry.children);
                target.addMenu(sub);
                continue;
            }
            const row = itemComponent.createObject(null, {
                entry: entry,
                owner: owner
            });
            owner.built.push(row);
            target.addItem(row);
        }
    }
}
