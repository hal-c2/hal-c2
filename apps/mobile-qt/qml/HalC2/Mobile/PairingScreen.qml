import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// What a phone with no environment shows (`pairing`, apps/mobile-qt
// Pairing): where a pairing link comes from, a field for one, and how the
// attempt went. The field follows `pairing.link`, so a link that failed is
// still there to correct.
Flickable {
    id: screen

    readonly property var pairing: Shell.state.pairing ?? null
    readonly property bool busy: pairing !== null && pairing.phase === "pairing"
    readonly property string error: pairing !== null ? (pairing.error ?? "") : ""

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
            text: qsTr("No environment connected")
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
            text: qsTr("Pair this phone with a machine that runs HAL-C2. On that machine, create a pairing link in the desktop app under Settings → Connections, or run `hal-c2 pair --tailscale`, and enter the link here.")
        }

        TextField {
            id: link

            objectName: "pairingLink"
            Layout.fillWidth: true
            Layout.topMargin: 8
            placeholderText: qsTr("Pairing link")
            text: screen.pairing !== null ? (screen.pairing.link ?? "") : ""
            enabled: !screen.busy
            inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
            Accessible.name: qsTr("Pairing link")
            onAccepted: screen.pair()
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
    }
}
