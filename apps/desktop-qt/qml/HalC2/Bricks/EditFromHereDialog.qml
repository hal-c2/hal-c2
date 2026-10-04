import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Asks before the conversation rewinds to one of the user's messages
// (Shell.state.rewind, RewindController): the files can go back with it or
// stay as they are.
Dialog {
    id: dialog

    readonly property var question: Shell.state.rewind ?? null

    objectName: "editFromHereDialog"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(460, (parent?.width ?? 492) / scale - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape
    onQuestionChanged: question !== null ? open() : close()
    onRejected: Shell.dispatch("rewind.cancel", {})

    background: Rectangle {
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
        radius: Math.min(Theme.radius, 16)
    }
    contentItem: ColumnLayout {
        spacing: 12

        Label {
            Layout.fillWidth: true
            text: qsTr("Edit from here?")
            color: Theme.palette.color("text", "#e4e4e7")
            font.pixelSize: Math.round(17 * Theme.fontScale)
            font.weight: Font.DemiBold
            wrapMode: Text.Wrap
        }
        Label {
            Layout.fillWidth: true
            text: qsTr("Rewind chat to before this message. Your prompt and attachments return to the composer.")
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(13 * Theme.fontScale)
            wrapMode: Text.Wrap
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 6
            spacing: 8

            ShellButton {
                objectName: "editFromHereCancel"
                text: qsTr("Cancel")
                onClicked: dialog.reject()
            }
            Item {
                Layout.fillWidth: true
            }
            ShellButton {
                objectName: "editFromHereRevertFiles"
                text: qsTr("Revert files too")
                tint: Theme.palette.color("error", "#ef4444")
                onClicked: Shell.dispatch("rewind.confirm", {
                    restoreFiles: true
                })
            }
            ShellButton {
                objectName: "editFromHereKeepFiles"
                primary: true
                text: qsTr("Revert and keep changes")
                onClicked: Shell.dispatch("rewind.confirm", {
                    restoreFiles: false
                })
            }
        }
    }
}
