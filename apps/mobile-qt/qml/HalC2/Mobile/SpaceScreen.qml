pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Dialogs
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The Spaces in the phone layout, one step at a time: the list of Spaces, a
// Space's pages or images, a page, its comments or its history. Everything shown is SpaceController's
// (`Spaces`) and everything done is its actions; which step shows is the only
// thing kept here, because the controller always has a page selected, opened
// by the user or not.
Item {
    id: screen

    property string view: "spaces"
    // A page the user asked for here is on its way (new or imported): it opens
    // when the controller selects it.
    property bool pageExpected: false
    // A page written from a thread, opened when it arrives and no other.
    property string awaitedPageId: ""
    property string openedSpaceId: ""
    property string openedPageId: ""
    // The step this screen was on before a layout change made it again.
    property var resumeStep: null
    readonly property var step: ({ view: view, spaceId: openedSpaceId, pageId: openedPageId })
    // What the controller already holds when the screen loads is no arrival:
    // the bindings report it as a change while the screen is being made.
    property bool settled: false
    readonly property string spaceId: Spaces.spaceId
    readonly property string pageId: Spaces.pageId
    readonly property string error: (Shell.state.space ?? {}).error ?? ""
    readonly property bool readingVersion: Spaces.history.reading
    // Signing an address for every image lasts only as long as they are on screen.
    readonly property bool browsingImages: view === "images" && visible

    signal backRequested
    // The awaited page opened.
    signal pageArrived
    // The user picked another Space, so the page written from a thread no longer opens.
    signal awaitDropped
    // The user moved to `step`, for the shell to hand back as `resumeStep`.
    signal stepMoved(var step)

    // One step back within the screen; false at its first step.
    function stepBack() {
        forceActiveFocus();
        if (view === "version") {
            Shell.dispatch("space.history.back", {});
            view = "history";
        } else if (view === "comments" || view === "history")
            view = "page";
        else if (view === "page")
            view = "pages";
        else if (view === "images")
            view = "pages";
        else if (view === "pages")
            view = "spaces";
        else
            return false;
        return true;
    }

    function openSpace(id) {
        if (id !== spaceId) {
            pageExpected = false;
            awaitDropped();
        }
        openedSpaceId = id;
        Shell.dispatch("space.select", { spaceId: id });
        view = "pages";
    }

    function openPage(id) {
        forceActiveFocus();
        openedSpaceId = Spaces.spaceId;
        openedPageId = id;
        Shell.dispatch("space.selectPage", { pageId: id });
        view = "page";
    }

    function showImages() {
        forceActiveFocus();
        view = "images";
    }

    function askImageFile() {
        imageFile.open();
    }

    function askGenerateImage() {
        generate.open();
    }

    function imageMenu(id) {
        sheet.ask([
            { id: "trash", label: qsTr("Move to trash"), icon: "trash", destructive: true }
        ], () => Shell.dispatch("space.image.trash", { imageId: id }));
    }

    function imageTrashMenu(id) {
        sheet.ask([
            { id: "restore", label: qsTr("Restore"), icon: "archive-restore" },
            { id: "delete", label: qsTr("Delete for good"), icon: "trash", destructive: true }
        ], choice => Shell.dispatch(choice === "restore" ? "space.image.restore" : "space.image.delete", { imageId: id }));
    }

    function showComments(blockId) {
        forceActiveFocus();
        view = "comments";
        if (blockId !== "")
            comments.showBlock(blockId);
    }

    // The history of the page `id`, whichever list or screen asked for it.
    function showHistory(id) {
        openPage(id);
        Shell.dispatch("space.history.open", { pageId: id });
        view = "history";
    }

    function readVersion(version) {
        Shell.dispatch("space.history.read", { version: version });
        view = "version";
    }

    function askNewSpace() {
        text.ask({ title: qsTr("New Space"), placeholder: qsTr("Name"), action: qsTr("Create") }, name => Shell.dispatch("space.create", { name: name }));
    }

    function spaceMenu(id, name) {
        sheet.ask([
            { id: "rename", label: qsTr("Rename"), icon: "pencil" },
            { id: "delete", label: qsTr("Delete"), icon: "trash", destructive: true }
        ], choice => {
            if (choice === "delete")
                Shell.dispatch("space.delete", { spaceId: id });
            else
                text.ask({ title: qsTr("Rename Space"), placeholder: qsTr("Name"), text: name, action: qsTr("Rename") }, renamed => Shell.dispatch("space.rename", { spaceId: id, name: renamed }));
        });
    }

    function askNewPage(parentPageId) {
        text.ask({ title: parentPageId === "" ? qsTr("New page") : qsTr("New subpage"), placeholder: qsTr("Title"), action: qsTr("Create") }, title => {
            pageExpected = true;
            Shell.dispatch("space.page.create", { title: title, parentPageId: parentPageId });
        });
    }

    // What an agent should do to the page `id`, which opens to show the agent working.
    // An ask the MC refuses comes back with its words (`words`).
    function askAgent(id, words) {
        text.ask({ title: qsTr("Ask an agent"), placeholder: qsTr("What should it do to this page?"), action: qsTr("Ask"), multiline: true, text: words ?? "" }, request => {
            openPage(id);
            Shell.dispatch("space.agent.ask", { pageId: id, request: request });
        });
    }

    Connections {
        target: Spaces
        function onAgentAskAnswered(pageId, request, taken) {
            if (!taken)
                screen.askAgent(pageId, request);
        }
    }

    function askImport() {
        text.ask({ title: qsTr("Import Markdown"), placeholder: qsTr("Paste Markdown here"), action: qsTr("Import"), multiline: true }, markdown => {
            pageExpected = true;
            Shell.dispatch("space.page.importMarkdown", { markdown: markdown });
        });
    }

    // `site`: the open page's site (SpaceController's `page.site`). Of a page only
    // listed nothing is known, so its site is reached by opening it.
    function pageMenu(id, title, parentPageId, site) {
        const siteRows = site === undefined ? [] : [
            { id: "publish", label: (site.url ?? "") === "" ? qsTr("Publish as a site") : qsTr("Publish again"), icon: "globe" },
            { id: "publishTailscale", label: qsTr("Publish over Tailscale"), icon: "globe" }
        ].concat((site.url ?? "") === "" ? [] : [
            { id: "copySite", label: qsTr("Copy site link"), icon: "copy" },
            { id: "unpublish", label: qsTr("Unpublish"), icon: "circle-x" }
        ]);
        sheet.ask(siteRows.concat([
            { id: "rename", label: qsTr("Rename"), icon: "pencil" },
            { id: "subpage", label: qsTr("New subpage"), icon: "plus" },
            { id: "agent", label: qsTr("Ask an agent…"), icon: "sparkles" },
            { id: "into", label: qsTr("Move into…"), icon: "folder" },
            { id: "top", label: qsTr("Move to the top"), icon: "arrow-up", enabled: parentPageId !== "" },
            { id: "copy", label: qsTr("Copy as Markdown"), icon: "copy" },
            { id: "history", label: qsTr("History"), icon: "clock" },
            { id: "trash", label: qsTr("Move to trash"), icon: "trash", destructive: true }
        ]), choice => {
            if (choice === "publish") {
                Shell.dispatch("space.page.publish", { pageId: id });
            } else if (choice === "publishTailscale") {
                Shell.dispatch("space.page.publish", { pageId: id, tailscale: true });
            } else if (choice === "copySite") {
                Shell.dispatch("space.page.copySiteLink", { pageId: id });
            } else if (choice === "unpublish") {
                Shell.dispatch("space.page.unpublish", { pageId: id });
            } else if (choice === "rename") {
                text.ask({ title: qsTr("Rename page"), placeholder: qsTr("Title"), text: title, action: qsTr("Rename") }, renamed => Shell.dispatch("space.page.rename", { pageId: id, title: renamed }));
            } else if (choice === "subpage") {
                askNewPage(id);
            } else if (choice === "agent") {
                askAgent(id);
            } else if (choice === "into") {
                pickParent(id);
            } else if (choice === "top") {
                Shell.dispatch("space.page.move", { pageId: id, parentPageId: "" });
            } else if (choice === "copy") {
                Shell.dispatch("space.page.copyMarkdown", { pageId: id });
            } else if (choice === "history") {
                showHistory(id);
            } else {
                Shell.dispatch("space.page.trash", { pageId: id });
                view = "pages";
            }
        });
    }

    // The pages `id` can go inside: all but itself and what is inside it.
    function pickParent(id) {
        const rows = [];
        let within = -1;
        for (let row = 0; row < Spaces.pages.count; ++row) {
            const page = Spaces.pages.get(row);
            if (within >= 0 && page.depth > within)
                continue;
            within = -1;
            if (page.id === id)
                within = page.depth;
            else
                rows.push({ id: page.id, label: page.title, icon: "file-text" });
        }
        if (rows.length === 0)
            rows.push({ id: "", label: qsTr("No other pages"), enabled: false });
        sheet.ask(rows, parent => Shell.dispatch("space.page.move", { pageId: id, parentPageId: parent }));
    }

    function trashMenu(id) {
        sheet.ask([
            { id: "restore", label: qsTr("Restore"), icon: "archive-restore" },
            { id: "history", label: qsTr("History"), icon: "clock" },
            { id: "delete", label: qsTr("Delete for good"), icon: "trash", destructive: true }
        ], choice => {
            if (choice === "history")
                showHistory(id);
            else
                Shell.dispatch(choice === "restore" ? "space.page.restore" : "space.page.delete", { pageId: id });
        });
    }

    // The block menu: `afterBlockId` is where a new block goes (undefined: last).
    function addBlockMenu(afterBlockId) {
        sheet.ask([
            { id: "paragraph", label: qsTr("Text"), icon: "text-wrap" },
            { id: "heading", label: qsTr("Heading"), icon: "hash" },
            { id: "checklist", label: qsTr("Checklist"), icon: "square-check" },
            { id: "callout", label: qsTr("Callout"), icon: "info" },
            { id: "subpage_link", label: qsTr("Subpage link"), icon: "link" },
            { id: "image", label: qsTr("Image"), icon: "image" }
        ], kind => {
            if (kind === "subpage_link")
                pickLink(afterBlockId);
            else if (kind === "image")
                pickImage(afterBlockId);
            else
                text.ask({ title: qsTr("New block"), placeholder: qsTr("Write something"), action: qsTr("Add"), multiline: kind === "paragraph" || kind === "callout" }, written => insert({ kind: kind, text: written }, afterBlockId));
        });
    }

    // The open page's own subpages, which a link block can point to.
    function pickLink(afterBlockId) {
        const rows = [];
        for (let row = 0; row < Spaces.pages.count; ++row) {
            const page = Spaces.pages.get(row);
            if (page.parentPageId === Spaces.pageId)
                rows.push({ id: page.id, label: page.title, icon: "file-text" });
        }
        if (rows.length === 0)
            rows.push({ id: "", label: qsTr("No subpages yet"), enabled: false });
        sheet.ask(rows, linked => insert({ kind: "subpage_link", text: rows.find(row => row.id === linked).label, linkedPageId: linked }, afterBlockId));
    }

    // The Space's images, which an image block can show, and the way to get more.
    function pickImage(afterBlockId) {
        const rows = [];
        for (let row = 0; row < Spaces.images.count; ++row) {
            const image = Spaces.images.get(row);
            rows.push({ id: image.id, label: image.name, icon: "image" });
        }
        if (rows.length === 0)
            rows.push({ id: "", label: qsTr("No images yet"), enabled: false });
        rows.push({ id: "browse", label: qsTr("Add or generate images…"), icon: "plus" });
        sheet.ask(rows, chosen => {
            if (chosen === "browse")
                showImages();
            else
                insert({ kind: "image", text: rows.find(row => row.id === chosen).label, imageId: chosen }, afterBlockId);
        });
    }

    function insert(block, afterBlockId) {
        const payload = Object.assign({ pageId: Spaces.pageId, checked: false }, block);
        if (afterBlockId !== undefined)
            payload.afterBlockId = afterBlockId;
        Shell.dispatch("space.block.insert", payload);
    }

    function blockMenu(row, id, said) {
        const blockAt = at => Spaces.blocks.get(at).id;
        sheet.ask([
            { id: "up", label: qsTr("Move up"), icon: "arrow-up", enabled: row > 0 },
            { id: "down", label: qsTr("Move down"), icon: "arrow-down", enabled: row < Spaces.blocks.count - 1 },
            { id: "below", label: qsTr("Add a block below"), icon: "plus" },
            { id: "comment", label: qsTr("Comment"), icon: "message-square-plus" },
            { id: "delete", label: qsTr("Delete"), icon: "trash", destructive: true }
        ], choice => {
            if (choice === "up")
                Shell.dispatch("space.block.move", { blockId: id, afterBlockId: row > 1 ? blockAt(row - 2) : "" });
            else if (choice === "down")
                Shell.dispatch("space.block.move", { blockId: id, afterBlockId: blockAt(row + 1) });
            else if (choice === "below")
                addBlockMenu(id);
            else if (choice === "comment")
                askComment(id);
            else
                Shell.dispatch("space.block.delete", { blockId: id });
        });
    }

    // For a picker the user leaves without choosing.
    function closeSheet() {
        sheet.close();
    }

    function askComment(blockId) {
        const add = { pageId: Spaces.pageId };
        if (blockId !== "")
            add.blockId = blockId;
        text.ask({ title: qsTr("New comment"), placeholder: qsTr("Comment"), action: qsTr("Comment"), multiline: true }, body => Shell.dispatch("space.comment.add", Object.assign({ body: body }, add)));
    }

    // Back on the step, or as near as what the controller now has selected allows.
    function resume() {
        if (resumeStep === null || resumeStep.view === "spaces" || resumeStep.spaceId !== spaceId)
            return;
        openedSpaceId = resumeStep.spaceId;
        openedPageId = resumeStep.pageId;
        const wanted = resumeStep.view === "pages" || resumeStep.view === "images" || resumeStep.pageId === pageId ? resumeStep.view : "pages";
        // The controller may have closed what the step was showing.
        if (wanted === "version" && !readingVersion)
            view = Spaces.history.shown ? "history" : "page";
        else if (wanted === "history" && !Spaces.history.shown)
            view = "page";
        else
            view = wanted;
    }

    function openArrived() {
        openedSpaceId = spaceId;
        openedPageId = pageId;
        view = "page";
        if (pageId === awaitedPageId)
            pageArrived();
    }

    onPageIdChanged: {
        if (!settled)
            return;
        if (pageId !== "" && (pageExpected || pageId === awaitedPageId)) {
            pageExpected = false;
            openArrived();
        } else if (["page", "comments", "history", "version"].includes(view) && pageId !== openedPageId) {
            // The page went (another client deleted it): not some other page in its place.
            view = "pages";
        }
    }
    onSpaceIdChanged: {
        if (settled && !pageExpected && awaitedPageId === "" && view !== "spaces" && spaceId !== openedSpaceId)
            view = "spaces";
    }
    // Every way out of the history closes it, so nothing keeps asking the MC for it.
    onViewChanged: {
        if (view !== "history" && view !== "version" && Spaces.history.shown)
            Shell.dispatch("space.history.close", {});
    }
    // A restore landed, or the controller stopped reading: back to the versions.
    onReadingVersionChanged: {
        if (!readingVersion && view === "version")
            view = "history";
    }
    onStepChanged: {
        if (settled)
            stepMoved(step);
    }
    onErrorChanged: {
        if (error !== "")
            pageExpected = false;
    }
    onBrowsingImagesChanged: Shell.dispatch("space.images.show", { shown: browsingImages })
    Component.onDestruction: {
        if (browsingImages)
            Shell.dispatch("space.images.show", { shown: false });
    }

    Component.onCompleted: {
        resume();
        settled = true;
        // Selected before the screen was made.
        if (pageId !== "" && pageId === awaitedPageId)
            openArrived();
    }

    objectName: "spaceScreen"

    ColumnLayout {
        objectName: "spaceList"
        anchors.fill: parent
        visible: screen.view === "spaces"
        spacing: 0

        MobileBar {
            Layout.fillWidth: true
            title: qsTr("Spaces")
            canGoBack: true
            onBackRequested: screen.backRequested()

            MobileIconButton {
                objectName: "spaceNew"
                iconName: "plus"
                label: qsTr("New Space")
                onClicked: screen.askNewSpace()
            }
        }

        ListView {
            objectName: "spaceRows"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: Spaces.spaces

            delegate: SpaceListRow {
                required property var model

                objectName: "spaceRow:" + title
                width: ListView.view.width
                title: model.name
                iconName: "book"
                menuName: "spaceMenu:" + model.name
                onClicked: screen.openSpace(model.id)
                onMenuRequested: screen.spaceMenu(model.id, model.name)
            }

            footer: Label {
                objectName: "spaceListEmpty"
                width: ListView.view.width
                padding: 24
                visible: Spaces.spaces.count === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(14 * Theme.fontScale)
                text: {
                    if (Spaces.status === "unreachable")
                        return qsTr("The MC cannot be reached, so its Spaces cannot be shown.");
                    if (Spaces.status === "loading")
                        return qsTr("Loading the Spaces…");
                    return qsTr("There are no Spaces. Make one to start writing pages.");
                }
            }
        }
    }

    SpacePagesView {
        anchors.fill: parent
        visible: screen.view === "pages"
        screen: screen
    }

    SpaceImagesView {
        anchors.fill: parent
        visible: screen.view === "images"
        screen: screen
    }

    SpacePageView {
        anchors.fill: parent
        visible: screen.view === "page"
        screen: screen
    }

    SpaceCommentsView {
        id: comments

        anchors.fill: parent
        visible: screen.view === "comments"
        screen: screen
    }

    SpaceHistoryView {
        anchors.fill: parent
        visible: screen.view === "history"
        screen: screen
    }

    SpaceVersionScreen {
        anchors.fill: parent
        visible: screen.view === "version"
        screen: screen
    }

    SpaceSheet {
        id: sheet
    }

    SpaceTextDialog {
        id: text
    }

    SpaceImageDialog {
        id: generate
    }

    // On Android the system's picker answers with a content address.
    FileDialog {
        id: imageFile

        title: qsTr("Add an image to the Space")
        fileMode: FileDialog.OpenFile
        nameFilters: [qsTr("Images (*.png *.jpg *.jpeg *.gif *.webp)"), qsTr("All files (*)")]
        onAccepted: Shell.dispatch("space.image.addFile", { url: selectedFile.toString() })
    }
}
