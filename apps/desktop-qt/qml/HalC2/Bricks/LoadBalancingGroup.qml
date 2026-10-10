pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The Connections page's "Load balancing" group (LoadBalancingController
// publishes `loadBalancing`): the switch that lets the MC start new threads on
// the machine with the most room, and how often each machine gets them. It
// starts folded, its header saying what is set inside, and a settings search
// result for it (route.target, its objectName) opens it. Not shown while the
// cluster has one machine.
ShellCard {
    id: group

    readonly property var model: Shell.state.loadBalancing ?? null
    readonly property bool ready: model !== null && model.ready
    readonly property bool balancing: model !== null && model.enabled
    readonly property var preferences: model ? model.preferences : []
    property bool open: false
    readonly property var route: Shell.state.route ?? null
    readonly property int targetSeq: route !== null && route.targetSeq !== undefined ? route.targetSeq : 0
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    function openForTarget() {
        if (route !== null && route.target === objectName) open = true;
    }

    objectName: "load-balancing"
    visible: model !== null
    implicitHeight: column.implicitHeight + 2
    onTargetSeqChanged: openForTarget()
    Component.onCompleted: openForTarget()

    ColumnLayout {
        id: column

        width: parent.width
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            spacing: 12

            AbstractButton {
                id: fold

                objectName: "loadBalancingFold"
                Layout.fillWidth: true
                implicitHeight: 44
                Accessible.name: qsTr("Load balancing")
                Accessible.role: Accessible.Button
                onClicked: group.open = !group.open

                contentItem: RowLayout {
                    spacing: 8

                    ShellIcon {
                        name: group.open ? "chevron-down" : "chevron-right"
                        size: 16
                        color: group.muted
                    }

                    Label {
                        text: qsTr("Load balancing")
                        color: group.foreground
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                        font.weight: Font.Medium
                    }

                    Label {
                        objectName: "loadBalancingSummary"
                        Layout.fillWidth: true
                        text: group.model ? group.model.summary : ""
                        color: group.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        elide: Text.ElideRight
                    }
                }
            }

            ShellSwitch {
                objectName: "loadBalancingEnabled"
                enabled: group.ready
                checked: group.balancing
                Accessible.name: qsTr("Automatically balance load")
                onToggled: Shell.dispatch("loadBalancing.enable", {
                    enabled: checked
                })
            }
        }

        ColumnLayout {
            objectName: "loadBalancingBody"
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            Layout.bottomMargin: 12
            visible: group.open
            spacing: 8

            Label {
                Layout.fillWidth: true
                text: qsTr("New threads in shared projects start on the machine with the most free CPU and memory, weighted by each machine's preference.")
                color: group.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Repeater {
                model: group.model ? group.model.machines : []

                delegate: RowLayout {
                    id: machine

                    required property var modelData

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
                        objectName: "loadPreference:" + machine.modelData.environmentId
                        outline: true
                        implicitWidth: 140
                        enabled: group.ready && group.balancing
                        model: group.preferences
                        textRole: "label"
                        currentIndex: group.preferences.findIndex(preference => preference.weight === machine.modelData.weight)
                        Accessible.name: qsTr("%1 load preference").arg(machine.modelData.label)
                        onActivated: index => Shell.dispatch("loadBalancing.prefer", {
                            environmentId: machine.modelData.environmentId,
                            weight: group.preferences[index].weight
                        })
                    }
                }
            }
        }
    }
}
