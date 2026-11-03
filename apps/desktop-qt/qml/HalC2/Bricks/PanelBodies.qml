pragma ComponentBehavior: Bound
import QtQuick
import HalC2.Shell
import "js/panelTabs.js" as PanelTabs

// The right panel's tab bodies (js/panelTabs.js), shared by the side panel
// and the stage's panes. A place shows a tab through a PanelBodySlot, which
// borrows the tab's body from here: the body is made the first time a slot
// shows it and moves between slots after that, so it keeps its scroll and what
// it loaded. A body no slot shows waits here, hidden.
//
//   PanelBodies { id: bodies }
//   RightPanel { bodies: bodies }
//   Stage { bodies: bodies }
Item {
    id: pool

    // The slot each body shows in, by body key (PanelTabs.bodyOf).
    property var hosts: ({})
    property var slots: []
    // The tab being dragged between the side panel and the stage, or "".
    property string dragging: ""
    readonly property var panel: Shell.state.panel ?? null

    visible: false
    onPanelChanged: rehost()
    Component.onCompleted: sync()

    function enter(slot) {
        if (!slots.includes(slot))
            slots = slots.concat([slot]);
        rehost();
    }

    function leave(slot) {
        slots = slots.filter(other => other !== slot);
        rehost();
    }

    // A body shows in the slot whose tab shows first (Shell.state.panel.shownTabs).
    function rehost() {
        const shown = panel?.shownTabs ?? [];
        const rank = id => {
            const at = shown.indexOf(id);
            return at < 0 ? shown.length : at;
        };
        const next = {};
        for (const slot of slots) {
            if (slot.tabId.length === 0 || !PanelTabs.tabs[PanelTabs.kindOf(slot.tabId)])
                continue;
            const key = PanelTabs.bodyOf(slot.tabId);
            const held = next[key];
            if (!held || rank(slot.tabId) < rank(held.tabId))
                next[key] = slot;
        }
        const keys = Object.keys(next);
        if (keys.length !== Object.keys(hosts).length || keys.some(key => hosts[key] !== next[key]))
            hosts = next;
        sync();
    }

    // One body per kind, plus one per tab of a per-tab kind.
    function sync() {
        const wanted = [];
        for (const kind of Object.keys(PanelTabs.tabs)) {
            if (!PanelTabs.tabs[kind].perTab)
                wanted.push(kind);
        }
        for (const tab of panel?.tabs ?? []) {
            if (PanelTabs.tabs[tab.kind]?.perTab)
                wanted.push(tab.id);
        }
        for (let at = keys.count - 1; at >= 0; --at) {
            if (!wanted.includes(keys.get(at).key))
                keys.remove(at);
        }
        for (const key of wanted) {
            let found = false;
            for (let at = 0; at < keys.count && !found; ++at)
                found = keys.get(at).key === key;
            if (!found)
                keys.append({
                    key: key
                });
        }
    }

    ListModel {
        id: keys
    }

    Instantiator {
        model: keys

        delegate: Loader {
            id: body

            required property string key
            readonly property string kind: PanelTabs.kindOf(key)
            readonly property var tab: PanelTabs.tabs[kind]
            readonly property Item host: pool.hosts[key] ?? null

            objectName: "panelBody-" + key
            parent: host ?? pool
            anchors.fill: parent
            visible: host !== null
            active: false
            onHostChanged: if (host)
                active = true
            Component.onCompleted: {
                setSource(Qt.resolvedUrl(tab.brick + ".qml"), {
                    source: Qt.binding(() => body.tab.source ? Panel[body.tab.source] : null)
                });
                active = host !== null;
            }
            // The tab it shows: its own, or its kind's that shows first.
            onLoaded: if ("tabId" in item)
                item.tabId = Qt.binding(() => body.tab.perTab ? body.key : (body.host?.tabId ?? ""))
        }
    }
}
