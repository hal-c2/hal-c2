pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import HalC2.Shell

// The Space view (route kind `space`; SpaceController publishes `space`): the
// Space's pages beside the open one, and its comments beside that when the
// user asks for them. Everything shown is the MC's; with nothing to show it
// says why.
Rectangle {
    id: workspace

    objectName: "spaceWorkspace"

    readonly property var space: Shell.state.space ?? ({})
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color lineColor: Theme.palette.color("border", "#27272a")
    property bool commentsShown: false
    // What the open page's state is when it shows nothing.
    readonly property string emptyText: {
        if (Spaces.status === "unreachable")
            return qsTr("The MC cannot be reached, so its Spaces cannot be shown.");
        if (Spaces.status === "loading")
            return qsTr("Loading the Space…");
        if (Spaces.spaceId === "")
            return qsTr("There are no Spaces. Make one to start writing pages.");
        return qsTr("%1 has no pages yet.").arg(Spaces.spaceName);
    }

    function showComments(blockId) {
        comments.blockId = blockId;
        workspace.commentsShown = true;
        comments.focusDraft();
    }

    color: Theme.palette.color("canvas", "#09090b")

    // Another page's comments are not this one's.
    readonly property string pageId: Spaces.pageId
    onPageIdChanged: comments.blockId = ""

    RowLayout {
        anchors.fill: parent
        spacing: 0

        SpaceSidebar {
            id: sidebar

            Layout.preferredWidth: 260
            Layout.fillHeight: true
            onImportRequested: importDialog.open()
        }

        Rectangle {
            Layout.preferredWidth: 1
            Layout.fillHeight: true
            color: workspace.lineColor
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            SpacePage {
                anchors.fill: parent
                visible: Spaces.pageId !== ""
                onSaveRequested: saveDialog.open()
                onSubpageRequested: parentPageId => sidebar.newPage(parentPageId)
                onCommentRequested: blockId => workspace.showComments(blockId)
            }

            ColumnLayout {
                objectName: "spaceEmpty"
                anchors.centerIn: parent
                width: Math.min(parent.width - 48, 420)
                visible: Spaces.pageId === ""
                spacing: 12

                ShellIcon {
                    Layout.alignment: Qt.AlignHCenter
                    name: Spaces.status === "unreachable" ? "info" : "book"
                    size: 28
                    color: workspace.muted
                }

                Text {
                    objectName: "spaceEmptyText"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: workspace.emptyText
                    color: workspace.foreground
                    font.family: Theme.fontUi
                    font.pixelSize: Math.round(15 * Theme.fontScale)
                }

                Text {
                    Layout.fillWidth: true
                    visible: workspace.space.busy === true
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("Writing a page from the thread…")
                    color: workspace.muted
                    font.family: Theme.fontUi
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    visible: Spaces.status === "live" && Spaces.spaceId !== ""
                    spacing: 8

                    ShellButton {
                        objectName: "spaceEmptyNewPage"
                        primary: true
                        iconName: "plus"
                        text: qsTr("New page")
                        onClicked: sidebar.newPage("")
                    }

                    ShellButton {
                        objectName: "spaceEmptyImport"
                        iconName: "file"
                        text: qsTr("Import Markdown")
                        onClicked: importDialog.open()
                    }
                }
            }
        }

        Rectangle {
            Layout.preferredWidth: 1
            Layout.fillHeight: true
            visible: comments.visible
            color: workspace.lineColor
        }

        SpaceComments {
            id: comments

            Layout.preferredWidth: 300
            Layout.fillHeight: true
            visible: workspace.commentsShown && Spaces.pageId !== ""
            readOnly: Spaces.page.trashed === true
            onCloseRequested: workspace.commentsShown = false
        }
    }

    FileDialog {
        id: importDialog

        title: qsTr("Import Markdown as a page")
        fileMode: FileDialog.OpenFile
        nameFilters: [qsTr("Markdown (*.md *.markdown)"), qsTr("All files (*)")]
        onAccepted: Shell.dispatch("space.page.importFile", { url: selectedFile.toString() })
    }

    FileDialog {
        id: saveDialog

        title: qsTr("Save the page as Markdown")
        fileMode: FileDialog.SaveFile
        defaultSuffix: "md"
        nameFilters: [qsTr("Markdown (*.md)")]
        onAccepted: Shell.dispatch("space.page.saveMarkdown", { pageId: Spaces.pageId, url: selectedFile.toString() })
    }
}
