import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Asks the shell's question (Shell.state.confirmation: {requestId, title,
// description, confirmLabel, destructive}, MenuController) and answers it
// with `confirmation.answer`.
Dialog {
    id: dialog

    readonly property var question: Shell.state.confirmation ?? null

    function answer(accepted) {
        if (question === null) {
            return;
        }
        Shell.dispatch("confirmation.answer", {
            requestId: question.requestId,
            accepted: accepted
        });
    }

    objectName: "confirmDialog"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(440, (parent?.width ?? 472) / scale - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape
    title: question?.title ?? ""
    onQuestionChanged: question !== null ? open() : close()
    onRejected: answer(false)

    background: Rectangle {
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
        radius: Math.min(Theme.radius, 16)
    }
    header: Label {
        text: dialog.title
        padding: 20
        bottomPadding: 4
        font.pixelSize: Math.round(17 * Theme.fontScale)
        font.weight: Font.DemiBold
        color: Theme.palette.color("text", "#e4e4e7")
        wrapMode: Text.Wrap
    }
    contentItem: ColumnLayout {
        spacing: 12
        Label {
            Layout.fillWidth: true
            visible: text.length > 0
            text: dialog.question?.description ?? ""
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(13 * Theme.fontScale)
            wrapMode: Text.Wrap
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 8
            spacing: 8
            Item { Layout.fillWidth: true }
            ShellButton {
                objectName: "confirmCancel"
                text: qsTr("Cancel")
                onClicked: dialog.reject()
            }
            ShellButton {
                objectName: "confirmAccept"
                text: dialog.question?.confirmLabel ?? qsTr("Confirm")
                primary: dialog.question?.destructive !== true
                tint: dialog.question?.destructive === true ? Theme.palette.color("error", "#ef4444") : Theme.palette.color("accentForeground", "#ffffff")
                onClicked: dialog.answer(true)
            }
        }
    }
}
