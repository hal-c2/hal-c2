import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtMultimedia
import HalC2.Shell
import HalC2.Bricks

// The camera, looking for an environment's pairing code (`scanner`,
// apps/mobile-qt Scanner): what it sees under a bar that leads back to the
// pairing screen, and below it what to point it at or why a code it read was
// not taken. A device that keeps the camera from the app is told so instead,
// with the way to the system's settings, and so is one whose camera gives no
// picture (`failed`), with a way to try it again. The scanner reads the
// frames at this screen's own sink, and stops the camera when the screen goes.
Rectangle {
    id: screen

    readonly property var scanner: Shell.state.scanner ?? null
    readonly property string access: scanner !== null ? (scanner.access ?? "") : ""
    readonly property string message: scanner !== null ? (scanner.message ?? "") : ""
    readonly property bool failed: access === "granted" && scanner.failed === true
    // The camera is the app's to use and gives a picture, or will.
    readonly property bool looking: access === "granted" && !failed
    readonly property var pairing: Shell.state.pairing ?? null
    readonly property bool replacing: pairing !== null && pairing.phase === "paired"
    readonly property string environment: pairing !== null && pairing.label ? pairing.label : qsTr("this environment")

    objectName: "scanScreen"
    color: Theme.palette.color("canvas", "#0b0b0d")

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        MobileBar {
            Layout.fillWidth: true
            canGoBack: true
            title: qsTr("Scan QR code")
            onBackRequested: Shell.dispatch("scanner.close")
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            // Dark behind the picture, and before the camera's first one.
            color: screen.looking ? "black" : "transparent"

            VideoOutput {
                id: preview

                objectName: "scanPreview"
                anchors.fill: parent
                visible: screen.looking
                fillMode: VideoOutput.PreserveAspectCrop
                Component.onCompleted: Shell.dispatch("scanner.preview", { sink: preview.videoSink })
            }

            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - 48, 420)
                visible: screen.access === "denied"
                spacing: 16

                Label {
                    objectName: "scanDenied"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    font.pixelSize: Math.round(15 * Theme.fontScale)
                    text: qsTr("HAL-C2 needs the camera to scan a pairing code. Allow the camera for HAL-C2 in the system settings, or go back and enter the pairing link.")
                }

                MobileButton {
                    objectName: "scanSettings"
                    Layout.fillWidth: true
                    primary: true
                    text: qsTr("Open settings")
                    onClicked: Shell.dispatch("scanner.settings")
                }
            }

            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - 48, 420)
                visible: screen.failed
                spacing: 16

                Label {
                    objectName: "scanFailed"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    font.pixelSize: Math.round(15 * Theme.fontScale)
                    text: screen.message
                }

                MobileButton {
                    objectName: "scanRetry"
                    Layout.fillWidth: true
                    primary: true
                    text: qsTr("Try again")
                    onClicked: Shell.dispatch("scanner.retry")
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: hint.implicitHeight + 24
            visible: screen.looking
            color: Theme.palette.color("toolbar", "#0b0b0d")

            Label {
                id: hint

                objectName: "scanMessage"
                anchors.verticalCenter: parent.verticalCenter
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(parent.width - 32, 520)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: screen.message.length > 0 ? Theme.palette.color("error", "#f87171") : Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(13 * Theme.fontScale)
                text: screen.message.length > 0 ? screen.message : screen.replacing ? qsTr("Point the camera at the QR code under Settings → Connections on the machine that runs HAL-C2. Pairing with it replaces %1.").arg(screen.environment) : qsTr("Point the camera at the QR code under Settings → Connections on the machine that runs HAL-C2.")
            }
        }
    }
}
