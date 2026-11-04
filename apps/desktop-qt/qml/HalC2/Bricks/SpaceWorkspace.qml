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
            return qsTr("Spaces can’t be shown");
        if (Spaces.status === "loading")
            return qsTr("Loading the Space…");
        if (Spaces.spaceId === "")
            return qsTr("No Spaces yet");
        return qsTr("%1 has no pages yet").arg(Spaces.spaceName);
    }
    readonly property string emptyDetail: {
        if (Spaces.status === "unreachable")
            return qsTr("The MC cannot be reached. Its Spaces show again once it answers.");
        if (Spaces.status === "loading")
            return "";
        if (Spaces.spaceId === "")
            return qsTr("Make a Space to start writing pages.");
        return workspace.space.busy === true ? qsTr("Writing a page from the thread…") : qsTr("Write one, or import Markdown.");
    }

    function showComments(blockId) {
        if (Spaces.history.shown)
            Shell.dispatch("space.history.close", {});
        comments.blockId = blockId;
        workspace.commentsShown = true;
        comments.focusDraft();
    }

    color: Theme.palette.color("canvas", "#09090b")

    // The Space draws its own header line, the sidebar's Space picker on it,
    // so the layout draws no band above it (RouteView.titleBar): the line is
    // the window's title bar, as a thread's header is.
    readonly property bool titleBar: true
    readonly property bool movesWindow: Theme.frameless && Qt.platform.os !== "android" && Qt.platform.os !== "ios"

    // Under the columns, so their buttons take their own clicks.
    Item {
        objectName: "spaceTitleBar"
        width: parent.width
        height: Theme.headerHeight

        DragHandler {
            enabled: workspace.movesWindow
            target: null
            grabPermissions: PointerHandler.CanTakeOverFromAnything
            onActiveChanged: if (active)
                workspace.Window.window.startSystemMove()
        }

        TapHandler {
            enabled: workspace.movesWindow
            // ljos-allow(focus-pointer-only): a double click on the title bar is the pointer's shortcut for the window controls' Maximize button, which the keyboard reaches
            onDoubleTapped: workspace.Window.window.visibility === Window.Maximized ? workspace.Window.window.showNormal() : workspace.Window.window.showMaximized()
        }
    }

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
            Layout.topMargin: Theme.headerHeight + 1

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

            // Placed by its top, so loading, empty and unreachable share one place.
            ShellEmptyState {
                objectName: "spaceEmpty"
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.round(parent.height / 3)
                visible: Spaces.pageId === "" && Spaces.deckId === "" && !workspace.imagesShown
                status: Spaces.status === "unreachable" ? "error" : Spaces.status === "loading" ? "loading" : "empty"
                iconName: "book"
                title: workspace.emptyText
                description: workspace.emptyDetail
                actionText: Spaces.status === "live" && Spaces.spaceId !== "" ? qsTr("New page") : ""
                secondaryActionText: actionText.length > 0 ? qsTr("Import Markdown") : ""
                onActionTriggered: sidebar.newPage("")
                onSecondaryActionTriggered: importDialog.open()
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
            Layout.topMargin: Theme.headerHeight + 1
            visible: comments.visible || historyPanel.visible
            color: workspace.lineColor
        }

        SpaceComments {
            id: comments

            Layout.preferredWidth: 300
            Layout.fillHeight: true
            Layout.topMargin: Theme.headerHeight + 1
            visible: workspace.commentsShown && Spaces.pageId !== "" && Spaces.deckId === "" && !workspace.imagesShown
            readOnly: Spaces.page.trashed === true
            onCloseRequested: workspace.commentsShown = false
        }

        SpaceHistoryPanel {
            id: historyPanel

            Layout.preferredWidth: 300
            Layout.fillHeight: true
            Layout.topMargin: Theme.headerHeight + 1
            visible: Spaces.history.shown && !workspace.imagesShown
        }
    }

    // The header line's hairline, level with a thread header's, over the columns.
    Rectangle {
        objectName: "spaceHeaderLine"
        y: Theme.headerHeight
        width: parent.width
        height: 1
        color: workspace.lineColor
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

    SpaceFilePicker {}

    FileDialog {
        id: saveDialog

        title: qsTr("Save the page as Markdown")
        fileMode: FileDialog.SaveFile
        defaultSuffix: "md"
        nameFilters: [qsTr("Markdown (*.md)")]
        onAccepted: Shell.dispatch("space.page.saveMarkdown", { pageId: Spaces.pageId, url: selectedFile.toString() })
    }
}
