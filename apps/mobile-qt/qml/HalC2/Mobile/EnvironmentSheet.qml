import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The environment this phone is paired with (`pairing`): what it is called,
// where it is, how the connection is doing (`connection`), and the way out,
// which asks first.
MobileDialog {
    id: sheet

    readonly property var pairing: Shell.state.pairing ?? null
    readonly property string label: pairing !== null && pairing.label ? pairing.label : qsTr("This environment")

    objectName: "environmentSheet"
    title: label

    ColumnLayout {
        anchors.fill: parent
        spacing: 16

        Label {
            objectName: "environmentAddress"
            Layout.fillWidth: true
            text: sheet.pairing !== null ? (sheet.pairing.origin ?? "") : ""
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(14 * Theme.fontScale)
            wrapMode: Text.WrapAnywhere
        }

        ConnectionStatusRow {
            Layout.fillWidth: true
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 8
            spacing: 8

            MobileButton {
                objectName: "environmentForget"
                subtle: true
                tint: Theme.palette.color("error", "#ef4444")
                text: qsTr("Forget this environment")
                // One sheet at a time: the question takes this one's place.
                onClicked: {
                    sheet.close();
                    forget.open();
                }
            }

            Item {
                Layout.fillWidth: true
            }

            MobileButton {
                objectName: "environmentClose"
                subtle: true
                text: qsTr("Close")
                onClicked: sheet.close()
            }
        }
    }

    MobileDialog {
        id: forget

        objectName: "forgetDialog"
        parent: sheet.parent
        title: qsTr("Forget %1?").arg(sheet.label)
        onAccepted: Shell.dispatch("pairing.forget")
        onRejected: sheet.open()

        ColumnLayout {
            anchors.fill: parent
            spacing: 16

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(14 * Theme.fontScale)
                text: qsTr("This phone signs out of the environment and stops showing its projects and threads. Nothing on the environment is deleted. Pair again with a fresh pairing link to come back.")
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Item {
                    Layout.fillWidth: true
                }

                MobileButton {
                    objectName: "forgetCancel"
                    subtle: true
                    text: qsTr("Cancel")
                    onClicked: forget.reject()
                }

                MobileButton {
                    objectName: "forgetConfirm"
                    primary: true
                    text: qsTr("Forget")
                    onClicked: forget.accept()
                }
            }
        }
    }
}
