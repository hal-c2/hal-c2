import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Asks before a project is removed. The shell publishes the question under
// Shell.state.projectRemoval ({projectKey, title, workspaceRoot, threadCount})
// after a `project.remove`, and closes it when the removal lands, fails, is
// cancelled or the project goes away.
Dialog {
    id: dialog

    readonly property var removal: Shell.state.projectRemoval ?? null

    objectName: "projectRemovalDialog"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    width: Math.min(480, (parent?.width ?? 512) - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape
    title: qsTr("Remove project \"%1\"?").arg(removal?.title ?? "")
    onRemovalChanged: removal !== null ? open() : close()
    onRejected: Shell.dispatch("project.remove.cancel")

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
        color: Theme.palette.color("text", "#e4e4e7")
        elide: Text.ElideRight
    }
    contentItem: ColumnLayout {
        spacing: 12
        Label {
            Layout.fillWidth: true
            text: (dialog.removal?.threadCount ?? 0) > 0 ? qsTr("Its %n thread(s) and their conversation history will be cleared.", "", dialog.removal?.threadCount ?? 0) : qsTr("It has no threads.")
            color: Theme.palette.color("text", "#e4e4e7")
            font.pixelSize: 13
            wrapMode: Text.Wrap
        }
        Label {
            Layout.fillWidth: true
            text: qsTr("The files on disk are kept.")
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: 13
            wrapMode: Text.Wrap
        }
        Label {
            Layout.fillWidth: true
            text: dialog.removal?.workspaceRoot ?? ""
            font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
            font.pixelSize: 11
            color: Theme.palette.color("textMuted", "#a1a1aa")
            wrapMode: Text.WrapAnywhere
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 8
            spacing: 8
            Item { Layout.fillWidth: true }
            ShellButton {
                objectName: "projectRemovalCancel"
                text: qsTr("Cancel")
                onClicked: dialog.reject()
            }
            ShellButton {
                objectName: "projectRemovalConfirm"
                text: qsTr("Remove project")
                tint: Theme.palette.color("error", "#ef4444")
                onClicked: Shell.dispatch("project.remove.confirm")
            }
        }
    }
}
