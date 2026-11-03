pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The pages of the open Space as a tree with its decks and its trash, and under
// them a section for each project with Space files (`Spaces.projects`, collapsed
// until the user expands it). A file picked in a section is edited as a page of
// its project.
ColumnLayout {
    id: view

    required property Item screen
    // Why there is nothing to list.
    readonly property string emptyText: {
        if (Spaces.status === "unreachable")
            return qsTr("The MC cannot be reached, so its Spaces cannot be shown.");
        if (Spaces.status === "loading")
            return qsTr("Loading the Space…");
        return qsTr("%1 has no pages yet.").arg(Spaces.spaceName);
    }

    objectName: "spacePagesView"
    spacing: 0

    MobileBar {
        Layout.fillWidth: true
        title: Spaces.spaceName
        canGoBack: true
        onBackRequested: view.screen.backRequested()

        MobileIconButton {
            objectName: "spaceImages"
            iconName: "image"
            label: qsTr("Images")
            onClicked: view.screen.showImages()
        }

        MobileIconButton {
            objectName: "spaceImport"
            iconName: "download"
            label: qsTr("Import Markdown")
            onClicked: view.screen.askImport()
        }

        MobileIconButton {
            objectName: "spaceNewPage"
            iconName: "plus"
            label: qsTr("New page")
            onClicked: view.screen.askNewPage("")
        }
    }

    ListView {
        objectName: "spacePages"
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: Spaces.pages

        delegate: SpaceListRow {
            required property var model
            required property string parentPageId

            objectName: "spacePage:" + title
            width: ListView.view.width
            title: model.title
            depth: model.depth
            iconName: model.fromThread ? "message-square" : "file-text"
            menuName: "spacePageMenu:" + model.title
            onClicked: view.screen.openPage(model.id)
            onMenuRequested: view.screen.pageMenu(model.id, model.title, parentPageId)
        }

        footer: ColumnLayout {
            width: ListView.view.width
            spacing: 0

            Label {
                objectName: "spaceEmptyText"
                Layout.fillWidth: true
                Layout.margins: 24
                visible: Spaces.pages.count === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(14 * Theme.fontScale)
                text: view.emptyText
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.topMargin: 16
                Layout.rightMargin: 4
                spacing: 8

                Label {
                    objectName: "spaceDecks"
                    Layout.fillWidth: true
                    text: qsTr("Decks")
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    font.weight: Font.DemiBold
                }

                MobileButton {
                    objectName: "spaceNewDeck"
                    subtle: true
                    text: qsTr("New deck")
                    onClicked: view.screen.askNewDeck()
                }
            }

            Repeater {
                model: Spaces.decks

                delegate: SpaceListRow {
                    required property var model

                    objectName: "spaceDeck:" + title
                    Layout.fillWidth: true
                    title: model.title
                    iconName: "play"
                    menuName: "spaceDeckMenu:" + model.title
                    onClicked: view.screen.openDeck(model.id)
                    onMenuRequested: view.screen.deckMenu(model.id, model.title)
                }
            }

            Label {
                objectName: "spaceTrash"
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.topMargin: 16
                Layout.bottomMargin: 4
                visible: Spaces.trash.count > 0 || Spaces.deckTrash.count > 0
                text: qsTr("Trash")
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.DemiBold
            }

            Repeater {
                model: Spaces.trash

                delegate: SpaceListRow {
                    id: trashed

                    required property var model

                    objectName: "spaceTrashRow:" + title
                    Layout.fillWidth: true
                    title: model.title
                    iconName: "trash"
                    menuName: "spaceTrashMenu:" + model.title
                    onClicked: view.screen.openPage(model.id)
                    onMenuRequested: view.screen.trashMenu(model.id)
                }
            }

            Repeater {
                model: Spaces.deckTrash

                delegate: SpaceListRow {
                    required property var model

                    objectName: "spaceDeckTrashRow:" + title
                    Layout.fillWidth: true
                    title: model.title
                    iconName: "trash"
                    menuName: "spaceDeckTrashMenu:" + model.title
                    onClicked: view.screen.openDeck(model.id)
                    onMenuRequested: view.screen.deckTrashMenu(model.id)
                }
            }
        }
    }

    ListView {
        objectName: "spaceProjects"
        Layout.fillWidth: true
        // The sections take the room they need, up to half the screen's; their own
        // list, so an expanded project builds only the rows on screen.
        Layout.preferredHeight: Math.min(contentHeight, view.height / 2)
        visible: count > 0
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: Spaces.projects

        delegate: SpaceListRow {
            required property var model
            readonly property bool section: model.kind === "project"

            objectName: section ? "spaceProject:" + model.projectId : "spaceProject" + (model.kind === "file" ? "File:" : "Folder:") + model.projectId + ":" + model.path
            width: ListView.view.width
            // A gap above each section, outside its highlight.
            implicitHeight: section ? 60 : 52
            topInset: section ? 8 : 0
            topPadding: topInset
            title: model.name
            depth: model.depth
            iconName: section ? (model.expanded ? "chevron-down" : "chevron-right") : model.kind === "folder" ? (model.expanded ? "folder-open" : "folder") : "file-text"
            Accessible.name: model.kind === "file" ? model.name : (model.expanded ? qsTr("Collapse %1") : qsTr("Expand %1")).arg(model.name)
            function setExpanded(open) {
                if (model.kind === "file" || open === model.expanded)
                    return;
                Shell.dispatch("space.project.setExpanded", section ? { projectId: model.projectId, expanded: open } : { projectId: model.projectId, path: model.path, expanded: open });
            }

            onClicked: {
                if (model.kind === "file")
                    Shell.dispatch("space.openFile", { projectId: model.projectId, relativePath: model.path });
                else
                    setExpanded(!model.expanded);
            }
            // A hardware keyboard: Space clicks, Left and Right collapse and expand.
            Keys.onLeftPressed: event => {
                event.accepted = model.kind !== "file";
                setExpanded(false);
            }
            Keys.onRightPressed: event => {
                event.accepted = model.kind !== "file";
                setExpanded(true);
            }
        }
    }
}
