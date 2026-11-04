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
    padding: Theme.space.lg
    closePolicy: Popup.CloseOnEscape
    title: question?.title ?? ""
    onQuestionChanged: question !== null ? open() : close()
    onRejected: answer(false)

    Overlay.modal: ShellScrim {}
    background: ShellPopoverSurface {}
    header: Label {
        text: dialog.title
        padding: Theme.space.lg
        bottomPadding: Theme.space.xs
        font.pixelSize: Theme.type.title.size
        font.weight: Theme.type.title.weight
        color: Theme.palette.color("text", "#e4e4e7")
        wrapMode: Text.Wrap
    }
    contentItem: ColumnLayout {
        spacing: Theme.space.md
        Label {
            Layout.fillWidth: true
            visible: text.length > 0
            text: dialog.question?.description ?? ""
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Theme.type.body.size
            wrapMode: Text.Wrap
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.space.sm
            spacing: Theme.space.sm
            Item { Layout.fillWidth: true }
            ShellButton {
                objectName: "confirmCancel"
                text: qsTr("Cancel")
                onClicked: dialog.reject()
            }
            ShellButton {
                objectName: "confirmAccept"
                text: dialog.question?.confirmLabel ?? qsTr("Confirm")
                // A destructive answer is the solid error fill, not a red label.
                primary: dialog.question?.destructive !== true
                destructive: dialog.question?.destructive === true
                onClicked: dialog.answer(true)
            }
        }
    }
}
