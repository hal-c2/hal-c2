import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// Where a device gets its environment (`pairing`, apps/mobile-qt Pairing):
// where a pairing link comes from, the camera for its QR code, a field for
// the link itself, and how the attempt went. A device with no environment
// shows it, and a paired one that asked to pair with another (`adding`),
// which is then told what it gives up and has a way back. The field follows
// `pairing.link`, so a link that failed is still there to correct, and a link
// another app opened this one with is there to read: `offered` is the address
// that one leads to, said until the user writes over it.
Flickable {
    id: screen

    readonly property var pairing: Shell.state.pairing ?? null
    readonly property bool busy: pairing !== null && pairing.phase === "pairing"
    readonly property string error: pairing !== null ? (pairing.error ?? "") : ""
    readonly property bool adding: pairing !== null && pairing.adding === true
    // The field's text follows this and not `pairing` itself: only a link
    // that changed is put there, and the rest of `pairing` changing leaves
    // what the user is writing alone.
    readonly property string published: pairing !== null ? (pairing.link ?? "") : ""
    readonly property string offered: pairing !== null ? (pairing.offered ?? "") : ""
    readonly property string environment: pairing !== null && pairing.label ? pairing.label : qsTr("this environment")

    function pair() {
        if (link.text.trim().length > 0 && !busy)
            Shell.dispatch("pairing.pair", { link: link.text.trim() });
    }

    objectName: "pairingScreen"
    contentHeight: column.implicitHeight + 48
    boundsBehavior: Flickable.StopAtBounds

    ColumnLayout {
        id: column

        // Centred while there is room, from the top once the keyboard takes it.
        y: Math.max(24, (screen.height - implicitHeight) / 2)
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(screen.width - 48, 420)
        spacing: 16

        HalC2Wordmark {
            Layout.alignment: Qt.AlignHCenter
            Layout.bottomMargin: 16
            size: 22
        }

        Label {
            objectName: "pairingTitle"
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: screen.adding ? qsTr("Pair with another environment") : qsTr("No environment connected")
            font.pixelSize: Math.round(20 * Theme.fontScale)
            font.weight: Font.DemiBold
        }

        Label {
            objectName: "pairingHelp"
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(14 * Theme.fontScale)
            text: qsTr("Pair this device with a machine that runs HAL-C2. On that machine, create a pairing link in the desktop app under Settings → Connections, or run `hal-c2 pair --tailscale`. Then scan its QR code, or enter the link here.")
        }

        // What pairing costs a device that already has an environment.
        Label {
            objectName: "pairingReplaces"
            Layout.fillWidth: true
            visible: screen.adding
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(14 * Theme.fontScale)
            text: qsTr("This device is paired with %1 at %2. It keeps one environment at a time: pairing here replaces %1.").arg(screen.environment).arg(screen.pairing !== null ? (screen.pairing.origin ?? "") : "")
        }

        MobileButton {
            objectName: "pairingScan"
            Layout.fillWidth: true
            Layout.topMargin: 8
            enabled: !screen.busy
            text: qsTr("Scan QR code")
            onClicked: Shell.dispatch("scanner.open")
        }

        TextField {
            id: link

            objectName: "pairingLink"
            Layout.fillWidth: true
            placeholderText: qsTr("Pairing link")
            text: screen.published
            enabled: !screen.busy
            inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
            Accessible.name: qsTr("Pairing link")
            onAccepted: screen.pair()
        }

        // A link the user did not write: where it leads, before it is used.
        Label {
            objectName: "pairingOffer"
            Layout.fillWidth: true
            visible: screen.offered.length > 0 && link.text.trim() === screen.published
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(13 * Theme.fontScale)
            text: qsTr("This link was opened from outside HAL-C2. It pairs this device with the environment at %1. Pair only if that is the machine you meant.").arg(screen.offered)
        }

        Label {
            objectName: "pairingError"
            Layout.fillWidth: true
            visible: text.length > 0
            wrapMode: Text.Wrap
            color: Theme.palette.color("error", "#f87171")
            font.pixelSize: Math.round(13 * Theme.fontScale)
            text: screen.error
        }

        MobileButton {
            objectName: "pairingPair"
            Layout.fillWidth: true
            primary: true
            enabled: !screen.busy && link.text.trim().length > 0
            text: screen.busy ? qsTr("Pairing…") : qsTr("Pair")
            onClicked: screen.pair()
        }

        MobileButton {
            objectName: "pairingCancel"
            Layout.fillWidth: true
            visible: screen.adding
            enabled: !screen.busy
            subtle: true
            text: qsTr("Back")
            onClicked: Shell.dispatch("pairing.cancel")
        }
    }
}
