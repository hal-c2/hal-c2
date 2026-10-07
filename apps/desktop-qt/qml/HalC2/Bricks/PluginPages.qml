import QtQuick
import HalC2.Shell

// The pages MC plugins add, one PluginPage per tab, the selected one shown.
// The pages are made from their keys, so a republished list that keeps a
// page keeps its PluginPage and the state in it.
Item {
    id: pages

    readonly property var entries: Shell.state.mcPlugins?.pages ?? []
    readonly property string selected: Shell.state.route?.tab ?? "threads"
    property var keys: []

    function entry(key) {
        return pages.entries.find(page => page.key === key) ?? ({ key: key });
    }

    onEntriesChanged: {
        const next = pages.entries.map(page => page.key);
        if (JSON.stringify(next) !== JSON.stringify(pages.keys))
            pages.keys = next;
    }
    Component.onCompleted: keys = entries.map(page => page.key)

    Repeater {
        model: pages.keys

        delegate: PluginPage {
            required property string modelData

            anchors.fill: parent
            page: pages.entry(modelData)
            selected: pages.selected === modelData
        }
    }
}
