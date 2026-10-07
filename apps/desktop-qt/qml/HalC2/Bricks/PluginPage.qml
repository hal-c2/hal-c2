import QtQuick
import HalC2.Shell

// One plugin page (an entry of Shell.state.mcPlugins.pages), made the first
// time its tab is selected and kept while other tabs show, so it keeps its
// state. Says when the plugin's file could not be fetched or loaded.
Item {
    id: host

    property var page: ({})
    property bool selected: false
    property bool started: false
    readonly property string problem: (page.error ?? "").length > 0 ? page.error : part.problem
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")

    objectName: "pluginPage:" + (page.key ?? "")
    visible: selected
    onSelectedChanged: if (selected)
        started = true
    Component.onCompleted: started = selected

    PluginPart {
        id: part

        anchors.fill: parent
        fill: true
        url: host.started ? (host.page.url ?? "") : ""
        pluginId: host.page.pluginId ?? ""
        environments: host.page.environments ?? []
    }

    Text {
        objectName: "pluginPageProblem"
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 560)
        visible: host.problem.length > 0
        text: qsTr("%1 failed: %2").arg(host.page.pluginName || host.page.pluginId).arg(host.problem)
        color: Theme.palette.color("error", "#ef4444")
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
        font.pixelSize: Math.round(13 * Theme.fontScale)
    }

    Text {
        anchors.centerIn: parent
        visible: host.problem.length === 0 && part.item === null
        text: qsTr("Loading…")
        color: host.muted
        font.pixelSize: Math.round(13 * Theme.fontScale)
    }
}
