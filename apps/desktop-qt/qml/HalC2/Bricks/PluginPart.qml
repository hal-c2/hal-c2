import QtQuick
import HalC2.Shell

// One UI part of an MC plugin: the QML file at `url`, made with `plugin` (a
// PluginContext of its own), `thread` when it is a thread's (both declared by
// the part, as packages/contracts plugin.ts says), and `slotData` bound if it
// declares that. A new url (a new version of the plugin) makes it again;
// `problem` says why it could not be made.
Item {
    id: part

    property string url: ""
    property string pluginId: ""
    property var environments: []
    property var thread: null
    property var slotData: ({})
    // Whether the part takes this item's size rather than its own.
    property bool fill: false
    property Item item: null
    property string problem: ""
    property var context: null
    property string made: ""

    function clear() {
        if (part.item !== null)
            part.item.destroy();
        if (part.context !== null)
            part.context.destroy();
        part.item = null;
        part.context = null;
        part.problem = "";
    }

    function load() {
        if (part.url === part.made)
            return;
        part.made = part.url;
        part.clear();
        if (part.url.length === 0)
            return;
        const component = Qt.createComponent(part.url);
        if (component.status !== Component.Ready) {
            part.problem = component.errorString().trim();
            return;
        }
        const context = contextFactory.createObject(part);
        context.pluginId = Qt.binding(() => part.pluginId);
        context.environments = Qt.binding(() => part.environments);
        const given = { plugin: context };
        if (part.thread !== null)
            given.thread = part.thread;
        const made = component.createObject(holder, given);
        if (made === null || !(made instanceof Item)) {
            if (made !== null)
                made.destroy();
            context.destroy();
            part.problem = component.errorString().trim() || qsTr("the part cannot be drawn");
            return;
        }
        if (made.thread !== undefined)
            made.thread = Qt.binding(() => part.thread);
        if (made.slotData !== undefined)
            made.slotData = Qt.binding(() => part.slotData);
        if (part.fill)
            made.anchors.fill = holder;
        part.context = context;
        part.item = made;
    }

    implicitWidth: item !== null ? item.implicitWidth : 0
    implicitHeight: item !== null ? item.implicitHeight : 0
    onUrlChanged: load()
    Component.onCompleted: load()
    Component.onDestruction: clear()

    Component {
        id: contextFactory

        PluginContext {}
    }

    Item {
        id: holder

        anchors.fill: parent
    }
}
