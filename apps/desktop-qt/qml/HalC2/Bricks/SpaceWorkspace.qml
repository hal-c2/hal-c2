pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import HalC2.Shell

// The Space view (route kind `space`; SpaceController publishes `space`): the
// Space's pages and decks beside the open one, or beside its images, and a page's
// comments or its history beside that when the user asks for them; a version being
// read takes the page's place. Everything shown is the MC's; with nothing to show
// it says why.
Rectangle {
    id: workspace

    objectName: "spaceWorkspace"

    readonly property var space: Shell.state.space ?? ({})
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color lineColor: Theme.palette.color("border", "#27272a")
    property bool commentsShown: false
    property bool imagesShown: false
    // Signing an address for every image lasts only as long as they are on screen.
    readonly property bool browsing: imagesShown && visible
    onBrowsingChanged: Shell.dispatch("space.images.show", { shown: browsing })
    Component.onDestruction: {
        if (browsing)
            Shell.dispatch("space.images.show", { shown: false });
    }
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
        if (Spaces.history.shown)
            Shell.dispatch("space.history.close", {});
        comments.blockId = blockId;
        workspace.commentsShown = true;
        comments.focusDraft();
    }

    color: Theme.palette.color("canvas", "#09090b")

    // Another page's comments are not this one's.
    readonly property string pageId: Spaces.pageId
    onPageIdChanged: comments.blockId = ""

    // A deck just opened, made in the sidebar say, is what the user wants to see.
    readonly property string deckId: Spaces.deckId
    onDeckIdChanged: {
        if (deckId !== "")
            imagesShown = false;
    }

    // One column beside the page at a time.
    Connections {
        target: Spaces.history
        function onChanged() {
            if (Spaces.history.shown)
                workspace.commentsShown = false;
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        SpaceSidebar {
            id: sidebar

            Layout.preferredWidth: 260
            Layout.fillHeight: true
            onImportRequested: importDialog.open()
            onImagesRequested: workspace.imagesShown = true
            onPageChosen: workspace.imagesShown = false
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
                visible: Spaces.pageId !== "" && Spaces.deckId === "" && !Spaces.history.reading && !workspace.imagesShown
                onImagesRequested: workspace.imagesShown = true
                onSaveRequested: saveDialog.open()
                onSubpageRequested: (parentPageId, link) => sidebar.newPage(parentPageId, link)
                onCommentRequested: blockId => workspace.showComments(blockId)
            }

            SpaceVersionView {
                anchors.fill: parent
                visible: Spaces.history.reading && !workspace.imagesShown
            }

            SpaceDeck {
                anchors.fill: parent
                visible: Spaces.deckId !== "" && !workspace.imagesShown
            }

            ColumnLayout {
                objectName: "spaceEmpty"
                anchors.centerIn: parent
                width: Math.min(parent.width - 48, 420)
                visible: Spaces.pageId === "" && Spaces.deckId === "" && !workspace.imagesShown
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
                    font.pixelSize: Math.round(15 * Theme.fontScale)
                }

                Text {
                    Layout.fillWidth: true
                    visible: workspace.space.busy === true
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("Writing a page from the thread…")
                    color: workspace.muted
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

            SpaceImages {
                anchors.fill: parent
                visible: workspace.imagesShown
                onAddRequested: imageDialog.open()
                onGenerateRequested: generateDialog.open()
                onCloseRequested: workspace.imagesShown = false
            }
        }

        Rectangle {
            Layout.preferredWidth: 1
            Layout.fillHeight: true
            visible: comments.visible || historyPanel.visible
            color: workspace.lineColor
        }

        SpaceComments {
            id: comments

            Layout.preferredWidth: 300
            Layout.fillHeight: true
            visible: workspace.commentsShown && Spaces.pageId !== "" && Spaces.deckId === "" && !workspace.imagesShown
            readOnly: Spaces.page.trashed === true
            onCloseRequested: workspace.commentsShown = false
        }

        SpaceHistoryPanel {
            id: historyPanel

            Layout.preferredWidth: 300
            Layout.fillHeight: true
            visible: Spaces.history.shown && !workspace.imagesShown
        }
    }

    SpacePresenter {
        anchors.fill: parent
    }

    FileDialog {
        id: importDialog

        title: qsTr("Import Markdown as a page")
        fileMode: FileDialog.OpenFile
        nameFilters: [qsTr("Markdown (*.md *.markdown)"), qsTr("All files (*)")]
        onAccepted: Shell.dispatch("space.page.importFile", { url: selectedFile.toString() })
    }

    FileDialog {
        id: imageDialog

        title: qsTr("Add an image to the Space")
        fileMode: FileDialog.OpenFile
        nameFilters: [qsTr("Images (*.png *.jpg *.jpeg *.gif *.webp)"), qsTr("All files (*)")]
        onAccepted: Shell.dispatch("space.image.addFile", { url: selectedFile.toString() })
    }

    SpaceImageDialog {
        id: generateDialog
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
