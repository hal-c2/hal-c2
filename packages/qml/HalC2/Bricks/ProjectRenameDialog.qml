import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Asks for a project folder's new name. The shell publishes the question
// under Shell.state.projectRename ({projectKey, title, environment}) after a
// `project.rename` (the legacy sidebar's project menu) and closes it once the
// rename lands, nothing changes, or it is cancelled; a name it refuses keeps
// it open (ProjectController).
Dialog {
    id: dialog

    readonly property var rename: Shell.state.projectRename ?? null

    objectName: "projectRenameDialog"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(420, (parent?.width ?? 452) / scale - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape

    title: qsTr("Rename project")
    onRenameChanged: {
        if (rename === null) {
            close();
            return;
        }
        field.text = rename.title;
        open();
        field.selectAll();
        field.forceActiveFocus();
    }
    onRejected: Shell.dispatch("project.rename.cancel")

    function submit() {
        Shell.dispatch("project.rename.submit", {
            title: field.text
        });
    }

    Overlay.modal: ShellScrim {}
    background: ShellPopoverSurface {}
    header: Label {
        text: dialog.title
        padding: 20
        bottomPadding: 4
        font.pixelSize: Theme.type.title.size
        font.weight: Font.DemiBold
        color: Theme.palette.color("text", "#e4e4e7")
        elide: Text.ElideRight
    }
    contentItem: ColumnLayout {
        spacing: 12

        ShellTextField {
            id: field

            objectName: "projectRenameField"
            Layout.fillWidth: true
            Accessible.name: qsTr("Project title")
            onAccepted: dialog.submit()
        }
        Label {
            Layout.fillWidth: true
            visible: text.length > 0
            text: (dialog.rename?.environment ?? "") !== "" ? qsTr("Environment: %1").arg(dialog.rename.environment) : ""
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Theme.type.body.size
            wrapMode: Text.Wrap
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 8
            spacing: 8
            Item { Layout.fillWidth: true }
            ShellButton {
                objectName: "projectRenameCancel"
                text: qsTr("Cancel")
                onClicked: dialog.reject()
            }
            ShellButton {
                objectName: "projectRenameSave"
                text: qsTr("Save")
                onClicked: dialog.submit()
            }
        }
    }
}
