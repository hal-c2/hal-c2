import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import HalC2.Shell

// Home, with no thread chosen (the route `home`): the user is asked what to
// work on, and offered a new thread, or with no projects yet, to add one. The
// page still follows home and moves on to a draft of the latest project, which
// the shell adopts.
Rectangle {
    id: home

    readonly property var sidebar: Shell.state.sidebar ?? null
    readonly property bool hasProjects: sidebar !== null && (sidebar.projects ?? []).length > 0

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
            font.pixelSize: home.sidebar ? 24 : 13
            text: home.sidebar ? qsTr("What should we work on?") : qsTr("Waiting for the app…")
        }

        Label {
            objectName: "homeDetail"
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: home.sidebar !== null && !home.hasProjects
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: 13
            text: qsTr("Add a project to start your first thread.")
        }

        ShellButton {
            objectName: "homeAction"
            Layout.alignment: Qt.AlignHCenter
            visible: home.sidebar !== null
            primary: true
            iconName: home.hasProjects ? "square-pen" : "folder-plus"
            text: home.hasProjects ? qsTr("New thread") : qsTr("Add project")
            onClicked: {
                if (home.hasProjects)
                    Shell.dispatch("thread.new", {});
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
