import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// This device's load balancing, in Connections settings (ConnectionsController
// publishes `connections.balancing`): whether a new thread in a project
// several machines share picks its machine, and how often each should get one.
ColumnLayout {
    id: section

    readonly property var model: Shell.state.connections ? Shell.state.connections.balancing ?? null : null
    readonly property var preferences: [
        { weight: 100, label: qsTr("Prefer") },
        { weight: 50, label: qsTr("Normal") },
        { weight: 25, label: qsTr("Less often") },
        { weight: 0, label: qsTr("Manual only") }
    ]

    // Folded until the user, or a settings search result, opens it; its header
    // still says what is set.
    property bool open: false
    readonly property string summary: {
        if (model === null) return "";
        if (!model.enabled) return qsTr("Off");
        return model.environments.filter(environment => environment.weight !== 50).map(environment => environment.label + " " + environment.preference.toLowerCase()).join(" · ");
    }

    objectName: "loadBalancing"
    visible: model !== null
    spacing: 8

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 12
        spacing: 8

        ShellButton {
            objectName: "fold"
            subtle: true
            text: section.open ? qsTr("Hide") : qsTr("Show")
            Accessible.name: section.open ? qsTr("Hide load balancing") : qsTr("Show load balancing")
            onClicked: section.open = !section.open
        }

        Label {
            text: qsTr("Load balancing")
            color: Theme.palette.color("text", "#e4e4e7")
            font.pixelSize: Math.round(14 * Theme.fontScale)
            font.weight: Font.DemiBold
        }

        Label {
            objectName: "summary"
            Layout.fillWidth: true
            text: section.summary
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(12 * Theme.fontScale)
            elide: Text.ElideRight
        }

        Switch {
            objectName: "loadBalancingEnabled"
            checked: section.model !== null && section.model.enabled
            Accessible.name: qsTr("Automatically balance load")
            onToggled: Shell.dispatch("connections.balancing.enabled", {
                enabled: checked
            })
        }
    }

    Label {
        Layout.fillWidth: true
        visible: section.open
        text: qsTr("New threads in shared projects start on the machine with the most free CPU and memory, weighted by each machine's preference.")
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }

    Repeater {
        model: section.open && section.model ? section.model.environments : []

        delegate: RowLayout {
            id: row

            required property var modelData

            Layout.fillWidth: true
            spacing: 8

            Label {
                Layout.fillWidth: true
                text: row.modelData.label
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Math.round(13 * Theme.fontScale)
                elide: Text.ElideRight
            }

            ShellComboBox {
                outline: true
                enabled: section.model.enabled
                model: section.preferences
                textRole: "label"
                valueRole: "weight"
                currentIndex: section.preferences.findIndex(preference => preference.weight === row.modelData.weight)
                Accessible.name: qsTr("%1 load preference").arg(row.modelData.label)
                onActivated: Shell.dispatch("connections.balancing.preference", {
                    environmentId: row.modelData.environmentId,
                    weight: currentValue
                })
            }
        }
    }
}
