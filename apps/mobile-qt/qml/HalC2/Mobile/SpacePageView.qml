pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The open page: its update, its blocks, the way to add one, its comments and
// what can be done with it. A page in the trash is only read, and says so.
ColumnLayout {
    id: view

    required property Item screen
    readonly property var page: Spaces.page ?? ({})
    readonly property bool trashed: page.trashed === true
    readonly property var site: page.site ?? ({})
    readonly property string siteUrl: site.url ?? ""
    // The project file the page is, or nothing.
    readonly property var file: page.file ?? ({})
    // The row being written in, kept above the keyboard.
    property SpaceBlockRow editing: null
    // What the prompt holds as typed, and whether it asks an agent.
    readonly property string promptText: composer.editor.text
    readonly property bool asking: /^@agent(\s|$)/i.test(promptText.trim())
    // The kind of block the prompt writes.
    property string newKind: "paragraph"
    readonly property string pageId: Spaces.pageId

    function keepEditingInView() {
        if (editing !== null)
            blocks.positionViewAtIndex(editing.index, ListView.Contain);
    }

    function kindIcon(kind) {
        const icons = { paragraph: "text-wrap", heading: "hash", checklist: "square-check", callout: "info" };
        return icons[kind] ?? "text-wrap";
    }

    function kindLabel(kind) {
        const labels = { paragraph: qsTr("Text"), heading: qsTr("Heading"), checklist: qsTr("Checklist"), callout: qsTr("Callout") };
        return labels[kind] ?? kind;
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

    // Writes the prompt's words (all but an ask, which the controller sends) as
    // a block of the chosen kind at the end, or asks for the chart they name.
    function write(text) {
        if (slash.visible) {
            slash.choose();
            return;
        }
        if (text.length === 0 || text === "/visualize")
            return;
        if (text.startsWith("/visualize ")) {
            Shell.dispatch("space.block.visualize", { pageId: Spaces.pageId, request: text });
        } else {
            view.screen.insert({ kind: view.newKind, text: text }, undefined);
            if (view.newKind === "heading" || view.newKind === "callout")
                view.newKind = "paragraph";
        }
        view.setPrompt("");
    }

    function chooseKind(kind) {
        view.setPrompt(kind === "chart" ? "/visualize " : "");
        if (kind === "subpage_link")
            view.screen.pickLink(undefined);
        else if (kind === "image")
            view.screen.pickImage(undefined);
        else if (kind !== "chart")
            view.newKind = kind;
    }

    // A `/` at the start offers the kinds of block, filtered by what follows.
    onPromptTextChanged: {
        if (promptText.startsWith("/") && !promptText.startsWith("/visualize ")) {
            slash.query = promptText.slice(1);
            if (!slash.visible)
                slash.open();
        } else if (slash.visible) {
            slash.close();
        }
    }
    onPageIdChanged: newKind = "paragraph"

    // The words the prompt does not send to an agent come back to be written.
    Connections {
        target: Shell
        function onActionRequested(action, payload) {
            if (action === "space.prompt.write" && payload.pageId === Spaces.pageId)
                view.write(payload.text);
        }
    }

    objectName: "spacePageView"
    spacing: 0

    MobileBar {
        Layout.fillWidth: true
        title: view.page.title ?? ""
        canGoBack: true
        onBackRequested: view.screen.backRequested()

        MobileIconButton {
            objectName: "spaceEditDone"
            visible: view.editing !== null
            iconName: "check"
            label: qsTr("Done")
            onClicked: view.screen.forceActiveFocus()
        }

        MobileIconButton {
            objectName: "spaceComments"
            iconName: "message-square"
            label: qsTr("Comments")
            onClicked: view.screen.showComments("")
        }

        MobileIconButton {
            objectName: "spacePageActions"
            iconName: "ellipsis"
            label: qsTr("Page actions")
            onClicked: view.trashed ? view.screen.trashMenu(Spaces.pageId) : view.screen.pageMenu(Spaces.pageId, view.page.title, view.page.parentPageId ?? "", view.site)
        }
    }

    SpaceViewers {
        Layout.fillWidth: true
        Layout.leftMargin: 16
        Layout.rightMargin: 16
        Layout.topMargin: 4
    }

    ListView {
        id: blocks

        objectName: "spaceBlocks"
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // A row that scrolls out while written in goes with what it holds, so
        // keep some around.
        cacheBuffer: 600
        model: Spaces.blocks
        onHeightChanged: Qt.callLater(view.keepEditingInView)

        header: ColumnLayout {
            width: ListView.view.width
            spacing: 0

            Label {
                objectName: "spacePageSource"
                Layout.fillWidth: true
                Layout.margins: 16
                Layout.bottomMargin: 4
                visible: (view.page.sourceThreadId ?? "") !== ""
                wrapMode: Text.Wrap
                text: qsTr("Made from the thread “%1”").arg(view.page.sourceThreadTitle ?? "")
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }

            // The project file the page is: where it is, and that it is gone or won over an edit.
            ColumnLayout {
                objectName: "spacePageFile"
                Layout.fillWidth: true
                Layout.margins: 16
                Layout.bottomMargin: 4
                visible: (view.file.path ?? "") !== ""
                spacing: 4

                Label {
                    objectName: "spacePageFilePath"
                    Layout.fillWidth: true
                    elide: Text.ElideMiddle
                    text: qsTr("The file %1 of %2").arg(view.file.path ?? "").arg(view.file.projectTitle ?? "")
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                Label {
                    objectName: "spacePageFileGone"
                    Layout.fillWidth: true
                    visible: view.file.missing === true
                    wrapMode: Text.Wrap
                    text: view.file.unwritten === true
                        ? qsTr("The file is gone, and edits made since are on the page only. If the file comes back, it wins, and those edits stay in the page's history.")
                        : qsTr("The file is gone. The page keeps what it last said, and if the file comes back, it wins.")
                    color: Theme.palette.color("warning", "#f59e0b")
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                Label {
                    objectName: "spacePageFileConflict"
                    Layout.fillWidth: true
                    visible: (view.file.conflictAt ?? "") !== ""
                    wrapMode: Text.Wrap
                    text: qsTr("The file changed while you were editing, and the page now shows the file. Your edit is in the page's history.")
                    color: Theme.palette.color("warning", "#f59e0b")
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: 4

                    MobileButton {
                        objectName: "spacePageFileShow"
                        subtle: true
                        visible: view.file.missing !== true
                        text: qsTr("Show file")
                        onClicked: Shell.dispatch("space.page.showFile", { pageId: Spaces.pageId })
                    }

                    MobileButton {
                        objectName: "spacePageFileHistory"
                        subtle: true
                        visible: (view.file.conflictAt ?? "") !== ""
                        text: qsTr("History")
                        onClicked: view.screen.showHistory(Spaces.pageId)
                    }
                }
            }

            SpaceAgentStrip {
                Layout.fillWidth: true
                Layout.margins: 16
                Layout.bottomMargin: 4
                buttonHeight: 44
                onHistoryRequested: view.screen.showHistory(Spaces.pageId)
            }

            Label {
                objectName: "spaceTrashedNotice"
                Layout.fillWidth: true
                Layout.margins: 16
                Layout.bottomMargin: 4
                visible: view.trashed
                wrapMode: Text.Wrap
                text: qsTr("This page is in the trash. Restore it to edit it.")
                color: Theme.palette.color("error", "#ef4444")
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }

            // Its actions are in the page's menu, a finger wide.
            SpacePageUpdate {
                Layout.fillWidth: true
                Layout.margins: 12
                Layout.bottomMargin: 4
                actions: false
            }

            // The page's site: where it is, whether it is behind the page, and the ways on and back.
            ColumnLayout {
                objectName: "spaceSiteNotice"
                Layout.fillWidth: true
                Layout.margins: 16
                Layout.bottomMargin: 4
                visible: view.siteUrl !== ""
                spacing: 4

                Label {
                    objectName: "spaceSiteStatus"
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: view.site.behind === true
                        ? qsTr("Published. This page has changes the site does not show until you publish again.")
                        : qsTr("Published. The site shows this page as it is now.")
                    color: Theme.palette.color("text", "#e4e4e7")
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                Label {
                    objectName: "spaceSiteLink"
                    Layout.fillWidth: true
                    elide: Text.ElideMiddle
                    text: view.siteUrl
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                Label {
                    objectName: "spaceSiteLocalOnly"
                    Layout.fillWidth: true
                    visible: view.site.localOnly === true
                    wrapMode: Text.Wrap
                    text: qsTr("Only this machine can open this link: the MC listens on loopback.")
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: 4

                    MobileButton {
                        objectName: "spaceSiteCopy"
                        subtle: true
                        text: qsTr("Copy link")
                        onClicked: Shell.dispatch("space.page.copySiteLink", { pageId: Spaces.pageId })
                    }

                    MobileButton {
                        objectName: "spaceSiteRepublish"
                        subtle: true
                        text: qsTr("Publish again")
                        onClicked: Shell.dispatch("space.page.publish", { pageId: Spaces.pageId })
                    }

                    MobileButton {
                        objectName: "spaceSiteUnpublish"
                        subtle: true
                        text: qsTr("Unpublish")
                        onClicked: Shell.dispatch("space.page.unpublish", { pageId: Spaces.pageId })
                    }

                    MobileButton {
                        objectName: "spaceSiteTailscale"
                        visible: view.site.localOnly === true
                        subtle: true
                        text: qsTr("Publish over Tailscale")
                        onClicked: Shell.dispatch("space.page.publish", { pageId: Spaces.pageId, tailscale: true })
                    }
                }
            }
        }

        delegate: SpaceBlockRow {
            id: blockRow

            width: ListView.view.width
            readOnly: view.trashed
            onScreen: view.visible
            onEditingChanged: {
                if (editing) {
                    view.editing = blockRow;
                    Qt.callLater(view.keepEditingInView);
                } else if (view.editing === blockRow) {
                    view.editing = null;
                }
            }
            onMenuRequested: view.screen.blockMenu(blockRow.index, blockRow.blockId, blockRow.text, blockRow.kind === "chart" ? blockRow.chart.request : undefined)
            onLinkOpened: view.screen.openPage(blockRow.linkedPageId)
            onCommentsRequested: view.screen.showComments(blockRow.blockId)
        }

        footer: ColumnLayout {
            width: ListView.view.width
            spacing: 0

            Label {
                objectName: "spacePageEmpty"
                Layout.fillWidth: true
                Layout.margins: 24
                visible: Spaces.blocks.count === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: qsTr("This page is empty.")
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(14 * Theme.fontScale)
            }

            MobileButton {
                objectName: "spaceAddBlock"
                Layout.alignment: Qt.AlignLeft
                Layout.margins: 12
                visible: !view.trashed
                subtle: true
                text: qsTr("Add block")
                onClicked: view.screen.addBlockMenu(undefined)
            }
        }
    }

    Label {
        objectName: "spaceDrawing"
        Layout.fillWidth: true
        Layout.margins: 12
        visible: Shell.state.space?.drawing === true
        text: qsTr("Drawing a chart…")
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(13 * Theme.fontScale)
    }

    // The timeline's prompt, aimed at the page. It has no checkout, queue or
    // second model: those belong to a thread.
    Composer {
        id: composer

        objectName: "spaceComposer"
        Layout.fillWidth: true
        visible: !view.trashed && ready && model.routeKind === "page"
        editorActions: [
            ShellButton {
                objectName: "spaceNewKind"
                subtle: true
                visible: !view.asking
                iconName: view.kindIcon(view.newKind)
                text: view.kindLabel(view.newKind)
                toolTip: qsTr("Kind of block")
                onClicked: view.setPrompt("/")
            },
            // Where the ask runs: the project the MC would pick, or the one picked.
            ShellButton {
                objectName: "spaceAskProject"
                subtle: true
                visible: view.asking
                iconName: "folder"
                chevron: true
                text: composer.model?.project?.title ?? qsTr("No project")
                toolTip: qsTr("The project the agent runs in")
                onClicked: view.screen.pickAskProject(composer.model?.projects ?? [], composer.model?.project?.id ?? "")
            }
        ]
        onEditorKeyPressed: event => {
            if (event.accepted || !slash.visible || event.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier))
                return;
            event.accepted = true;
            if (event.key === Qt.Key_Up)
                slash.move(-1);
            else if (event.key === Qt.Key_Down)
                slash.move(1);
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                slash.choose();
            else if (event.key === Qt.Key_Escape) {
                slash.close();
                view.setPrompt("");
            } else
                event.accepted = false;
        }

        SpaceSlashMenu {
            id: slash

            objectName: "spaceSlashMenu"
            x: composer.gutter
            y: -implicitHeight - 4
            onChosen: kind => view.chooseKind(kind)
        }
    }
}
