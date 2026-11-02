pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The open page of the Space view (Spaces.page): its title, where it sits,
// the thread it was made from, its update, its blocks, and a composer that adds
// a block of the kind a `/` picks or asks for a chart with `/visualize <request>`.
// A trashed page is read only, with the way back.
Rectangle {
    id: page

    objectName: "spacePage"

    readonly property var current: Spaces.page
    readonly property bool trashed: current.trashed === true
    readonly property var site: current.site ?? ({})
    readonly property string siteUrl: site.url ?? ""
    readonly property bool siteBehind: site.behind === true
    readonly property bool siteLocalOnly: site.localOnly === true
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    // The kind the composer adds, and the block it goes after ("" for the end).
    property string newKind: "paragraph"
    property string insertAfter: ""
    // The chart a `/visualize` replaces ("" for a new one).
    property string replacing: ""
    readonly property string insertAfterText: {
        const row = Spaces.blocks.indexOf(page.insertAfter);
        return row < 0 ? "" : Spaces.blocks.get(row).text;
    }

    signal saveRequested
    // `link`: the new subpage also gets a link block on this page.
    signal subpageRequested(string parentPageId, bool link)
    signal commentRequested(string blockId)
    signal imagesRequested

    function kindLabel(kind) {
        const labels = {
            paragraph: qsTr("Text"),
            heading: qsTr("Heading"),
            checklist: qsTr("Checklist"),
            callout: qsTr("Callout"),
            subpage_link: qsTr("Subpage link"),
            image: qsTr("Image")
        };
        return labels[kind] ?? kind;
    }

    function kindIcon(kind) {
        const icons = { paragraph: "text-wrap", heading: "hash", checklist: "square-check", callout: "info", subpage_link: "link", image: "image" };
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

    function insert(kind, text, linkedPageId, imageId) {
        const payload = { pageId: Spaces.pageId, kind: kind, text: text, checked: false };
        if (linkedPageId)
            payload.linkedPageId = linkedPageId;
        if (imageId)
            payload.imageId = imageId;
        if (page.insertAfter !== "")
            payload.afterBlockId = page.insertAfter;
        Shell.dispatch("space.block.insert", payload);
        page.insertAfter = "";
        page.replacing = "";
    }

    // Asks the MC to draw a chart for `/visualize <request>`, in place of the
    // chart being replaced or where a new block goes.
    function visualize(request) {
        const payload = { pageId: Spaces.pageId, request: request };
        if (page.replacing !== "")
            payload.blockId = page.replacing;
        else if (page.insertAfter !== "")
            payload.afterBlockId = page.insertAfter;
        Shell.dispatch("space.block.visualize", payload);
        page.insertAfter = "";
        page.replacing = "";
    }

    // Puts a chart's request back in the composer, to change and send again.
    function askAgain(blockId, request) {
        page.insertAfter = "";
        page.replacing = blockId;
        composer.text = "/visualize " + request;
        composer.forceActiveFocus();
    }

    // Writes the composer's text as a block of the chosen kind, asks for the
    // chart it names, or opens the kinds when it starts with `/`.
    function submit() {
        if (slash.visible) {
            slash.choose();
            return;
        }
        const text = composer.text.trim();
        if (text.length === 0 || text === "/visualize")
            return;
        if (text.startsWith("/visualize ")) {
            page.visualize(text);
            composer.clear();
            return;
        }
        page.insert(page.newKind, text, "");
        composer.clear();
        if (page.newKind === "heading" || page.newKind === "callout")
            page.newKind = "paragraph";
    }

    function chooseKind(kind) {
        composer.clear();
        if (kind === "chart") {
            composer.text = "/visualize ";
            composer.forceActiveFocus();
            return;
        }
        if (kind === "subpage_link") {
            linkMenu.popup(kindButton, 0, -linkMenu.implicitHeight - 4);
            return;
        }
        if (kind === "image") {
            imageMenu.popup(kindButton, 0, -imageMenu.implicitHeight - 4);
            return;
        }
        page.newKind = kind;
        composer.forceActiveFocus();
    }

    onCurrentChanged: {
        if ((current.id ?? "") !== titleField.pageId) {
            titleField.pageId = current.id ?? "";
            page.insertAfter = "";
            page.replacing = "";
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
                objectName: "spaceUpdateMenu"
                text: (page.current.schedule?.instruction ?? "") !== "" ? qsTr("Change its update…") : qsTr("Update itself…")
                iconName: "clock"
                enabled: !page.trashed
                onTriggered: updateDialog.ask()
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
                objectName: "spaceMakeDeck"
                text: qsTr("Make a deck")
                iconName: "monitor"
                enabled: !page.trashed
                onTriggered: Shell.dispatch("space.deck.createFromPage", { pageId: Spaces.pageId })
            }

            ShellMenuItem {
                objectName: "spacePublish"
                text: page.siteUrl === "" ? qsTr("Publish as a site") : qsTr("Publish again")
                iconName: "globe"
                visible: !page.trashed
                height: visible ? implicitHeight : 0
                onTriggered: Shell.dispatch("space.page.publish", { pageId: Spaces.pageId })
            }

            ShellMenuItem {
                objectName: "spacePublishTailscale"
                text: qsTr("Publish over Tailscale")
                iconName: "globe"
                visible: !page.trashed
                height: visible ? implicitHeight : 0
                onTriggered: Shell.dispatch("space.page.publish", { pageId: Spaces.pageId, tailscale: true })
            }

            ShellMenuItem {
                objectName: "spaceCopySiteLink"
                text: qsTr("Copy site link")
                iconName: "copy"
                visible: page.siteUrl !== ""
                height: visible ? implicitHeight : 0
                onTriggered: Shell.dispatch("space.page.copySiteLink", { pageId: Spaces.pageId })
            }

            ShellMenuItem {
                objectName: "spaceUnpublish"
                text: qsTr("Unpublish")
                iconName: "circle-x"
                visible: page.siteUrl !== ""
                height: visible ? implicitHeight : 0
                onTriggered: Shell.dispatch("space.page.unpublish", { pageId: Spaces.pageId })
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

        // The page's site: where it is, whether it is behind the page, and the ways on and back.
        Rectangle {
            objectName: "spaceSiteBanner"
            Layout.fillWidth: true
            visible: page.siteUrl !== ""
            implicitHeight: siteColumn.implicitHeight + 16
            radius: Math.min(Theme.radius, 8)
            color: Qt.alpha(page.foreground, 0.05)
            border.color: Qt.alpha(page.foreground, 0.15)

            ColumnLayout {
                id: siteColumn

                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    ShellIcon {
                        name: "globe"
                        size: 14
                        color: page.foreground
                    }

                    Text {
                        objectName: "spaceSiteStatus"
                        Layout.fillWidth: true
                        text: page.siteBehind
                            ? qsTr("Published. This page has changes the site does not show until you publish again.")
                            : qsTr("Published. The site shows this page as it is now.")
                        color: page.foreground
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                    }

                    ShellButton {
                        objectName: "spaceSiteCopy"
                        text: qsTr("Copy link")
                        iconName: "copy"
                        onClicked: Shell.dispatch("space.page.copySiteLink", { pageId: Spaces.pageId })
                    }

                    ShellButton {
                        objectName: "spaceSiteRepublish"
                        text: qsTr("Publish again")
                        onClicked: Shell.dispatch("space.page.publish", { pageId: Spaces.pageId })
                    }

                    ShellButton {
                        objectName: "spaceSiteUnpublish"
                        text: qsTr("Unpublish")
                        onClicked: Shell.dispatch("space.page.unpublish", { pageId: Spaces.pageId })
                    }
                }

                Text {
                    objectName: "spaceSiteLink"
                    Layout.fillWidth: true
                    text: page.siteUrl
                    color: page.muted
                    elide: Text.ElideMiddle
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                RowLayout {
                    objectName: "spaceSiteLocalOnly"
                    Layout.fillWidth: true
                    visible: page.siteLocalOnly
                    spacing: 8

                    Text {
                        Layout.fillWidth: true
                        text: qsTr("Only this machine can open this link: the MC listens on loopback.")
                        color: page.foreground
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    ShellButton {
                        objectName: "spaceSiteTailscale"
                        text: qsTr("Publish over Tailscale")
                        onClicked: Shell.dispatch("space.page.publish", { pageId: Spaces.pageId, tailscale: true })
                    }
                }
            }
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

        SpacePageUpdate {
            Layout.fillWidth: true
            onChangeRequested: updateDialog.ask()
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
                chart: model.chart ?? ({})
                readOnly: page.trashed
                previousId: index > 0 ? Spaces.blocks.get(index - 1).id : ""
                beforePreviousId: index > 1 ? Spaces.blocks.get(index - 2).id : ""
                nextId: index + 1 < Spaces.blocks.count ? Spaces.blocks.get(index + 1).id : ""
                onCommentRequested: blockId => page.commentRequested(blockId)
                onAskAgainRequested: (blockId, request) => page.askAgain(blockId, request)
                onAddBelowRequested: blockId => {
                    page.insertAfter = blockId;
                    page.replacing = "";
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
            objectName: "spaceDrawing"
            visible: Shell.state.space?.drawing === true
            text: qsTr("Drawing a chart…")
            color: page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Text {
            objectName: "spaceReplacing"
            visible: page.replacing !== "" && !page.trashed
            text: qsTr("Replacing this chart. Click here to keep it.")
            color: page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    page.replacing = "";
                    composer.clear();
                }
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
                    if (text.startsWith("/") && !text.startsWith("/visualize ")) {
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

        SpaceUpdateDialog {
            id: updateDialog
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

        // The Space's images, which an image block can show.
        ShellMenu {
            id: imageMenu

            objectName: "spaceImageMenu"

            Instantiator {
                model: imageMenu.visible ? Spaces.images : null

                delegate: ShellMenuItem {
                    required property var model

                    objectName: "spaceImageMenu:" + model.name
                    text: model.name
                    iconName: "image"
                    onTriggered: page.insert("image", model.name, "", model.id)
                }

                onObjectAdded: (index, object) => imageMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => imageMenu.removeItem(object)
            }

            ShellMenuItem {
                text: qsTr("No images yet")
                enabled: false
                visible: imageMenu.visible && Spaces.images.count === 0
                height: visible ? implicitHeight : 0
            }

            ShellMenuSeparator {}

            ShellMenuItem {
                objectName: "spaceImageMenuBrowse"
                text: qsTr("Add or generate images…")
                iconName: "plus"
                onTriggered: page.imagesRequested()
            }
        }
    }
}
