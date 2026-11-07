import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell

// Adds a project from a folder on the environment's machine, whose path the
// user types: the phone has no folders of its own to pick, and the MC says
// whether the folder is there (ProjectController, `onEnvironment`). Opened by
// `open()` from the home screen's bar; the project's draft opens when the
// MC has added it, and a refusal comes as a toast.
// Centred in its parent, so it stays clear of the keyboard when the parent does.
Dialog {
    id: dialog

    objectName: "addProjectDialog"
    modal: true
    anchors.centerIn: parent
    width: Math.min(parent.width - 32, 420)
    padding: 20
    title: qsTr("Add project")
    onAboutToShow: field.text = ""
    onOpened: field.forceActiveFocus()
    onAccepted: {
        if (field.text.trim().length > 0)
            Shell.dispatch("project.add", { path: field.text.trim(), onEnvironment: true });
    }

    background: MobileSurface {}
    Overlay.modal: Rectangle {
        color: Qt.rgba(0, 0, 0, 0.5)
    }
    header: Label {
        text: dialog.title
        padding: 20
        bottomPadding: 0
        font.pixelSize: Math.round(18 * Theme.fontScale)
        font.weight: Font.DemiBold
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 16

        Label {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(14 * Theme.fontScale)
            text: qsTr("The folder's path on the environment's machine.")
        }

        TextField {
            id: field

            objectName: "addProjectPath"
            Layout.fillWidth: true
            placeholderText: qsTr("/home/you/code/project")
            inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText | Qt.ImhUrlCharactersOnly
            Accessible.name: qsTr("Folder path")
            onAccepted: dialog.accept()
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Item {
                Layout.fillWidth: true
            }

            MobileButton {
                objectName: "addProjectCancel"
                subtle: true
                text: qsTr("Cancel")
                onClicked: dialog.reject()
            }

            MobileButton {
                objectName: "addProjectAdd"
                primary: true
                enabled: field.text.trim().length > 0
                text: qsTr("Add")
                onClicked: dialog.accept()
            }
        }
    }
}
