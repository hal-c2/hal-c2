pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The open page of the Space view (Spaces.page): its title, where it sits,
// the thread it was made from, its blocks, and a composer that adds a block
// of the kind a `/` picks. A trashed page is read only, with the way back.
Rectangle {
    id: page

    objectName: "spacePage"

    readonly property var current: Spaces.page
    readonly property bool trashed: current.trashed === true
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    // The kind the composer adds, and the block it goes after ("" for the end).
    property string newKind: "paragraph"
    property string insertAfter: ""
    readonly property string insertAfterText: {
        const row = Spaces.blocks.indexOf(page.insertAfter);
        return row < 0 ? "" : Spaces.blocks.get(row).text;
    }

    signal saveRequested
    // `link`: the new subpage also gets a link block on this page.
    signal subpageRequested(string parentPageId, bool link)
    signal commentRequested(string blockId)

    function kindLabel(kind) {
        const labels = {
            paragraph: qsTr("Text"),
            heading: qsTr("Heading"),
            checklist: qsTr("Checklist"),
            callout: qsTr("Callout"),
            subpage_link: qsTr("Subpage link")
        };
        return labels[kind] ?? kind;
    }

    function kindIcon(kind) {
        const icons = { paragraph: "text-wrap", heading: "hash", checklist: "square-check", callout: "info", subpage_link: "link" };
        return icons[kind] ?? "text-wrap";
    }

    // The pages above the open one, the top first.
    function trail() {
        const pages = Spaces.pages;
        const above = [];
        let parentId = page.current.parentPageId ?? "";
        while (parentId !== "" && above.length < 64) {
            const row = pages.indexOf(parentId);
            if (row < 0)
                break;
            const parent = pages.get(row);
            above.unshift({ id: parent.id, title: parent.title });
            parentId = parent.parentPageId;
        }
        return above;
    }

    // The open page's own subpages, which a link block can point to.
    function subpages() {
        const pages = Spaces.pages;
        const children = [];
        for (let i = 0; i < pages.count; ++i) {
            const row = pages.get(i);
            if (row.parentPageId === Spaces.pageId)
                children.push({ id: row.id, title: row.title });
        }
        return children;
    }

    function insert(kind, text, linkedPageId) {
        const payload = { pageId: Spaces.pageId, kind: kind, text: text, checked: false };
        if (linkedPageId)
            payload.linkedPageId = linkedPageId;
        if (page.insertAfter !== "")
            payload.afterBlockId = page.insertAfter;
        Shell.dispatch("space.block.insert", payload);
        page.insertAfter = "";
    }

    // Writes the composer's text as a block of the chosen kind, or opens the
    // kinds when it starts with `/`.
    function submit() {
        if (slash.visible) {
            slash.choose();
            return;
        }
        const text = composer.text.trim();
        if (text.length === 0)
            return;
        page.insert(page.newKind, text, "");
        composer.clear();
        if (page.newKind === "heading" || page.newKind === "callout")
            page.newKind = "paragraph";
    }

    function chooseKind(kind) {
        composer.clear();
        if (kind === "subpage_link") {
            linkMenu.popup(kindButton, 0, -linkMenu.implicitHeight - 4);
            return;
        }
        page.newKind = kind;
        composer.forceActiveFocus();
    }

    onCurrentChanged: {
        if ((current.id ?? "") !== titleField.pageId) {
            titleField.pageId = current.id ?? "";
            page.insertAfter = "";
            page.newKind = "paragraph";
            composer.clear();
        }
        if (!titleField.activeFocus)
            titleField.text = current.title ?? "";
    }

    color: Theme.palette.color("canvas", "#09090b")

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 48
        anchors.rightMargin: 48
        anchors.topMargin: 24
        spacing: 8

        // Where the page sits: its Space, and the pages above it.
        Flow {
            objectName: "spaceTrail"
            Layout.fillWidth: true
            spacing: 4

            Text {
                text: Spaces.spaceName
                color: page.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            Repeater {
                model: page.current.id ? page.trail() : []

                delegate: Text {
                    id: crumb

                    required property var modelData

                    text: "/  " + modelData.title
                    color: page.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Shell.dispatch("space.selectPage", { pageId: crumb.modelData.id })
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ShellButton {
                id: pageActions

                objectName: "spacePageActions"
                subtle: true
                iconName: "ellipsis"
                Accessible.name: qsTr("Page actions")
                onClicked: actionsMenu.popup(pageActions, 0, pageActions.height + 4)
            }

            TextInput {
                id: titleField

                property string pageId: ""

                objectName: "spacePageTitle"
                Layout.fillWidth: true
                readOnly: page.trashed
                color: page.foreground
                selectByMouse: true
                selectionColor: Theme.palette.color("accent", "#2563eb")
                selectedTextColor: Theme.palette.color("accentForeground", "#ffffff")
                font.pixelSize: Math.round(28 * Theme.fontScale)
                font.weight: Font.Bold
                clip: true

                function commit() {
                    const title = text.trim();
                    if (title.length > 0 && title !== page.current.title)
                        Shell.dispatch("space.page.rename", { pageId: Spaces.pageId, title: title });
                    else
                        text = page.current.title ?? "";
                }

                onAccepted: focus = false
                onActiveFocusChanged: {
                    if (!activeFocus)
                        commit();
                }
                Keys.onEscapePressed: {
                    text = page.current.title ?? "";
                    focus = false;
                }
            }
        }

        ShellMenu {
            id: actionsMenu

            ShellMenuItem {
                text: qsTr("New subpage")
                iconName: "plus"
                enabled: !page.trashed
                onTriggered: page.subpageRequested(Spaces.pageId, false)
            }

            ShellMenuItem {
                objectName: "spaceCopyMarkdown"
                text: qsTr("Copy as Markdown")
                iconName: "copy"
                onTriggered: Shell.dispatch("space.page.copyMarkdown", { pageId: Spaces.pageId })
            }

            ShellMenuItem {
                objectName: "spaceSaveMarkdown"
                text: qsTr("Save as Markdown…")
                iconName: "download"
                onTriggered: page.saveRequested()
            }

            ShellMenuItem {
                text: qsTr("Move to the top of the Space")
                iconName: "arrow-up"
                visible: (page.current.parentPageId ?? "") !== "" && !page.trashed
                height: visible ? implicitHeight : 0
                onTriggered: Shell.dispatch("space.page.move", { pageId: Spaces.pageId, parentPageId: "" })
            }

            ShellMenuSeparator {}

            ShellMenuItem {
                text: page.trashed ? qsTr("Restore") : qsTr("Move to the trash")
                iconName: page.trashed ? "archive-restore" : "trash"
                destructive: !page.trashed
                onTriggered: Shell.dispatch(page.trashed ? "space.page.restore" : "space.page.trash", { pageId: Spaces.pageId })
            }
        }

        Text {
            objectName: "spacePageSource"
            visible: (page.current.sourceThreadId ?? "") !== ""
            text: qsTr("Made from the thread “%1”").arg(page.current.sourceThreadTitle ?? "")
            color: page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Rectangle {
            objectName: "spaceTrashedBanner"
            Layout.fillWidth: true
            visible: page.trashed
            implicitHeight: trashedRow.implicitHeight + 16
            radius: Math.min(Theme.radius, 8)
            color: Qt.alpha(Theme.palette.color("warning", "#f59e0b"), 0.12)
            border.color: Qt.alpha(Theme.palette.color("warning", "#f59e0b"), 0.4)

            RowLayout {
                id: trashedRow

                anchors.fill: parent
                anchors.margins: 8
                spacing: 8

                ShellIcon {
                    name: "trash"
                    size: 14
                    color: page.foreground
                }

                Text {
                    Layout.fillWidth: true
                    text: qsTr("This page is in the trash, so it cannot be changed.")
                    color: page.foreground
                    wrapMode: Text.Wrap
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                ShellButton {
                    objectName: "spacePageRestore"
                    text: qsTr("Restore")
                    iconName: "archive-restore"
                    onClicked: Shell.dispatch("space.page.restore", { pageId: Spaces.pageId })
                }

                ShellButton {
                    objectName: "spacePageDelete"
                    text: qsTr("Delete for good")
                    tint: Theme.palette.color("error", "#ef4444")
                    onClicked: Shell.dispatch("space.page.delete", { pageId: Spaces.pageId })
                }
            }
        }

        ListView {
            id: blocks

            objectName: "spaceBlocks"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 2
            model: Spaces.blocks
            boundsBehavior: Flickable.StopAtBounds
            // Room under the last block, so nothing over the page's corner covers it.
            bottomMargin: 24

            delegate: SpaceBlock {
                required property var model

                width: ListView.view.width
                blockId: model.id
                readOnly: page.trashed
                previousId: index > 0 ? Spaces.blocks.get(index - 1).id : ""
                beforePreviousId: index > 1 ? Spaces.blocks.get(index - 2).id : ""
                nextId: index + 1 < Spaces.blocks.count ? Spaces.blocks.get(index + 1).id : ""
                onCommentRequested: blockId => page.commentRequested(blockId)
                onAddBelowRequested: blockId => {
                    page.insertAfter = blockId;
                    composer.forceActiveFocus();
                }
            }

            Text {
                objectName: "spacePageEmpty"
                anchors.top: parent.top
                anchors.topMargin: 8
                visible: Spaces.blocks.count === 0
                text: page.trashed ? qsTr("This page has no blocks.") : qsTr("This page is empty. Write below, or type / to pick a kind of block.")
                color: page.muted
                font.pixelSize: Math.round(14 * Theme.fontScale)
            }
        }

        Text {
            objectName: "spaceInsertAfter"
            visible: page.insertAfter !== "" && !page.trashed
            text: qsTr("Adding after “%1”").arg(page.insertAfterText)
            color: page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: page.insertAfter = ""
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: 24
            visible: !page.trashed
            spacing: 6

            ShellButton {
                id: kindButton

                objectName: "spaceNewKind"
                subtle: true
                iconName: page.kindIcon(page.newKind)
                text: page.kindLabel(page.newKind)
                toolTip: qsTr("Kind of block")
                onClicked: {
                    slash.query = "";
                    slash.open();
                }
            }

            ShellTextField {
                id: composer

                objectName: "spaceComposer"
                Layout.fillWidth: true
                placeholderText: qsTr("Write, or type / for a kind of block")
                onTextChanged: {
                    if (text.startsWith("/")) {
                        slash.query = text.slice(1);
                        if (!slash.visible)
                            slash.open();
                    } else if (slash.visible) {
                        slash.close();
                    }
                }
                onAccepted: page.submit()
                Keys.onUpPressed: event => {
                    event.accepted = slash.visible;
                    if (slash.visible)
                        slash.move(-1);
                }
                Keys.onDownPressed: event => {
                    event.accepted = slash.visible;
                    if (slash.visible)
                        slash.move(1);
                }
                Keys.onEscapePressed: event => {
                    if (slash.visible) {
                        slash.close();
                        composer.clear();
                    } else if (page.insertAfter !== "") {
                        page.insertAfter = "";
                    } else {
                        event.accepted = false;
                    }
                }

                SpaceSlashMenu {
                    id: slash

                    objectName: "spaceSlashMenu"
                    y: -implicitHeight - 4
                    onChosen: kind => page.chooseKind(kind)
                }
            }
        }

        ShellMenu {
            id: linkMenu

            objectName: "spaceLinkMenu"

            Instantiator {
                model: linkMenu.visible ? page.subpages() : []

                delegate: ShellMenuItem {
                    required property var modelData

                    text: modelData.title
                    iconName: "file-text"
                    onTriggered: page.insert("subpage_link", modelData.title, modelData.id)
                }

                onObjectAdded: (index, object) => linkMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => linkMenu.removeItem(object)
            }

            ShellMenuItem {
                text: qsTr("No subpages yet")
                enabled: false
                visible: linkMenu.visible && page.subpages().length === 0
                height: visible ? implicitHeight : 0
            }

            ShellMenuSeparator {}

            ShellMenuItem {
                objectName: "spaceLinkNewSubpage"
                text: qsTr("New subpage…")
                iconName: "plus"
                onTriggered: page.subpageRequested(Spaces.pageId, true)
            }
        }
    }
}
