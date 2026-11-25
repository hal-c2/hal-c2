import QtQuick
import HalC2.Shell

// How a thread an MC plugin started looks: its `rowMark` beside the row in
// the thread list or its `header` above the conversation, from the plugin's
// threadKinds (Shell.state.mcPlugins.threadKinds). Nothing while the plugin
// is not running, so the thread looks like any other.
//
// `thread` is {id, title, environmentId, plugin: {id, kind}}.
PluginPart {
    id: threadPart

    // "rowMark" or "header".
    property string look: "rowMark"
    readonly property var kind: thread !== null && thread.plugin ? (Shell.state.mcPlugins?.threadKinds ?? {})[thread.environmentId + "/" + thread.plugin.id + "/" + thread.plugin.kind] ?? null : null

    visible: item !== null
    url: kind !== null ? (kind[look] ?? "") : ""
    pluginId: thread !== null && thread.plugin ? thread.plugin.id : ""
    environments: thread !== null ? [thread.environmentId] : []
}
