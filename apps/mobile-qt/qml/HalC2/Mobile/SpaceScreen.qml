pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Dialogs
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The Spaces in the phone layout, one step at a time: the list of Spaces, a
// Space's pages and decks or images, a page, its comments, a deck. Everything shown is SpaceController's
// (`Spaces`) and everything done is its actions; which step shows is the only
// thing kept here, because the controller always has a page selected, opened
// by the user or not.
Item {
    id: screen

    property string view: "spaces"
    // A page the user asked for here is on its way (new or imported): it opens
    // when the controller selects it.
    property bool pageExpected: false
    // The same for a deck the user asked for here.
    property bool deckExpected: false
    // A page written from a thread, opened when it arrives and no other.
    property string awaitedPageId: ""
    property string openedSpaceId: ""
    property string openedPageId: ""
    property string openedDeckId: ""
    // The step this screen was on before a layout change made it again.
    property var resumeStep: null
    readonly property var step: ({ view: view, spaceId: openedSpaceId, pageId: openedPageId, deckId: openedDeckId })
    // The user is on the page only here, not while its Space's list shows.
    readonly property bool pageOnShow: view === "page" || view === "comments"
    // What the controller already holds when the screen loads is no arrival:
    // the bindings report it as a change while the screen is being made.
    property bool settled: false
    readonly property string spaceId: Spaces.spaceId
    readonly property string pageId: Spaces.pageId
    readonly property string deckId: Spaces.deckId
    readonly property string error: (Shell.state.space ?? {}).error ?? ""
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
        if (Spaces.presenting)
            Shell.dispatch("space.deck.leave", {});
        else if (view === "comments")
            view = "page";
        else if (view === "page" || view === "deck")
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
            deckExpected = false;
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

    function askImport() {
        text.ask({ title: qsTr("Import Markdown"), placeholder: qsTr("Paste Markdown here"), action: qsTr("Import"), multiline: true }, markdown => {
            pageExpected = true;
            Shell.dispatch("space.page.importMarkdown", { markdown: markdown });
        });
    }

    // What can be done with the open page's update. Only the open page's is known,
    // so the tree's menus do not offer it.
    function updateRows(id) {
        if (view !== "page" || id !== Spaces.pageId)
            return [];
        const schedule = Spaces.page.schedule ?? {};
        if ((schedule.instruction ?? "") === "")
            return [{ id: "update", label: qsTr("Update itself…"), icon: "clock" }];
        return [
            { id: "update", label: qsTr("Change its update…"), icon: "clock" },
            { id: "updateRun", label: qsTr("Run its update now"), icon: "play", enabled: schedule.lastRunStatus !== "running" },
            { id: "updatePause", label: schedule.enabled === true ? qsTr("Pause its update") : qsTr("Resume its update"), icon: schedule.enabled === true ? "pause" : "play" },
            { id: "updateRemove", label: qsTr("Remove its update"), icon: "x" }
        ];
    }

    // The instruction, then the cadence, each in a control a finger wide. A time
    // the MC cannot read comes back as its refusal.
    function askUpdate() {
        const schedule = Spaces.page.schedule ?? {};
        const given = (schedule.instruction ?? "") !== "";
        text.ask({ title: given ? qsTr("Change this page's update") : qsTr("Have this page update itself"), placeholder: qsTr("Summarise yesterday's threads"), text: schedule.instruction ?? "", action: qsTr("Next"), multiline: true }, instruction => {
            const save = cadence => Shell.dispatch("space.page.schedule.set", { pageId: Spaces.pageId, instruction: instruction, cadence: cadence });
            const hours = [1, 2, 6, 12].map(count => ({ id: "every:" + count, label: count === 1 ? qsTr("Every hour") : qsTr("Every %1 hours").arg(count), icon: "clock" }));
            const keep = given ? [{ id: "keep", label: qsTr("Keep: %1").arg(schedule.cadenceLabel), icon: "check" }] : [];
            sheet.ask(keep.concat(hours, [{ id: "time", label: qsTr("At a time of day…"), icon: "clock" }]), choice => {
                if (choice === "keep")
                    save(schedule.cadence);
                else if (choice === "time")
                    text.ask({ title: qsTr("What time of day?"), placeholder: "09:00", text: schedule.cadence?.timeOfDay ?? "09:00", action: qsTr("Save") }, time => save({ type: "fixed_time", timeOfDay: time, weekdays: schedule.cadence?.weekdays ?? [] }));
                else
                    save({ type: "interval", everyMs: Number(choice.slice("every:".length)) * 3600000 });
            });
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
            { id: "into", label: qsTr("Move into…"), icon: "folder" },
            { id: "top", label: qsTr("Move to the top"), icon: "arrow-up", enabled: parentPageId !== "" },
            { id: "copy", label: qsTr("Copy as Markdown"), icon: "copy" },
            { id: "deck", label: qsTr("Make a deck"), icon: "play" }
        ].concat(updateRows(id), [
            { id: "trash", label: qsTr("Move to trash"), icon: "trash", destructive: true }
        ])), choice => {
            if (choice === "update") {
                askUpdate();
            } else if (choice === "updateRun") {
                Shell.dispatch("space.page.schedule.runNow", { pageId: id });
            } else if (choice === "updatePause") {
                Shell.dispatch("space.page.schedule.setEnabled", { pageId: id, enabled: Spaces.page.schedule?.enabled !== true });
            } else if (choice === "updateRemove") {
                Shell.dispatch("space.page.schedule.remove", { pageId: id });
            } else if (choice === "publish") {
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
            } else if (choice === "into") {
                pickParent(id);
            } else if (choice === "top") {
                Shell.dispatch("space.page.move", { pageId: id, parentPageId: "" });
            } else if (choice === "copy") {
                Shell.dispatch("space.page.copyMarkdown", { pageId: id });
            } else if (choice === "deck") {
                deckExpected = true;
                Shell.dispatch("space.deck.createFromPage", { pageId: id });
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
            { id: "delete", label: qsTr("Delete for good"), icon: "trash", destructive: true }
        ], choice => Shell.dispatch(choice === "restore" ? "space.page.restore" : "space.page.delete", { pageId: id }));
    }

    // The block menu: `afterBlockId` is where a new block goes (undefined: last).
    function addBlockMenu(afterBlockId) {
        sheet.ask([
            { id: "paragraph", label: qsTr("Text"), icon: "text-wrap" },
            { id: "heading", label: qsTr("Heading"), icon: "hash" },
            { id: "checklist", label: qsTr("Checklist"), icon: "square-check" },
            { id: "callout", label: qsTr("Callout"), icon: "info" },
            { id: "subpage_link", label: qsTr("Subpage link"), icon: "link" },
            { id: "chart", label: qsTr("Chart"), icon: "chart-no-axes-column" },
            { id: "image", label: qsTr("Image"), icon: "image" }
        ], kind => {
            if (kind === "subpage_link")
                pickLink(afterBlockId);
            else if (kind === "chart")
                askChart({ afterBlockId: afterBlockId });
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

    // A chart for the page: `where` holds the block it goes after, or the chart
    // it replaces with the words that chart was asked for in.
    function askChart(where, request) {
        text.ask({ title: where.blockId === undefined ? qsTr("New chart") : qsTr("Ask again"), placeholder: qsTr("What should it show?"), text: request ?? "", action: qsTr("Draw") }, asked => {
            const payload = { pageId: Spaces.pageId, request: asked };
            if (where.blockId !== undefined)
                payload.blockId = where.blockId;
            else if (where.afterBlockId !== undefined)
                payload.afterBlockId = where.afterBlockId;
            Shell.dispatch("space.block.visualize", payload);
        });
    }

    function insert(block, afterBlockId) {
        const payload = Object.assign({ pageId: Spaces.pageId, checked: false }, block);
        if (afterBlockId !== undefined)
            payload.afterBlockId = afterBlockId;
        Shell.dispatch("space.block.insert", payload);
    }

    // `chartRequest` is what a chart was asked for with; other blocks have none.
    function blockMenu(row, id, said, chartRequest) {
        const blockAt = at => Spaces.blocks.get(at).id;
        const again = chartRequest === undefined ? [] : [{ id: "again", label: qsTr("Ask again"), icon: "refresh-cw" }];
        sheet.ask(again.concat([
            { id: "up", label: qsTr("Move up"), icon: "arrow-up", enabled: row > 0 },
            { id: "down", label: qsTr("Move down"), icon: "arrow-down", enabled: row < Spaces.blocks.count - 1 },
            { id: "below", label: qsTr("Add a block below"), icon: "plus" },
            { id: "comment", label: qsTr("Comment"), icon: "message-square-plus" },
            { id: "delete", label: qsTr("Delete"), icon: "trash", destructive: true }
        ]), choice => {
            if (choice === "again")
                askChart({ blockId: id }, chartRequest);
            else if (choice === "up")
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

    function openDeck(id) {
        forceActiveFocus();
        openedSpaceId = Spaces.spaceId;
        openedDeckId = id;
        Shell.dispatch("space.selectDeck", { deckId: id });
        view = "deck";
    }

    function askNewDeck() {
        text.ask({ title: qsTr("New deck"), placeholder: qsTr("Title"), action: qsTr("Create") }, title => {
            deckExpected = true;
            Shell.dispatch("space.deck.create", { title: title });
        });
    }

    function present(id) {
        forceActiveFocus();
        Shell.dispatch("space.deck.present", { deckId: id });
    }

    function deckMenu(id, title) {
        sheet.ask([
            { id: "present", label: qsTr("Present"), icon: "play" },
            { id: "rename", label: qsTr("Rename"), icon: "pencil" },
            { id: "trash", label: qsTr("Move to trash"), icon: "trash", destructive: true }
        ], choice => {
            if (choice === "present") {
                present(id);
            } else if (choice === "rename") {
                const space = Spaces.spaceId;
                text.ask({ title: qsTr("Rename deck"), placeholder: qsTr("Title"), text: title, action: qsTr("Rename") }, renamed => Shell.dispatch("space.deck.rename", { spaceId: space, deckId: id, title: renamed }));
            } else {
                Shell.dispatch("space.deck.trash", { deckId: id });
                view = "pages";
            }
        });
    }

    function deckTrashMenu(id) {
        sheet.ask([
            { id: "restore", label: qsTr("Restore"), icon: "archive-restore" },
            { id: "delete", label: qsTr("Delete for good"), icon: "trash", destructive: true }
        ], choice => Shell.dispatch(choice === "restore" ? "space.deck.restore" : "space.deck.delete", { deckId: id }));
    }

    // `afterSlideId` is where the new slide goes (undefined: last).
    function askNewSlide(afterSlideId) {
        text.ask({ title: qsTr("New slide"), placeholder: qsTr("Title"), action: qsTr("Add") }, title => {
            const payload = { deckId: Spaces.deckId, title: title, body: "" };
            if (afterSlideId !== undefined)
                payload.afterSlideId = afterSlideId;
            Shell.dispatch("space.slide.insert", payload);
        });
    }

    function slideMenu(row, id) {
        const slideAt = at => Spaces.slides.get(at).id;
        sheet.ask([
            { id: "up", label: qsTr("Move up"), icon: "arrow-up", enabled: row > 0 },
            { id: "down", label: qsTr("Move down"), icon: "arrow-down", enabled: row < Spaces.slides.count - 1 },
            { id: "below", label: qsTr("Add a slide below"), icon: "plus" },
            { id: "delete", label: qsTr("Delete"), icon: "trash", destructive: true }
        ], choice => {
            if (choice === "up")
                Shell.dispatch("space.slide.move", { slideId: id, afterSlideId: row > 1 ? slideAt(row - 2) : "" });
            else if (choice === "down")
                Shell.dispatch("space.slide.move", { slideId: id, afterSlideId: slideAt(row + 1) });
            else if (choice === "below")
                askNewSlide(id);
            else
                Shell.dispatch("space.slide.delete", { slideId: id });
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
        openedDeckId = resumeStep.deckId ?? "";
        const selected = resumeStep.view === "deck" ? resumeStep.deckId === deckId : resumeStep.pageId === pageId;
        view = resumeStep.view === "pages" || resumeStep.view === "images" || selected ? resumeStep.view : "pages";
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
        } else if ((view === "page" || view === "comments") && pageId !== openedPageId) {
            // The page went (another client deleted it): not some other page in its place.
            view = "pages";
        }
    }
    onDeckIdChanged: {
        if (!settled)
            return;
        if (deckId !== "" && deckExpected) {
            deckExpected = false;
            openedSpaceId = spaceId;
            openedDeckId = deckId;
            view = "deck";
        } else if (view === "deck" && deckId !== openedDeckId) {
            // The deck went (another client deleted it): back to what is left.
            view = "pages";
        }
    }
    onSpaceIdChanged: {
        if (settled && !pageExpected && !deckExpected && awaitedPageId === "" && view !== "spaces" && spaceId !== openedSpaceId)
            view = "spaces";
    }
    onStepChanged: {
        if (settled)
            stepMoved(step);
    }
    onPageOnShowChanged: {
        if (settled)
            Shell.dispatch("space.pageShown", { shown: pageOnShow });
    }
    onErrorChanged: {
        if (error !== "") {
            pageExpected = false;
            deckExpected = false;
        }
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
        Shell.dispatch("space.pageShown", { shown: pageOnShow });
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

    SpaceDeckView {
        anchors.fill: parent
        visible: screen.view === "deck"
        screen: screen
    }

    SpaceCommentsView {
        id: comments

        anchors.fill: parent
        visible: screen.view === "comments"
        screen: screen
    }

    SpaceSheet {
        id: sheet
    }

    SpaceTextDialog {
        id: text
    }

    SpacePresenter {
        anchors.fill: parent
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
