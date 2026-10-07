import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Pairing, in a client that paired itself with its environment
// (`pairing`, apps/mobile-qt's Pairing): which environment that is, how the
// connection to it stands, and the way out, which asks first
// (`pairing.askToForget`).
SettingsPage {
    id: page

    readonly property var pairing: Shell.state.pairing ?? null
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    objectName: "pairingSettings"
    title: qsTr("Pairing")

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 8

        Label {
            objectName: "environmentName"
            Layout.fillWidth: true
            Layout.topMargin: 12
            text: page.pairing !== null && page.pairing.label ? page.pairing.label : qsTr("This environment")
            color: page.foreground
            font.pixelSize: Math.round(14 * Theme.fontScale)
            font.weight: Font.DemiBold
            wrapMode: Text.Wrap
        }

        Label {
            objectName: "environmentAddress"
            Layout.fillWidth: true
            text: page.pairing !== null ? (page.pairing.origin ?? "") : ""
            color: page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
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
            color: Theme.palette.color("error", "#f87171")
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        ShellButton {
            objectName: "environmentForget"
            Layout.topMargin: 8
            tint: Theme.palette.color("error", "#ef4444")
            text: qsTr("Forget this environment")
            onClicked: Shell.dispatch("pairing.askToForget")
        }
    }
}
