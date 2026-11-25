import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Pairing, in a client that paired itself with its environments
// (`pairing`, apps/mobile-qt's Pairing): which environment the shell connects
// to and how that connection stands, the others paired beside it
// (SavedEnvironmentsGroup), the way to pair with one more (`pairing.add`, the
// client's own pairing screen), and the way out of each, which asks first
// (`pairing.askToForget`).
SettingsPage {
    id: page

    readonly property var pairing: Shell.state.pairing ?? null
    readonly property color muted: Theme.palette.color("inkTertiary", "#a1a1aa")

    objectName: "pairingSettings"
    title: qsTr("Pairing")

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.space.sm

        Label {
            objectName: "environmentName"
            Layout.fillWidth: true
            Layout.topMargin: Theme.space.md
            text: page.pairing !== null && page.pairing.label ? page.pairing.label : qsTr("This environment")
            color: page.foreground
            font.pixelSize: Theme.type.title.size
            font.weight: Font.DemiBold
            wrapMode: Text.Wrap
        }

        Label {
            objectName: "environmentAddress"
            Layout.fillWidth: true
            text: page.pairing !== null ? (page.pairing.origin ?? "") : ""
            color: page.muted
            font.pixelSize: Theme.type.meta.size
            wrapMode: Text.WrapAnywhere
        }

        ConnectionStatusRow {
            Layout.fillWidth: true
        }

        // Why the environment is still here after the user asked to forget it.
        Label {
            objectName: "environmentError"
            Layout.fillWidth: true
            visible: text.length > 0
            text: page.pairing !== null ? (page.pairing.error ?? "") : ""
            color: Theme.palette.color("errorForeground", "#f87171")
            font.pixelSize: Theme.type.meta.size
            wrapMode: Text.Wrap
        }

        ShellButton {
            objectName: "environmentForget"
            tint: Theme.palette.color("errorForeground", "#ef4444")
            text: qsTr("Forget this environment")
            onClicked: Shell.dispatch("pairing.askToForget")
        }

        SavedEnvironmentsGroup {
            id: others

            Layout.fillWidth: true
            Layout.topMargin: Theme.space.md
            visible: others.environments.length > 0
            pasting: false
            removeAction: "pairing.askToForget"
        }

        ShellButton {
            objectName: "environmentPairAnother"
            Layout.topMargin: Theme.space.sm
            text: qsTr("Pair with another environment")
            onClicked: Shell.dispatch("pairing.add")
        }
    }
}
