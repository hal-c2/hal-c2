pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The Space view's own sidebar (SpaceController): which Space is shown and
// what can be done to it, its page tree, and its trash.
Rectangle {
    id: sidebar

    objectName: "spaceSidebar"

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color selectedFill: Theme.palette.color("sidebarRowSelected", "#27272a")
    readonly property color hoverFill: Theme.palette.color("sidebarRowHover", "#1f1f23")
    // What the name field is for: "", "create" (a new Space), "rename" (this
    // one) or "page" (a new page, inside `parentPageId` when it is set).
    property string naming: ""
    property string parentPageId: ""
    property bool trashShown: false

    signal importRequested

    // Asks for a name for a new page, inside `parentPageId` ("" for the top).
    function newPage(parentPageId) {
        sidebar.parentPageId = parentPageId;
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
                Shell.dispatch("space.page.create", { title: text, parentPageId: sidebar.parentPageId });
        }
        sidebar.naming = "";
    }

    color: Theme.palette.color("sidebar", "#09090b")

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
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
                objectName: "spaceNewPage"
                subtle: true
                iconName: "plus"
                toolTip: qsTr("New page")
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
            placeholderText: sidebar.naming === "page" ? qsTr("Page title") : qsTr("Space name")
            onAccepted: sidebar.finishNaming()
            onActiveFocusChanged: {
                if (!activeFocus)
                    sidebar.naming = "";
            }
            Keys.onEscapePressed: sidebar.naming = ""
        }

        ShellButton {
            objectName: "spaceImportMarkdown"
            Layout.fillWidth: true
            subtle: true
            iconName: "file"
            text: qsTr("Import Markdown")
            enabled: Spaces.spaceId !== ""
            onClicked: sidebar.importRequested()
        }

        ListView {
            id: tree

            objectName: "spacePageTree"
            Layout.fillWidth: true
            Layout.fillHeight: true
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
                readonly property bool selected: model.id === Spaces.pageId

                objectName: "spacePage:" + title
                width: ListView.view.width
                height: 30
                radius: Math.min(Theme.radius, 6)
                color: selected ? sidebar.selectedFill : rowMouse.containsMouse ? sidebar.hoverFill : "transparent"

                MouseArea {
                    id: rowMouse

                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton)
                            pageMenu.popup();
                        else
                            Shell.dispatch("space.selectPage", { pageId: row.model.id });
                    }
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8 + row.depth * 14
                    anchors.rightMargin: 2
                    spacing: 6

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
                        font.family: Theme.fontUi
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                        font.weight: row.selected ? Font.Medium : Font.Normal
                    }

                    ShellButton {
                        objectName: "spacePageMenu:" + row.title
                        subtle: true
                        iconName: "ellipsis"
                        implicitHeight: 24
                        implicitWidth: 24
                        toolTip: qsTr("Page actions")
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

        ShellButton {
            objectName: "spaceTrash"
            Layout.fillWidth: true
            subtle: true
            chevron: true
            iconName: "trash"
            text: Spaces.trash.count > 0 ? qsTr("Trash (%1)").arg(Spaces.trash.count) : qsTr("Trash")
            onClicked: sidebar.trashShown = !sidebar.trashShown
        }

        Text {
            Layout.fillWidth: true
            Layout.leftMargin: 8
            visible: sidebar.trashShown && Spaces.trash.count === 0
            text: qsTr("The trash is empty.")
            color: sidebar.muted
            font.family: Theme.fontUi
            font.pixelSize: Math.round(12 * Theme.fontScale)
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
                    font.family: Theme.fontUi
                    font.pixelSize: Math.round(13 * Theme.fontScale)

                    MouseArea {
                        anchors.fill: parent
                        onClicked: Shell.dispatch("space.selectPage", { pageId: trashed.model.id })
                    }
                }

                ShellButton {
                    objectName: "spaceRestore:" + trashed.title
                    subtle: true
                    iconName: "archive-restore"
                    implicitHeight: 24
                    implicitWidth: 24
                    toolTip: qsTr("Restore")
                    onClicked: Shell.dispatch("space.page.restore", { pageId: trashed.model.id })
                }

                ShellButton {
                    objectName: "spaceDelete:" + trashed.title
                    subtle: true
                    iconName: "x"
                    implicitHeight: 24
                    implicitWidth: 24
                    tint: Theme.palette.color("error", "#ef4444")
                    toolTip: qsTr("Delete for good")
                    onClicked: Shell.dispatch("space.page.delete", { pageId: trashed.model.id })
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
