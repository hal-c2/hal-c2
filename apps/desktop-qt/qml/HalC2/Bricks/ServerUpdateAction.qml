import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// What can be done about one server behind this app (ServerUpdateController's
// `serverUpdates`): update it, have the desktop app that runs it update (the
// controller asks first), copy the command for a server started by hand, or,
// when only its own machine can update it, say so.
RowLayout {
    id: action

    required property string environmentId
    // The button's words for a server that updates from here.
    property string label: qsTr("Update")
    readonly property var machine: (Shell.state.serverUpdates?.machines ?? []).find(entry => entry.environmentId === environmentId) ?? null
    readonly property bool offered: machine !== null && machine.behind && machine.online

    objectName: "serverUpdateAction"
    visible: offered
    spacing: 8

    Label {
        objectName: "serverUpdateManual"
        Layout.fillWidth: true
        visible: action.offered && action.machine.path === "desktop-manual"
        text: qsTr("Update the desktop app on that machine to update this server.")
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }

    ShellButton {
        objectName: "serverUpdateButton"
        visible: action.offered && action.machine.path !== "desktop-manual"
        primary: action.offered && action.machine.path !== "command"
        enabled: action.offered && !action.machine.updating
        text: !action.offered ? "" : action.machine.updating ? qsTr("Updating…") : action.machine.path === "command" ? qsTr("Copy update command") : action.label
        Accessible.name: action.offered ? (action.machine.path === "command" ? qsTr("Copy the command that updates %1").arg(action.machine.label) : qsTr("Update %1").arg(action.machine.label)) : ""
        onClicked: Shell.dispatch(action.machine.path === "command" ? "serverUpdates.copyCommand" : "serverUpdates.update", {
            environmentId: action.environmentId
        })
    }
}
