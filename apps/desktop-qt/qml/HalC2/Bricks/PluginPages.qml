import QtQuick
import HalC2.Shell

// The pages MC plugins add, one PluginPage per tab, the selected one shown.
// The pages are made from their keys, and the list of keys is changed in place,
// so a republished list that keeps a page keeps its PluginPage and the state in
// it, whichever other tabs come or go.
Item {
    id: pages

    readonly property var entries: Shell.state.mcPlugins?.pages ?? []
    readonly property string selected: Shell.state.route?.tab ?? "threads"

    function entry(key) {
        return pages.entries.find(page => page.key === key) ?? ({ key: key });
    }

    function sync() {
        const next = pages.entries.map(page => page.key);
        const kept = [];
        for (let i = keys.count - 1; i >= 0; --i) {
            const key = keys.get(i).key;
            if (next.includes(key))
                kept.push(key);
            else
                keys.remove(i);
        }
        for (const key of next) {
            if (!kept.includes(key))
                keys.append({ key: key });
        }
    }

    onEntriesChanged: sync()
    Component.onCompleted: sync()

    ListModel {
        id: keys
    }

    Repeater {
        model: keys

        delegate: PluginPage {
            required property string key

            anchors.fill: parent
            page: pages.entry(key)
            selected: pages.selected === key
        }
    }
}
