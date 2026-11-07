pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The Space view's own sidebar (SpaceController): which Space is shown and
// what can be done to it, its page tree, a section for each project with Space
// files (`Spaces.projects`, collapsed until the user expands it), its decks, and
// its trash. A file picked in a section is edited as a page of its project.
Rectangle {
    id: sidebar

    objectName: "spaceSidebar"

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color selectedFill: Theme.palette.color("sidebarRowSelected", "#27272a")
    readonly property color hoverFill: Theme.palette.color("sidebarRowHover", "#1f1f23")
    // What the name field is for: "", "create" (a new Space), "rename" (this
    // one), "page" (a new page, inside `parentPageId` when it is set) or "deck"
    // (a new deck).
    property string naming: ""
    property string parentPageId: ""
    property bool linkFromParent: false
    property bool trashShown: false
    readonly property int trashCount: Spaces.trash.count + Spaces.deckTrash.count

    signal importRequested
    signal imagesRequested
    // The user went to a page: the Space's images give way to it.
    signal pageChosen

    // Asks for a name for a new page, inside `parentPageId` ("" for the top),
    // and with `link` also links to it from that parent.
    function newPage(parentPageId, link) {
        sidebar.parentPageId = parentPageId;
        sidebar.linkFromParent = link === true && parentPageId !== "";
        sidebar.name("page", "");
    }

    function name(what, text) {
        sidebar.naming = what;
        nameField.text = text;
        nameField.selectAll();
        nameField.forceActiveFocus();
    }

    function finishNaming() {
        const text = nameField.text.trim();
        if (text.length > 0) {
            if (sidebar.naming === "create")
                Shell.dispatch("space.create", { name: text });
            else if (sidebar.naming === "rename")
                Shell.dispatch("space.rename", { spaceId: Spaces.spaceId, name: text });
            else if (sidebar.naming === "page")
                Shell.dispatch("space.page.create", { title: text, parentPageId: sidebar.parentPageId, link: sidebar.linkFromParent });
            else if (sidebar.naming === "deck")
                Shell.dispatch("space.deck.create", { title: text });
        }
        sidebar.naming = "";
    }

    color: Theme.palette.color("sidebar", "#09090b")

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.space.sm
        spacing: Theme.space.sm

        // On the header line a thread's header shares (Theme.headerHeight),
        // from the window's top to the hairline under it.
        RowLayout {
            objectName: "spaceHeader"
            Layout.fillWidth: true
            Layout.topMargin: -Theme.space.sm
            Layout.preferredHeight: Theme.headerHeight
            spacing: 4

            ShellButton {
                id: spacePicker

                objectName: "spacePicker"
                Layout.fillWidth: true
                subtle: true
                chevron: true
                iconName: "book"
                text: Spaces.spaceName || qsTr("Spaces")
                toolTip: qsTr("Choose a Space")
                onClicked: spaceMenu.popup(spacePicker, 0, spacePicker.height + 4)
            }

            ShellButton {
                objectName: "spaceImportMarkdown"
                subtle: true
                iconName: "file"
                Accessible.name: qsTr("Import Markdown")
                enabled: Spaces.spaceId !== ""
                onClicked: sidebar.importRequested()
            }

            ShellButton {
                objectName: "spaceNewPage"
                subtle: true
                iconName: "plus"
                Accessible.name: qsTr("New page")
                enabled: Spaces.spaceId !== ""
                onClicked: sidebar.newPage("")
            }
        }

        ShellMenu {
            id: spaceMenu

            Instantiator {
                model: Spaces.spaces

                delegate: ShellMenuItem {
                    required property var model

                    objectName: "spaceMenu:" + model.name
                    text: model.name
                    current: model.id === Spaces.spaceId
                    onTriggered: Shell.dispatch("space.select", { spaceId: model.id })
                }

                onObjectAdded: (index, object) => spaceMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => spaceMenu.removeItem(object)
            }

            ShellMenuSeparator {}

            ShellMenuItem {
                objectName: "spaceMenuCreate"
                text: qsTr("New Space…")
                iconName: "plus"
                onTriggered: sidebar.name("create", "")
            }

            ShellMenuItem {
                objectName: "spaceMenuRename"
                text: qsTr("Rename Space…")
                iconName: "pencil"
                enabled: Spaces.spaceId !== ""
                onTriggered: sidebar.name("rename", Spaces.spaceName)
            }

            ShellMenuItem {
                objectName: "spaceMenuDelete"
                text: qsTr("Delete Space")
                iconName: "trash"
                destructive: true
                // The MC keeps a Space that still has pages, and says so.
                enabled: Spaces.spaceId !== ""
                onTriggered: Shell.dispatch("space.delete", { spaceId: Spaces.spaceId })
            }
        }

        ShellTextField {
            id: nameField

            objectName: "spaceNameField"
            Layout.fillWidth: true
            visible: sidebar.naming !== ""
            placeholderText: sidebar.naming === "page" ? qsTr("Page title") : sidebar.naming === "deck" ? qsTr("Deck title") : qsTr("Space name")
            onAccepted: sidebar.finishNaming()
            onActiveFocusChanged: {
                if (!activeFocus)
                    sidebar.naming = "";
            }
            Keys.onEscapePressed: sidebar.naming = ""
        }

        ListView {
            id: tree

            objectName: "spacePageTree"
            Layout.fillWidth: true
            // As tall as its pages, less when the sidebar is short: the
            // project sections follow the last page, not the sidebar's foot.
            Layout.fillHeight: true
            Layout.preferredHeight: contentHeight
            Layout.maximumHeight: contentHeight
            clip: true
            spacing: 1
            model: Spaces.pages
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: row

                required property var model
                required property int index
                required property string title
                required property int depth
                required property string parentPageId
                required property bool fromThread
                readonly property bool selected: model.id === Spaces.pageId && Spaces.deckId === ""

                objectName: "spacePage:" + title
                width: ListView.view.width
                height: 30
                radius: Theme.radiusSm
                color: selected ? sidebar.selectedFill : rowMouse.containsMouse ? sidebar.hoverFill : "transparent"

                MouseArea {
                    id: rowMouse

                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton) {
                            pageMenu.popup();
                        } else {
                            Shell.dispatch("space.selectPage", { pageId: row.model.id });
                            sidebar.pageChosen();
                        }
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space.sm + row.depth * Theme.space.md
                    anchors.rightMargin: 2
                    spacing: Theme.space.sm

                    ShellIcon {
                        name: row.fromThread ? "message-square" : "file-text"
                        size: 14
                        color: sidebar.muted
                    }

                    Text {
                        Layout.fillWidth: true
                        text: row.title
                        elide: Text.ElideRight
                        color: sidebar.foreground
                        font.pixelSize: Theme.type.body.size
                        font.weight: row.selected ? Font.Medium : Font.Normal
                    }

                    ShellButton {
                        objectName: "spacePageMenu:" + row.title
                        subtle: true
                        iconName: "ellipsis"
                        implicitHeight: 24
                        implicitWidth: 24
                        Accessible.name: qsTr("Page actions")
                        opacity: rowMouse.containsMouse || hovered || row.selected || pageMenu.visible ? 1 : 0
                        onClicked: pageMenu.popup(this, 0, height + 2)
                    }
                }

                ShellMenu {
                    id: pageMenu

                    ShellMenuItem {
                        text: qsTr("New subpage")
                        iconName: "plus"
                        onTriggered: sidebar.newPage(row.model.id)
                    }

                    ShellMenuItem {
                        text: qsTr("Move to the top of the Space")
                        iconName: "arrow-up"
                        visible: row.parentPageId !== ""
                        height: visible ? implicitHeight : 0
                        onTriggered: Shell.dispatch("space.page.move", { pageId: row.model.id, parentPageId: "" })
                    }

                    ShellMenu {
                        id: moveInto

                        title: qsTr("Move into")

                        Instantiator {
                            // Every other page but its own subpages, which
                            // follow it in the tree at a greater depth.
                            model: pageMenu.visible ? sidebar.movesFor(row.index) : []

                            delegate: ShellMenuItem {
                                required property var modelData

                                text: modelData.title
                                onTriggered: Shell.dispatch("space.page.move", { pageId: row.model.id, parentPageId: modelData.id })
                            }

                            onObjectAdded: (index, object) => moveInto.insertItem(index, object)
                            onObjectRemoved: (index, object) => moveInto.removeItem(object)
                        }
                    }

                    ShellMenuSeparator {}

                    ShellMenuItem {
                        objectName: "spacePageTrash:" + row.title
                        text: qsTr("Move to the trash")
                        iconName: "trash"
                        destructive: true
                        onTriggered: Shell.dispatch("space.page.trash", { pageId: row.model.id })
                    }
                }
            }
        }

        ListView {
            id: projectSections

            objectName: "spaceProjects"
            Layout.fillWidth: true
            // The sections take the room they need, up to half the sidebar's.
            Layout.preferredHeight: Math.min(contentHeight, sidebar.height / 2)
            // More, up to all of it, when the pages leave the room.
            Layout.fillHeight: true
            Layout.maximumHeight: contentHeight
            visible: count > 0
            clip: true
            spacing: 1
            model: Spaces.projects
            boundsBehavior: Flickable.StopAtBounds

            // An expanded project can take more than the room: a thin
            // scrollbar says the sections go on.
            ShellScrollEdge {
                target: projectSections
            }

            delegate: Rectangle {
                id: entry

                required property var model
                required property string kind
                required property string projectId
                required property string path
                required property string name
                required property int depth
                required property bool expanded
                required property string pageId
                readonly property bool section: kind === "project"
                readonly property bool selected: kind === "file" && pageId !== "" && pageId === Spaces.pageId && Spaces.fileSpaceId !== "" && Spaces.deckId === ""

                objectName: section ? "spaceProject:" + projectId : "spaceProject" + (kind === "file" ? "File:" : "Folder:") + projectId + ":" + path
                width: ListView.view.width
                height: section ? 28 : 26
                radius: Theme.radiusSm
                color: selected ? sidebar.selectedFill : entryMouse.containsMouse ? sidebar.hoverFill : "transparent"
                border.width: activeFocus ? 1 : 0
                border.color: Theme.palette.color("focus", "#3b82f6")
                // Tab reaches each row; Space or Return does what a click does, Left and
                // Right collapse and expand a section or a folder.
                activeFocusOnTab: true

                Accessible.role: kind === "file" ? Accessible.ListItem : Accessible.Button
                Accessible.name: kind === "file" ? name : (expanded ? qsTr("Collapse %1") : qsTr("Expand %1")).arg(name)

                function setExpanded(expanded) {
                    if (kind === "file" || expanded === entry.expanded)
                        return;
                    Shell.dispatch("space.project.setExpanded", section ? { projectId: projectId, expanded: expanded } : { projectId: projectId, path: path, expanded: expanded });
                }

                function activate() {
                    if (kind !== "file") {
                        setExpanded(!expanded);
                    } else {
                        Shell.dispatch("space.openFile", { projectId: projectId, relativePath: path });
                        sidebar.pageChosen();
                    }
                }

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                        activate();
                    else if ((event.key === Qt.Key_Left || event.key === Qt.Key_Right) && kind !== "file")
                        setExpanded(event.key === Qt.Key_Right);
                    else
                        return;
                    event.accepted = true;
                }

                MouseArea {
                    id: entryMouse

                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: entry.activate()
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.space.sm + entry.depth * Theme.space.md
                    anchors.rightMargin: Theme.space.sm
                    spacing: Theme.space.sm

                    ShellIcon {
                        name: entry.section ? (entry.expanded ? "chevron-down" : "chevron-right") : entry.kind === "folder" ? (entry.expanded ? "folder-open" : "folder") : "file-text"
                        size: entry.section ? 12 : 14
                        color: sidebar.muted
                    }

                    Text {
                        Layout.fillWidth: true
                        text: entry.name
                        elide: entry.section ? Text.ElideRight : Text.ElideMiddle
                        color: entry.section || entry.kind === "folder" ? sidebar.muted : sidebar.foreground
                        font.pixelSize: entry.section ? Theme.type.meta.size : Theme.type.body.size
                        font.weight: entry.selected || entry.section ? Font.Medium : Font.Normal
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 8
            spacing: 4

            Text {
                Layout.fillWidth: true
                text: qsTr("Decks")
                color: sidebar.muted
                font.pixelSize: Theme.type.meta.size
            }

            ShellButton {
                objectName: "spaceNewDeck"
                subtle: true
                iconName: "plus"
                implicitHeight: 24
                implicitWidth: 24
                Accessible.name: qsTr("New deck")
                enabled: Spaces.spaceId !== ""
                onClicked: sidebar.name("deck", "")
            }
        }

        ListView {
            objectName: "spaceDecks"
            Layout.fillWidth: true
            // The decks take the room they need, up to a part of the sidebar's.
            Layout.preferredHeight: Math.min(contentHeight, sidebar.height / 4)
            clip: true
            spacing: 1
            model: Spaces.decks
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: deckRow

                required property var model
                required property string title
                readonly property bool selected: model.id === Spaces.deckId

                objectName: "spaceDeckRow:" + title
                width: ListView.view.width
                height: 30
                radius: Theme.radiusSm
                color: selected ? sidebar.selectedFill : deckMouse.containsMouse ? sidebar.hoverFill : "transparent"

                MouseArea {
                    id: deckMouse

                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton)
                            deckMenu.popup();
                        else {
                            Shell.dispatch("space.selectDeck", { deckId: deckRow.model.id });
                            sidebar.pageChosen();
                        }
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 2
                    spacing: Theme.space.sm

                    ShellIcon {
                        name: "monitor"
                        size: 14
                        color: sidebar.muted
                    }

                    Text {
                        Layout.fillWidth: true
                        text: deckRow.title
                        elide: Text.ElideRight
                        color: sidebar.foreground
                        font.pixelSize: Theme.type.body.size
                        font.weight: deckRow.selected ? Font.Medium : Font.Normal
                    }

                    ShellButton {
                        objectName: "spaceDeckMenu:" + deckRow.title
                        subtle: true
                        iconName: "ellipsis"
                        implicitHeight: 24
                        implicitWidth: 24
                        Accessible.name: qsTr("Deck actions")
                        opacity: deckMouse.containsMouse || hovered || deckRow.selected || deckMenu.visible ? 1 : 0
                        onClicked: deckMenu.popup(this, 0, height + 2)
                    }
                }

                ShellMenu {
                    id: deckMenu

                    ShellMenuItem {
                        objectName: "spaceDeckPresent:" + deckRow.title
                        text: qsTr("Present")
                        iconName: "play"
                        onTriggered: Shell.dispatch("space.deck.present", { deckId: deckRow.model.id })
                    }

                    ShellMenuSeparator {}

                    ShellMenuItem {
                        objectName: "spaceDeckTrash:" + deckRow.title
                        text: qsTr("Move to the trash")
                        iconName: "trash"
                        destructive: true
                        onTriggered: Shell.dispatch("space.deck.trash", { deckId: deckRow.model.id })
                    }
                }
            }
        }

        // What is left of the height, so Images and Trash keep to the foot.
        Item {
            Layout.fillHeight: true
        }

        // Images and Trash start where the rows' text does, not centred.
        ShellButton {
            objectName: "spaceImages"
            Layout.alignment: Qt.AlignLeft
            subtle: true
            iconName: "image"
            enabled: Spaces.spaceId !== ""
            text: Spaces.images.count > 0 ? qsTr("Images (%1)").arg(Spaces.images.count) : qsTr("Images")
            onClicked: sidebar.imagesRequested()
        }

        ShellButton {
            objectName: "spaceTrash"
            Layout.alignment: Qt.AlignLeft
            subtle: true
            chevron: true
            iconName: "trash"
            text: sidebar.trashCount > 0 ? qsTr("Trash (%1)").arg(sidebar.trashCount) : qsTr("Trash")
            onClicked: sidebar.trashShown = !sidebar.trashShown
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: 8
            visible: sidebar.trashShown && sidebar.trashCount === 0
            text: qsTr("The trash is empty.")
            color: sidebar.muted
            font.pixelSize: Theme.type.meta.size
        }

        Repeater {
            model: sidebar.trashShown ? Spaces.trash : null

            delegate: RowLayout {
                id: trashed

                required property var model
                required property string title

                objectName: "spaceTrashed:" + title
                Layout.fillWidth: true
                Layout.leftMargin: 8
                spacing: 2

                Text {
                    Layout.fillWidth: true
                    text: trashed.title
                    elide: Text.ElideRight
                    color: sidebar.muted
                    font.pixelSize: Theme.type.body.size

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            Shell.dispatch("space.selectPage", { pageId: trashed.model.id });
                            sidebar.pageChosen();
                        }
                    }
                }

                ShellButton {
                    objectName: "spaceRestore:" + trashed.title
                    subtle: true
                    iconName: "archive-restore"
                    implicitHeight: 24
                    implicitWidth: 24
                    Accessible.name: qsTr("Restore")
                    onClicked: Shell.dispatch("space.page.restore", { pageId: trashed.model.id })
                }

                ShellButton {
                    objectName: "spaceDelete:" + trashed.title
                    subtle: true
                    iconName: "x"
                    implicitHeight: 24
                    implicitWidth: 24
                    tint: Theme.palette.color("error", "#ef4444")
                    Accessible.name: qsTr("Delete for good")
                    onClicked: Shell.dispatch("space.page.delete", { pageId: trashed.model.id })
                }
            }
        }

        Repeater {
            model: sidebar.trashShown ? Spaces.deckTrash : null

            delegate: RowLayout {
                id: trashedDeck

                required property var model
                required property string title

                objectName: "spaceTrashedDeck:" + title
                Layout.fillWidth: true
                Layout.leftMargin: 8
                spacing: 2

                ShellIcon {
                    name: "monitor"
                    size: 14
                    color: sidebar.muted
                }

                Text {
                    Layout.fillWidth: true
                    text: trashedDeck.title
                    elide: Text.ElideRight
                    color: sidebar.muted
                    font.pixelSize: Theme.type.body.size

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            Shell.dispatch("space.selectDeck", { deckId: trashedDeck.model.id });
                            sidebar.pageChosen();
                        }
                    }
                }

                ShellButton {
                    objectName: "spaceRestoreDeck:" + trashedDeck.title
                    subtle: true
                    iconName: "archive-restore"
                    implicitHeight: 24
                    implicitWidth: 24
                    Accessible.name: qsTr("Restore")
                    onClicked: Shell.dispatch("space.deck.restore", { deckId: trashedDeck.model.id })
                }

                ShellButton {
                    objectName: "spaceDeleteDeck:" + trashedDeck.title
                    subtle: true
                    iconName: "x"
                    implicitHeight: 24
                    implicitWidth: 24
                    tint: Theme.palette.color("error", "#ef4444")
                    Accessible.name: qsTr("Delete for good")
                    onClicked: Shell.dispatch("space.deck.delete", { deckId: trashedDeck.model.id })
                }
            }
        }
    }

    // The pages the tree's row `index` can move into: all but itself and the
    // rows after it that are deeper than it (its subpages).
    function movesFor(index) {
        const pages = Spaces.pages;
        const own = pages.get(index);
        const moves = [];
        let inside = true;
        for (let i = 0; i < pages.count; ++i) {
            const page = pages.get(i);
            if (i === index)
                continue;
            if (i > index && inside && page.depth > own.depth)
                continue;
            if (i > index)
                inside = false;
            if (page.id !== own.parentPageId)
                moves.push({ id: page.id, title: page.title });
        }
        return moves;
    }
}
