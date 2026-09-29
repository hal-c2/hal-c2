import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Asks before reverting a thread to a turn's checkpoint, keeping the files or
// putting them back. The revert itself is the source's (a ThreadDiff,
// Panel.diff), so a reply's Revert and the diff panel's go the same way.
//
//   RevertDialog { id: revert; source: Panel.diff }
//   onClicked: revert.ask(turn)   // 0: the turn the diff shows, or the latest
Dialog {
    id: dialog

    property var source: null
    readonly property int turn: source?.revertTurn ?? 0
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")

    function ask(turn) {
        if (!dialog.source)
            return;
        dialog.source.requestRevert(turn);
        if (dialog.turn > 0)
            dialog.open();
    }

    objectName: "revertDialog"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    width: Math.min(460, (parent?.width ?? 492) - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape
    title: qsTr("Revert to turn %1?").arg(turn)
    // Answered, cancelled or dropped (the thread changed): nothing left to ask.
    onTurnChanged: {
        if (turn === 0)
            close();
    }
    onRejected: source?.cancelRevert()

    background: Rectangle {
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
        radius: Math.min(Theme.radius, 16)
    }
    header: Label {
        text: dialog.title
        padding: 20
        bottomPadding: 4
        font.pixelSize: 17
        font.weight: Font.DemiBold
        color: dialog.foreground
    }
    contentItem: ColumnLayout {
        spacing: 12
        Label {
            Layout.fillWidth: true
            text: qsTr("The conversation after turn %1 is discarded. Reverting the files too puts the workspace back as it was after that turn. This cannot be undone.").arg(dialog.turn)
            color: dialog.foreground
            font.pixelSize: 13
            wrapMode: Text.Wrap
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 8
            spacing: 8
            Item {
                Layout.fillWidth: true
            }
            ShellButton {
                objectName: "revertCancel"
                text: qsTr("Cancel")
                onClicked: dialog.reject()
            }
            ShellButton {
                objectName: "revertKeepFiles"
                text: qsTr("Keep files")
                onClicked: dialog.source.confirmRevert(false)
            }
            ShellButton {
                objectName: "revertFiles"
                text: qsTr("Revert files too")
                tint: Theme.palette.color("diffRemoved", "#ef4444")
                onClicked: dialog.source.confirmRevert(true)
            }
        }
    }
}
