import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import HalC2.Shell

// Home, with no thread chosen (the route `home`). The shell moves on from here
// to a draft of the most recent project (DraftController), so with projects
// home shows nothing, unless that draft could not be started: then it says so
// and offers to try again. With no projects yet the user is asked what to work
// on and offered to add one.
Rectangle {
    id: home

    readonly property var sidebar: Shell.state.sidebar ?? null
    readonly property bool hasProjects: sidebar !== null && (sidebar.projects ?? []).length > 0
    readonly property bool failed: (Shell.state.landing ?? null)?.failed === true
    // Nothing to say while the draft opens.
    readonly property bool opening: hasProjects && !failed

    color: Theme.palette.color("canvas", "#0b0b0d")

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 480)
        spacing: 10

        Label {
            objectName: "homeTitle"
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            color: Theme.palette.color("text", "#e4e4e7")
            visible: !home.opening
            font.pixelSize: home.sidebar ? 24 : 13
            text: home.failed ? qsTr("Couldn’t start a new thread")
                : home.sidebar ? qsTr("What should we work on?") : qsTr("Waiting for the app…")
        }

        Label {
            objectName: "homeDetail"
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: home.failed || (home.sidebar !== null && !home.hasProjects)
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: 13
            text: home.failed ? qsTr("The project is still available. Try opening the draft again.")
                : qsTr("Add a project to start your first thread.")
        }

        ShellButton {
            objectName: "homeAction"
            Layout.alignment: Qt.AlignHCenter
            visible: home.sidebar !== null && !home.opening
            primary: true
            iconName: home.failed ? "refresh-cw" : "folder-plus"
            text: home.failed ? qsTr("Try again") : qsTr("Add project")
            onClicked: {
                if (home.failed)
                    Shell.dispatch("landing.retry");
                // A local folder is picked here, as the sidebar does; without local folders the page's palette asks.
                else if (Shell.localFolderImportEnabled && (home.sidebar.localEnvironmentId ?? null) !== null)
                    addProjectDialog.open();
                else
                    Shell.dispatch("project.add");
            }
        }
    }

    FolderDialog {
        id: addProjectDialog

        title: qsTr("Add a project folder")
        onAccepted: {
            const path = Shell.localDirectoryPath(selectedFolder);
            if (path.length > 0)
                Shell.dispatch("project.add", { path: path });
        }
    }
}
