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

    // Placed by its top a third of the way down, so waiting, the invitation and
    // the failure keep the tile and title in one place.
    ShellEmptyState {
        objectName: "homeState"
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(home.height / 3)
        visible: !home.opening
        status: home.failed ? "error" : home.sidebar ? "empty" : "loading"
        iconName: "folder-plus"
        title: home.failed ? qsTr("Couldn’t start a new thread")
            : home.sidebar ? qsTr("What should we work on?") : qsTr("Waiting for the app…")
        description: home.failed ? qsTr("The project is still available. Try opening the draft again.")
            : home.sidebar && !home.hasProjects ? qsTr("Add a project to start your first thread.") : ""
        actionText: home.sidebar === null ? "" : home.failed ? qsTr("Try again") : qsTr("Add project")
        onActionTriggered: {
            if (home.failed)
                Shell.dispatch("landing.retry");
            // A local folder is picked here, as the sidebar does; without local folders the command palette asks.
            else if (Shell.localFolderImportEnabled && (home.sidebar.localFolders ?? false))
                addProjectDialog.open();
            else
                Shell.dispatch("project.add");
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
