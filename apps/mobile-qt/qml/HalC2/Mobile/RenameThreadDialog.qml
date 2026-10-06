import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell

// Renames the open thread when the thread menu's Rename asks for it: the
// desktop's header edits its title in place on `workspace.renameRequestId`,
// and a phone asks in a dialog.
MobileDialog {
    id: dialog

    readonly property var workspace: Shell.state.workspace ?? null
    readonly property int request: workspace !== null ? (workspace.renameRequestId ?? 0) : 0
    // The request already answered; one made before this dialog was is old.
    property int handled: request

    onRequestChanged: {
        if (request === handled)
            return;
        handled = request;
        if (request > 0 && workspace !== null && !workspace.isDraft) {
            field.text = workspace.threadTitle ?? "";
            open();
            field.selectAll();
            field.forceActiveFocus();
        }
    }

    objectName: "renameThreadDialog"
    title: qsTr("Rename thread")
    onAccepted: {
        if (field.text.trim().length > 0)
            Shell.dispatch("workspace.rename", { title: field.text.trim() });
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 16

        TextField {
            id: field

            objectName: "renameThreadTitle"
            Layout.fillWidth: true
            placeholderText: qsTr("Thread title")
            Accessible.name: qsTr("Thread title")
            onAccepted: dialog.accept()
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Item {
                Layout.fillWidth: true
            }

            MobileButton {
                objectName: "renameThreadCancel"
                subtle: true
                text: qsTr("Cancel")
                onClicked: dialog.reject()
            }

            MobileButton {
                objectName: "renameThreadSave"
                primary: true
                enabled: field.text.trim().length > 0
                text: qsTr("Rename")
                onClicked: dialog.accept()
            }
        }
    }
}
