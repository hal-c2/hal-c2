import QtQuick
import HalC2.Shell

// A named place in the shell that plugins contribute to (Contribution.slot).
// Its children are the built-in content: shown alone when no plugin
// contributes, and then by `mode`: "replace" puts the contributions in its
// place, "append" after it, "single_winner" only the first by plugin order.
//
//   PluginSlot { name: "statusbar"; Text { text: qsTr("Ready") } }
Item {
    id: slot

    property string name: ""
    property string mode: "replace"
    // Handed to contributions that declare `property var slotData`.
    property var slotData: ({})
    property bool vertical: false
    property real spacing: 6
    default property alias builtIn: fallback.data
    // The plugins shown here, in order.
    property var shown: []
    readonly property bool builtInVisible: slot.mode === "append" || slot.shown.length === 0
    property var items: []

    function rebuild() {
        for (const item of slot.items)
            item.destroy();
        const items = [];
        const shown = [];
        const offered = slot.name.length > 0 ? PluginRegistry.contributionsFor(slot.name) : [];
        for (const contribution of slot.mode === "single_winner" ? offered.slice(0, 1) : offered) {
            const item = contribution.delegate.createObject(content, contribution.given ?? {});
            if (contribution.mc === true && item !== null) {
                // An MC plugin's part is a PluginPart, which loads its file itself.
                if (item.slotData !== undefined)
                    item.slotData = Qt.binding(() => slot.slotData);
                items.push(item);
                shown.push(contribution.pluginId);
                continue;
            }
            let problem = "";
            if (item === null)
                problem = contribution.delegate.errorString();
            else if (!(item instanceof Item))
                problem = qsTr("the contribution cannot be drawn");
            if (problem.length > 0) {
                if (item !== null)
                    item.destroy();
                PluginRegistry.noteRender(contribution.pluginId, contribution.file, slot.name, problem);
                continue;
            }
            PluginRegistry.noteRender(contribution.pluginId, contribution.file, slot.name, "");
            if (item.slotData !== undefined)
                item.slotData = Qt.binding(() => slot.slotData);
            items.push(item);
            shown.push(contribution.pluginId);
        }
        slot.items = items;
        slot.shown = shown;
    }

    implicitWidth: content.implicitWidth
    implicitHeight: content.implicitHeight
    onModeChanged: rebuild()
    Component.onCompleted: {
        PluginRegistry.mount(slot.name, 1);
        rebuild();
    }
    Component.onDestruction: PluginRegistry.mount(slot.name, -1)

    Connections {
        target: PluginRegistry
        function onRevisionChanged() {
            slot.rebuild();
        }
    }

    Grid {
        id: content

        rows: slot.vertical ? -1 : 1
        columns: slot.vertical ? 1 : -1
        spacing: slot.spacing
        verticalItemAlignment: Grid.AlignVCenter

        Item {
            id: fallback

            visible: slot.builtInVisible && children.length > 0
            implicitWidth: childrenRect.width
            implicitHeight: childrenRect.height
        }
    }
}
