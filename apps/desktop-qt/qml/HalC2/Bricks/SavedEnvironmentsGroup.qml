pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The Connections page's "Paired environments" (SavedEnvironmentsController
// publishes `savedEnvironments`): other MCs this app paired with by a pairing
// link, each on a connection of its own, with why one is not connected, a way
// to try it again, and a way to remove it. Pasting a link pairs a new one.
ColumnLayout {
    id: group

    readonly property var model: Shell.state.savedEnvironments ?? null
    readonly property var environments: model ? model.environments : []
    readonly property bool pairing: model !== null && model.pairing
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("inkTertiary", "#a1a1aa")
    readonly property color danger: Theme.palette.color("errorForeground", "#f87171")

    function stateLabel(state) {
        switch (state) {
        case "connected":
            return qsTr("Connected");
        case "connecting":
            return qsTr("Connecting…");
        case "reconnecting":
            return qsTr("Reconnecting…");
        case "offline":
            return qsTr("Offline");
        case "refused":
            return qsTr("Refused this device");
        case "blocked":
            return qsTr("Cannot connect");
        }
        return qsTr("Not connected");
    }

    function pair() {
        if (link.text.trim().length === 0)
            return;
        Shell.dispatch("savedEnvironments.pair", {
            link: link.text.trim()
        });
        link.clear();
    }

    objectName: "saved-environments"
    visible: model !== null
    spacing: Theme.space.sm

    Label {
        Layout.fillWidth: true
        text: qsTr("Paste a pairing link from another machine to connect to it from here, beside this machine.")
        color: group.muted
        font.pixelSize: Theme.type.meta.size
        wrapMode: Text.Wrap
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.space.sm

        ShellTextField {
            id: link

            objectName: "savedEnvironmentsLink"
            Layout.fillWidth: true
            enabled: !group.pairing
            placeholderText: qsTr("Pairing link")
            Accessible.name: qsTr("Pairing link from another machine")
            onAccepted: group.pair()
        }

        ShellButton {
            objectName: "savedEnvironmentsPair"
            primary: true
            enabled: !group.pairing && link.text.trim().length > 0
            text: group.pairing ? qsTr("Pairing…") : qsTr("Pair")
            onClicked: group.pair()
        }
    }

    Label {
        objectName: "savedEnvironmentsError"
        Layout.fillWidth: true
        visible: text.length > 0
        text: group.model ? (group.model.error ?? "") : ""
        color: group.danger
        font.pixelSize: Theme.type.meta.size
        wrapMode: Text.Wrap
    }

    Label {
        Layout.fillWidth: true
        visible: group.model !== null && (group.model.damaged ?? "").length > 0
        text: qsTr("The record of paired environments was damaged and set aside as %1.").arg(group.model ? group.model.damaged : "")
        color: group.muted
        font.pixelSize: Theme.type.meta.size
        wrapMode: Text.Wrap
    }

    Repeater {
        model: group.environments

        delegate: ColumnLayout {
            id: entry

            required property var modelData

            Layout.fillWidth: true
            spacing: 2

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space.sm

                Label {
                    Layout.fillWidth: true
                    text: entry.modelData.label
                    color: group.foreground
                    font.pixelSize: Theme.type.body.size
                    elide: Text.ElideRight
                }

                Label {
                    text: group.stateLabel(entry.modelData.state)
                    color: entry.modelData.state === "connected" ? group.muted : entry.modelData.state === "refused" || entry.modelData.state === "blocked" ? group.danger : group.muted
                    font.pixelSize: Theme.type.meta.size
                }

                ShellButton {
                    visible: entry.modelData.state !== "connected" && entry.modelData.state !== "connecting"
                    subtle: true
                    text: qsTr("Retry")
                    Accessible.name: qsTr("Try connecting to %1 again").arg(entry.modelData.label)
                    onClicked: Shell.dispatch("savedEnvironments.retry", {
                        id: entry.modelData.id
                    })
                }

                ShellButton {
                    subtle: true
                    text: qsTr("Remove")
                    Accessible.name: qsTr("Remove %1").arg(entry.modelData.label)
                    onClicked: Shell.dispatch("savedEnvironments.remove", {
                        id: entry.modelData.id
                    })
                }
            }

            Label {
                Layout.fillWidth: true
                visible: text.length > 0
                text: entry.modelData.message || entry.modelData.origin
                color: group.muted
                font.pixelSize: Theme.type.meta.size
                elide: Text.ElideRight
            }
        }
    }
}
