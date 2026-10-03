import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Connections → Load balancing (LoadBalancingController's `loadBalancing`): a
// folded group whose switch turns balancing on for this device, holding how
// often each connected machine should get new threads. Shown with two or more
// machines connected.
ColumnLayout {
    id: group

    readonly property var model: Shell.state.loadBalancing ?? null
    property bool open: false
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    objectName: "loadBalancing"
    Layout.fillWidth: true
    visible: model !== null
    spacing: 6

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 12
        spacing: 8

        ShellButton {
            objectName: "fold"
            subtle: true
            text: group.open ? qsTr("Hide") : qsTr("Show")
            Accessible.name: group.open ? qsTr("Hide load balancing") : qsTr("Show load balancing")
            onClicked: group.open = !group.open
        }

        Label {
            text: qsTr("Load balancing")
            color: group.foreground
            font.pixelSize: Math.round(14 * Theme.fontScale)
            font.weight: Font.DemiBold
        }

        Label {
            objectName: "summary"
            Layout.fillWidth: true
            text: group.model?.summary ?? ""
            color: group.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
            elide: Text.ElideRight
        }

        Switch {
            objectName: "enabled"
            checked: group.model?.enabled ?? false
            Accessible.name: qsTr("Automatically balance load")
            onToggled: Shell.dispatch("loadBalancing.enable", { enabled: checked })
        }
    }

    Label {
        Layout.fillWidth: true
        visible: group.open
        text: qsTr("New threads in shared projects start on the machine with the most free CPU and memory, weighted by each machine's preference.")
        color: group.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }

    Repeater {
        model: group.open ? (group.model?.machines ?? []) : []

        delegate: RowLayout {
            id: machine

            required property var modelData
            readonly property var preferences: group.model?.preferences ?? []

            objectName: "machine:" + modelData.environmentId
            Layout.fillWidth: true
            spacing: 8

            Label {
                Layout.fillWidth: true
                text: machine.modelData.label
                color: group.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                elide: Text.ElideRight
            }

            ShellComboBox {
                objectName: "preference"
                outline: true
                implicitWidth: 140
                enabled: group.model?.enabled ?? false
                model: machine.preferences
                textRole: "label"
                currentIndex: machine.preferences.findIndex(preference => preference.value === machine.modelData.preference)
                Accessible.name: qsTr("%1 load preference").arg(machine.modelData.label)
                onActivated: index => Shell.dispatch("loadBalancing.prefer", {
                    environmentId: machine.modelData.environmentId,
                    value: machine.preferences[index].value
                })
            }
        }
    }
}
