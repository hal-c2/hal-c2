pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The open page of the Space view (Spaces.page): its title, where it sits,
// the thread it was made from, its update, its blocks, and the timeline's
// prompt (Composer, aimed at the page by ComposerController): it adds a block
// of the kind a `/` picks, asks for a chart with `/visualize <request>`, and
// asks an agent with `@agent`. A trashed page is read only, with the way back.
Rectangle {
    id: page

    objectName: "spacePage"

    readonly property var current: Spaces.page
    readonly property bool trashed: current.trashed === true
    readonly property var site: current.site ?? ({})
    readonly property string siteUrl: site.url ?? ""
    readonly property bool siteBehind: site.behind === true
    readonly property bool siteLocalOnly: site.localOnly === true
    // The project file the page is: {projectId, projectTitle, path, missing, unwritten, conflictAt}, or empty.
    readonly property var file: current.file ?? ({})
    readonly property bool fileBacked: (file.path ?? "") !== ""
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    // What the prompt holds as typed.
    readonly property string promptText: composer.editor.text
    readonly property bool asking: /^@agent(\s|$)/i.test(promptText.trim())
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

    // The words the prompt does not send to an agent come back to be written.
    Connections {
        target: Shell
        function onActionRequested(action, payload) {
            if (action === "space.prompt.write" && payload.pageId === Spaces.pageId)
                page.write(payload.text);
        }
    }

    // Puts `text` in the prompt, the caret at its end and the keyboard on it.
    function setPrompt(text) {
        composer.editor.text = text;
        composer.editor.cursorPosition = text.length;
        composer.flushText();
        composer.focusInput();
    }

    // Starts the words of an ask in the prompt, ahead of a draft already there.
    function startAsk() {
        composer.flushText();
        Shell.dispatch("composer.ask");
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
        page.setPrompt("/visualize " + request);
    }

    // Writes the prompt's words (all but an ask, which the controller sends)
    // as a block of the chosen kind, or asks for the chart they name.
    function write(text) {
        if (slash.visible) {
            slash.choose();
            return;
        }
        if (text.length === 0 || text === "/visualize")
            return;
        if (text.startsWith("/visualize ")) {
            page.visualize(text);
        } else {
            page.insert(page.newKind, text, "");
            if (page.newKind === "heading" || page.newKind === "callout")
                page.newKind = "paragraph";
        }
        page.setPrompt("");
    }

    function chooseKind(kind) {
        if (kind === "chart") {
            page.setPrompt("/visualize ");
            return;
        }
        page.setPrompt("");
        if (kind === "subpage_link") {
            linkMenu.popup(kindButton, 0, -linkMenu.implicitHeight - 4);
            return;
        }
        if (kind === "image") {
            imageMenu.popup(kindButton, 0, -imageMenu.implicitHeight - 4);
            return;
        }
        page.newKind = kind;
        composer.focusInput();
    }

    // A `/` at the start opens the kinds of block, filtered by what follows.
    onPromptTextChanged: {
        if (promptText.startsWith("/") && !promptText.startsWith("/visualize ")) {
            slash.query = promptText.slice(1);
            if (!slash.visible)
                slash.open();
        } else if (slash.visible) {
            slash.close();
        }
    }

    // Each page keeps its own draft in the prompt (ComposerController).
    onCurrentChanged: {
        if ((current.id ?? "") !== titleField.pageId) {
            titleField.pageId = current.id ?? "";
            page.insertAfter = "";
            page.replacing = "";
            page.newKind = "paragraph";
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
                objectName: "spaceAskAgent"
                text: qsTr("Ask an agent…")
                iconName: "sparkles"
                enabled: !page.trashed
                onTriggered: page.startAsk()
            }

            ShellMenuItem {
                objectName: "spaceHistoryOpen"
                text: qsTr("History")
                iconName: "clock"
                onTriggered: Shell.dispatch("space.history.open", { pageId: Spaces.pageId })
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
                objectName: "spaceShowFile"
                text: qsTr("Show the file")
                iconName: "file-text"
                visible: page.fileBacked && !(page.file.missing ?? false)
                height: visible ? implicitHeight : 0
                onTriggered: Shell.dispatch("space.page.showFile", { pageId: Spaces.pageId })
            }

            ShellMenuItem {
                objectName: "spaceUnlinkFile"
                text: qsTr("Stop following the file")
                iconName: "circle-x"
                visible: page.fileBacked
                height: visible ? implicitHeight : 0
                onTriggered: Shell.dispatch("space.page.unlinkFile", { pageId: Spaces.pageId })
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

        SpaceViewers {
            Layout.fillWidth: true
        }

        Text {
            objectName: "spacePageSource"
            visible: (page.current.sourceThreadId ?? "") !== ""
            text: qsTr("Made from the thread “%1”").arg(page.current.sourceThreadTitle ?? "")
            color: page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        // The project file the page is: where it is, and that it is gone or won over an edit.
        Rectangle {
            objectName: "spacePageFile"
            Layout.fillWidth: true
            visible: page.fileBacked
            readonly property bool warn: (page.file.missing ?? false) || (page.file.conflictAt ?? "") !== ""
            implicitHeight: fileColumn.implicitHeight + 12
            radius: Math.min(Theme.radius, 8)
            color: warn ? Qt.alpha(Theme.palette.color("warning", "#f59e0b"), 0.12) : Qt.alpha(page.foreground, 0.05)
            border.color: warn ? Qt.alpha(Theme.palette.color("warning", "#f59e0b"), 0.4) : Qt.alpha(page.foreground, 0.15)

            ColumnLayout {
                id: fileColumn

                anchors.fill: parent
                anchors.margins: 6
                spacing: 4

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    ShellIcon {
                        name: "file-text"
                        size: 14
                        color: page.foreground
                    }

                    Text {
                        objectName: "spacePageFilePath"
                        Layout.fillWidth: true
                        text: qsTr("The file %1 of %2").arg(page.file.path ?? "").arg(page.file.projectTitle ?? "")
                        color: page.foreground
                        elide: Text.ElideMiddle
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    ShellButton {
                        objectName: "spacePageFileShow"
                        text: qsTr("Show file")
                        visible: !(page.file.missing ?? false)
                        onClicked: Shell.dispatch("space.page.showFile", { pageId: Spaces.pageId })
                    }
                }

                Text {
                    objectName: "spacePageFileGone"
                    Layout.fillWidth: true
                    visible: page.file.missing ?? false
                    text: (page.file.unwritten ?? false)
                        ? qsTr("The file is gone, and edits made since are on the page only. If the file comes back, it wins, and those edits stay in the page's history.")
                        : qsTr("The file is gone. The page keeps what it last said; stop following the file to keep it as an ordinary page.")
                    color: page.foreground
                    wrapMode: Text.Wrap
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                RowLayout {
                    objectName: "spacePageFileConflict"
                    Layout.fillWidth: true
                    visible: (page.file.conflictAt ?? "") !== ""
                    spacing: 8

                    Text {
                        Layout.fillWidth: true
                        text: qsTr("The file changed while you were editing, and the page now shows the file. Your edit is in the page's history.")
                        color: page.foreground
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    ShellButton {
                        objectName: "spacePageFileHistory"
                        text: qsTr("History")
                        onClicked: Shell.dispatch("space.history.open", { pageId: Spaces.pageId })
                    }
                }
            }
        }

        SpaceAgentStrip {
            id: agentStrip

            Layout.fillWidth: true
            onHistoryRequested: Shell.dispatch("space.history.open", { pageId: Spaces.pageId })
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
                level: model.level ?? 0
                language: model.language ?? ""
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
                    composer.focusInput();
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
                    page.setPrompt("");
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

        // The timeline's prompt, aimed at the page. It has no checkout, queue
        // or second model: those belong to a thread.
        Composer {
            id: composer

            objectName: "spaceComposer"
            Layout.fillWidth: true
            Layout.leftMargin: -composer.gutter
            Layout.rightMargin: -composer.gutter
            Layout.bottomMargin: 4
            visible: !page.trashed && ready && model.routeKind === "page"
            color: "transparent"
            editorActions: [
                ShellButton {
                    id: kindButton

                    objectName: "spaceNewKind"
                    subtle: true
                    visible: !page.asking
                    iconName: page.kindIcon(page.newKind)
                    text: page.kindLabel(page.newKind)
                    toolTip: qsTr("Kind of block")
                    onClicked: {
                        slash.query = "";
                        slash.open();
                    }
                },
                // Where the ask runs: the project the MC would pick, or the one picked.
                ShellButton {
                    id: projectButton

                    objectName: "spaceAskProject"
                    subtle: true
                    visible: page.asking
                    iconName: "folder"
                    chevron: true
                    text: composer.model?.project?.title ?? qsTr("No project")
                    toolTip: qsTr("The project the agent runs in")
                    onClicked: projectMenu.popup(projectButton, 0, -projectMenu.implicitHeight - 4)
                }
            ]
            onEditorKeyPressed: event => {
                if (event.accepted || event.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier))
                    return;
                if (slash.visible) {
                    event.accepted = true;
                    if (event.key === Qt.Key_Up)
                        slash.move(-1);
                    else if (event.key === Qt.Key_Down)
                        slash.move(1);
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                        slash.choose();
                    else if (event.key === Qt.Key_Escape) {
                        slash.close();
                        page.setPrompt("");
                    } else
                        event.accepted = false;
                } else if (event.key === Qt.Key_Escape && page.insertAfter !== "") {
                    event.accepted = true;
                    page.insertAfter = "";
                }
            }

            SpaceSlashMenu {
                id: slash

                objectName: "spaceSlashMenu"
                x: Math.max(composer.gutter, (composer.width - composer.maximumCardWidth) / 2)
                y: -implicitHeight - 4
                onChosen: kind => page.chooseKind(kind)
            }
        }

        ShellMenu {
            id: projectMenu

            objectName: "spaceAskProjectMenu"

            Instantiator {
                model: projectMenu.visible ? (composer.model?.projects ?? []) : []

                delegate: ShellMenuItem {
                    required property var modelData

                    text: modelData.title
                    iconName: "folder"
                    current: modelData.id === composer.model?.project?.id
                    onTriggered: Shell.dispatch("composer.project.set", { projectId: modelData.id })
                }

                onObjectAdded: (index, object) => projectMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => projectMenu.removeItem(object)
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
