pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The cluster's servers behind this app (ServerUpdateController's
// `serverUpdates`), each with its way to update, and Update all for every one
// that can update from here.
ColumnLayout {
    id: list

    readonly property var model: Shell.state.serverUpdates ?? null
    readonly property var behind: (model?.machines ?? []).filter(machine => machine.behind && machine.online)

    objectName: "serverUpdatesList"
    visible: behind.length > 0
    spacing: 8

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Label {
            Layout.fillWidth: true
            text: qsTr("Servers behind this app (%1)").arg(list.model ? list.model.appVersion : "")
            color: Theme.palette.color("text", "#e4e4e7")
            font.pixelSize: Math.round(13 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        ShellButton {
            objectName: "serverUpdatesAll"
            visible: list.model !== null && list.model.updatable > 0
            text: qsTr("Update all")
            onClicked: Shell.dispatch("serverUpdates.updateAll")
        }
    }

    Repeater {
        model: list.behind

        delegate: RowLayout {
            id: row

            required property var modelData

            Layout.fillWidth: true
            spacing: 8

            Label {
                Layout.preferredWidth: 180
                text: qsTr("%1 on %2").arg(row.modelData.label, row.modelData.version)
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                elide: Text.ElideRight
            }

            ServerUpdateAction {
                Layout.fillWidth: true
                environmentId: row.modelData.environmentId
            }
        }
    }
}
