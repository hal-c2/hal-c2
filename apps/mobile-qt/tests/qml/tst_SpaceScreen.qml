import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml/HalC2/Mobile"
import HalC2.Shell

// What SpaceScreen decides by itself, which step shows and what its menus ask
// of the controller, over the fake `Spaces`. The whole way through the real
// controller is the feature steps' (features/SpaceSteps.cpp).
Item {
    id: root

    width: 390
    height: 800

    Component {
        id: screenComponent

        SpaceScreen {
            anchors.fill: parent
        }
    }

    function pageRow(id, title, depth, parentPageId) {
        return { id: id, title: title, depth: depth ?? 0, parentPageId: parentPageId ?? "", hasChildren: false, fromThread: false };
    }

    function block(id, text, more) {
        return Object.assign({ id: id, kind: "paragraph", text: text, checked: false, linkedPageId: "", linkedTitle: "", byAgent: false, openComments: 0, imageId: "", imageState: "", imageUrl: "", imageWidth: 0, imageHeight: 0 }, more ?? {});
    }

    function pageOf(id, more) {
        return Object.assign({ id: id, title: id, parentPageId: "", trashed: false, sourceThreadId: "", sourceThreadTitle: "" }, more ?? {});
    }

    TestCase {
        id: test

        name: "SpaceScreen"
        when: windowShown

        function init() {
            Shell.reset();
            Spaces.reset();
        }

        function makeScreen(state, properties) {
            Spaces.load(Object.assign({
                spaceId: "s1",
                spaceName: "Research",
                spaces: [{ id: "s1", name: "Research" }, { id: "s2", name: "Lab" }],
                pages: [root.pageRow("p1", "Roadmap"), root.pageRow("p2", "Q3", 1, "p1"), root.pageRow("p3", "Q4", 2, "p2"), root.pageRow("p4", "Ideas")],
                page: root.pageOf("p1")
            }, state ?? {}));
            return test.createTemporaryObject(screenComponent, root, properties ?? {});
        }

        function dispatched(action) {
            return Shell.dispatchedActions.filter(entry => entry.action === action).map(entry => entry.payload);
        }

        function sheetOf(screen) {
            return findChild(screen, "spaceSheet");
        }

        function dialogOf(screen) {
            return findChild(screen, "spaceTextDialog");
        }

        function publishSpace(space) {
            Shell.state = Object.assign({}, Shell.state, { space: space });
        }

        function test_theSelectedPageStaysClosedUntilTheUserOpensIt() {
            const screen = makeScreen();
            compare(screen.view, "spaces");
            screen.openSpace("s1");
            compare(dispatched("space.select")[0].spaceId, "s1");
            compare(screen.view, "pages");
            screen.openPage("p1");
            compare(screen.view, "page");
        }

        function sheetIds(screen) {
            return sheetOf(screen).rows.map(row => row.id);
        }

        function test_theOpenPageOffersPublishingAndAListedOneDoesNot() {
            const screen = makeScreen();
            screen.pageMenu("p1", "Roadmap", "");
            verify(!sheetIds(screen).includes("publish"));
            sheetOf(screen).close();
            screen.pageMenu("p1", "Roadmap", "", {});
            verify(sheetIds(screen).includes("publish"));
            verify(sheetIds(screen).includes("publishTailscale"));
            verify(!sheetIds(screen).includes("unpublish"));
            verify(!sheetIds(screen).includes("copySite"));
        }

        function test_aPublishedPageShowsItsLinkAndTheWaysOnAndBack() {
            const site = { url: "http://192.168.1.20:3773/sites/s1/token", localOnly: false, behind: false, publishedAt: "" };
            const screen = makeScreen({ page: root.pageOf("p1", { site: site }) });
            screen.openSpace("s1");
            screen.openPage("p1");
            const notice = findChild(screen, "spaceSiteNotice");
            verify(notice !== null);
            verify(notice.visible);
            compare(findChild(screen, "spaceSiteLink").text, site.url);
            verify(!findChild(screen, "spaceSiteLocalOnly").visible);
            verify(!findChild(screen, "spaceSiteTailscale").visible);
            mouseClick(findChild(screen, "spaceSiteCopy"));
            mouseClick(findChild(screen, "spaceSiteRepublish"));
            mouseClick(findChild(screen, "spaceSiteUnpublish"));
            compare(Shell.dispatchedActions.filter(entry => entry.action.startsWith("space.page.")).map(entry => entry.action),
                    ["space.page.copySiteLink", "space.page.publish", "space.page.unpublish"]);
            screen.pageMenu("p1", "Roadmap", "", site);
            verify(sheetIds(screen).includes("copySite"));
            verify(sheetIds(screen).includes("unpublish"));
        }

        function test_theSiteNoticeSaysWhenItIsBehindOrOnlyForThisMachine() {
            const site = { url: "http://127.0.0.1:3773/sites/s1/token", localOnly: true, behind: false, publishedAt: "" };
            const screen = makeScreen({ page: root.pageOf("p1", { site: site }) });
            screen.openSpace("s1");
            screen.openPage("p1");
            const upToDate = findChild(screen, "spaceSiteStatus").text;
            verify(findChild(screen, "spaceSiteLocalOnly").visible);
            const tailscale = findChild(screen, "spaceSiteTailscale");
            // The row it wraps into is laid out on the next polish.
            waitForItemPolished(tailscale.parent);
            mouseClick(tailscale);
            compare(dispatched("space.page.publish"), [{ pageId: "p1", tailscale: true }]);
            Spaces.page = root.pageOf("p1", { site: Object.assign({}, site, { behind: true }) });
            verify(findChild(screen, "spaceSiteStatus").text !== upToDate);
        }

        function test_anUnpublishedPageShowsNoSite() {
            const screen = makeScreen();
            screen.openSpace("s1");
            screen.openPage("p1");
            const notice = findChild(screen, "spaceSiteNotice");
            verify(notice === null || !notice.visible);
        }

        function test_backTakesOneStepAtATimeThenLeaves() {
            const screen = makeScreen();
            screen.openSpace("s1");
            screen.openPage("p1");
            screen.showComments("");
            compare(screen.view, "comments");
            verify(screen.stepBack());
            compare(screen.view, "page");
            verify(screen.stepBack());
            compare(screen.view, "pages");
            verify(screen.stepBack());
            compare(screen.view, "spaces");
            verify(!screen.stepBack());
        }

        function test_theImagesAreOneStepFromThePagesAndSignedOnlyWhileOpen() {
            const screen = makeScreen();
            screen.openSpace("s1");
            screen.showImages();
            compare(screen.view, "images");
            compare(dispatched("space.images.show")[0].shown, true);
            verify(screen.stepBack());
            compare(screen.view, "pages");
            compare(dispatched("space.images.show")[1].shown, false);
        }

        function test_aPageOffersTheSpacesImagesAndTheWayToGetMore() {
            const screen = makeScreen({ images: [{ id: "i1", name: "cat.png", prompt: "", url: "" }] });
            screen.openSpace("s1");
            screen.openPage("p1");
            screen.pickImage(undefined);
            const rows = sheetOf(screen).rows;
            compare(rows.map(row => row.id), ["i1", "browse"]);
            sheetOf(screen).choose("i1");
            const inserted = dispatched("space.block.insert")[0];
            compare(inserted.kind, "image");
            compare(inserted.imageId, "i1");
            compare(inserted.text, "cat.png");
            screen.pickImage(undefined);
            sheetOf(screen).choose("browse");
            compare(screen.view, "images");
        }

        function test_thePlaceholderShowsOnlyWhenThereIsNoPicture() {
            const pixel = ";base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==";
            const screen = makeScreen({ images: [{ id: "i1", name: "cat.png", prompt: "", url: "" }] });
            screen.openSpace("s1");
            screen.showImages();
            waitForRendering(screen);
            const row = findChild(screen, "spaceImage:cat.png");
            const thumbnail = findChild(row, "spaceImageThumbnail");
            const placeholder = findChild(row, "spaceImagePlaceholder");
            compare(placeholder.visible, true);

            // Each address is a new one to the image cache, so each one is fetched.
            const address = name => "data:image/png;name=" + name + pixel;
            Spaces.images.setProperty(0, "url", address("first"));
            compare(thumbnail.status, Image.Loading);
            compare(placeholder.visible, true);
            tryCompare(thumbnail, "status", Image.Ready);
            compare(placeholder.visible, false);

            Spaces.images.setProperty(0, "url", address("renewed"));
            compare(thumbnail.status, Image.Loading);
            compare(placeholder.visible, false);
            tryCompare(thumbnail, "status", Image.Ready);
            compare(placeholder.visible, false);

            ignoreWarning(new RegExp("Error decoding: data:image/png;name=refused"));
            Spaces.images.setProperty(0, "url", "data:image/png;name=refused;base64,AAAA");
            tryCompare(thumbnail, "status", Image.Error);
            compare(placeholder.visible, true);

            // A failed load leaves nothing on screen, so the next address has no picture to keep.
            Spaces.images.setProperty(0, "url", address("after-refusal"));
            compare(thumbnail.status, Image.Loading);
            compare(placeholder.visible, true);
            tryCompare(thumbnail, "status", Image.Ready);
            compare(placeholder.visible, false);

            // Nor does an address taken away.
            Spaces.images.setProperty(0, "url", "");
            compare(thumbnail.status, Image.Null);
            compare(placeholder.visible, true);
            Spaces.images.setProperty(0, "url", address("after-none"));
            compare(thumbnail.status, Image.Loading);
            compare(placeholder.visible, true);
            tryCompare(thumbnail, "status", Image.Ready);
            compare(placeholder.visible, false);

            // A new tile can find its address already in the image cache.
            Spaces.images.append({ id: "i2", name: "dog.png", prompt: "", url: address("after-none") });
            waitForRendering(screen);
            const cached = findChild(screen, "spaceImage:dog.png");
            tryCompare(findChild(cached, "spaceImageThumbnail"), "status", Image.Ready);
            compare(findChild(cached, "spaceImagePlaceholder").visible, false);
        }

        function test_anImageInTheTrashComesBackOrGoesForGood() {
            const screen = makeScreen();
            screen.imageMenu("i1");
            sheetOf(screen).choose("trash");
            compare(dispatched("space.image.trash")[0].imageId, "i1");
            screen.imageTrashMenu("i1");
            sheetOf(screen).choose("restore");
            compare(dispatched("space.image.restore")[0].imageId, "i1");
            screen.imageTrashMenu("i1");
            sheetOf(screen).choose("delete");
            compare(dispatched("space.image.delete")[0].imageId, "i1");
        }

        function test_aNewPageOpensWhenItArrives() {
            const screen = makeScreen();
            screen.openSpace("s1");
            screen.askNewPage("p1");
            dialogOf(screen).then("Q5");
            compare(dispatched("space.page.create")[0].parentPageId, "p1");
            compare(screen.view, "pages");
            Spaces.pageId = "p9";
            compare(screen.view, "page");
            compare(screen.openedPageId, "p9");
        }

        function test_aRefusalLeavesTheUserWhereTheyWere() {
            const screen = makeScreen();
            screen.openSpace("s1");
            screen.askNewPage("");
            dialogOf(screen).then("Q5");
            publishSpace({ error: "No." });
            Spaces.pageId = "p4";
            compare(screen.view, "pages");
        }

        function test_aPageWrittenFromAThreadOpensWhenItArrives() {
            const screen = makeScreen({}, { awaitedPageId: "p9" });
            const arrived = createTemporaryQmlObject("import QtTest; SignalSpy { signalName: \"pageArrived\" }", screen);
            arrived.target = screen;
            // Its Space comes first, and is no reason to fall back to the list.
            Spaces.spaceId = "s2";
            compare(screen.view, "spaces");
            Spaces.pageId = "p9";
            compare(screen.view, "page");
            compare(arrived.count, 1);
        }

        function test_onlyThePageWrittenFromAThreadOpensByItself() {
            const screen = makeScreen({}, { awaitedPageId: "p9" });
            const arrived = createTemporaryQmlObject("import QtTest; SignalSpy { signalName: \"pageArrived\" }", screen);
            arrived.target = screen;
            // The user looks at another Space meanwhile, and its first page is selected.
            screen.openSpace("s1");
            Spaces.pageId = "p4";
            compare(screen.view, "pages");
            compare(arrived.count, 0);
            Spaces.spaceId = "s2";
            Spaces.pageId = "p9";
            compare(screen.view, "page");
            compare(screen.openedPageId, "p9");
            compare(arrived.count, 1);
        }

        function test_pickingAnotherSpaceStopsWaitingForTheWrittenPage() {
            const screen = makeScreen({ spaceId: "s2" }, { awaitedPageId: "p9" });
            const dropped = createTemporaryQmlObject("import QtTest; SignalSpy { signalName: \"awaitDropped\" }", screen);
            dropped.target = screen;
            // Its own Space keeps the wait: the controller still selects the page.
            screen.openSpace("s2");
            compare(dropped.count, 0);
            screen.openSpace("s1");
            compare(dropped.count, 1);
        }

        function test_pickingAnotherSpaceStopsWaitingForTheNewPage() {
            const screen = makeScreen();
            screen.openSpace("s1");
            screen.pageExpected = true;
            screen.openSpace("s2");
            Spaces.spaceId = "s2";
            Spaces.pageId = "p9";
            compare(screen.view, "pages");
        }

        function test_aScreenMadeAgainIsBackOnItsStep() {
            const first = makeScreen();
            const moved = createTemporaryQmlObject("import QtTest; SignalSpy { signalName: \"stepMoved\" }", first);
            moved.target = first;
            first.openSpace("s1");
            first.openPage("p1");
            first.showComments("");
            compare(moved.signalArguments[moved.count - 1][0].view, "comments");
            const screen = makeScreen({}, { resumeStep: first.step });
            compare(screen.view, "comments");
            compare(screen.openedPageId, "p1");
            verify(screen.stepBack());
            compare(screen.view, "page");
        }

        function test_aStepWhoseSelectionWentResumesAsNearAsItCan() {
            const step = { view: "page", spaceId: "s1", pageId: "p1" };
            compare(makeScreen({ page: root.pageOf("p4") }, { resumeStep: step }).view, "pages");
            compare(makeScreen({ spaceId: "s2" }, { resumeStep: step }).view, "spaces");
        }

        function test_aWrittenPageSelectedBeforeTheScreenOpens() {
            const screen = makeScreen({ spaceId: "s2", page: root.pageOf("p9") }, { awaitedPageId: "p9" });
            compare(screen.view, "page");
            compare(screen.openedPageId, "p9");
        }

        function test_aPageThatGoesAwayIsNotReplacedByAnother() {
            const screen = makeScreen();
            screen.openSpace("s1");
            screen.openPage("p1");
            Spaces.pageId = "p4";
            compare(screen.view, "pages");
        }

        function test_aSpaceThatGoesAwayLeadsBackToTheList() {
            const screen = makeScreen();
            screen.openSpace("s1");
            Spaces.spaceId = "s2";
            compare(screen.view, "spaces");
        }

        function test_aBlockMovesToTheSlotOneRowAway_data() {
            return [
                { tag: "up to the top", row: 1, choice: "up", after: "" },
                { tag: "up", row: 2, choice: "up", after: "b1" },
                { tag: "down", row: 0, choice: "down", after: "b2" }
            ];
        }

        function test_aBlockMovesToTheSlotOneRowAway(data) {
            const screen = makeScreen({ blocks: [root.block("b1", "One"), root.block("b2", "Two"), root.block("b3", "Three")] });
            const ids = ["b1", "b2", "b3"];
            screen.blockMenu(data.row, ids[data.row], "");
            sheetOf(screen).choose(data.choice);
            const move = dispatched("space.block.move")[0];
            compare(move.blockId, ids[data.row]);
            compare(move.afterBlockId, data.after);
        }

        function test_aBlockCannotMovePastTheEnds() {
            const screen = makeScreen({ blocks: [root.block("b1", "One"), root.block("b2", "Two")] });
            const enabled = id => sheetOf(screen).rows.find(row => row.id === id).enabled;
            screen.blockMenu(0, "b1", "One");
            compare(enabled("up"), false);
            compare(enabled("down"), true);
            screen.blockMenu(1, "b2", "Two");
            compare(enabled("up"), true);
            compare(enabled("down"), false);
        }

        function test_aPageIsNotOfferedAPlaceInsideItself() {
            const screen = makeScreen();
            screen.pickParent("p1");
            compare(sheetOf(screen).rows.map(row => row.id), ["p4"]);
            screen.pickParent("p2");
            compare(sheetOf(screen).rows.map(row => row.id), ["p1", "p4"]);
        }

        function test_aLinkIsOfferedTheOpenPagesOwnSubpages() {
            const screen = makeScreen();
            screen.pickLink(undefined);
            compare(sheetOf(screen).rows.map(row => row.id), ["p2"]);
            sheetOf(screen).choose("p2");
            const insert = dispatched("space.block.insert")[0];
            compare(insert.kind, "subpage_link");
            compare(insert.linkedPageId, "p2");
            compare(insert.text, "Q3");
            verify(!("afterBlockId" in insert));
        }

        function test_noSubpagesOffersNothingToLink() {
            const screen = makeScreen({ page: root.pageOf("p4") });
            screen.pickLink(undefined);
            compare(sheetOf(screen).rows.length, 1);
            compare(sheetOf(screen).rows[0].enabled, false);
        }

        function test_aPageInTheTrashIsOnlyRead() {
            const screen = makeScreen({ blocks: [root.block("b1", "One")], page: root.pageOf("p1", { trashed: true }) });
            screen.openSpace("s1");
            screen.openPage("p1");
            waitForRendering(screen);
            verify(findChild(screen, "spaceTrashedNotice").visible);
            verify(!findChild(screen, "spaceAddBlock").visible);
            verify(findChild(screen, "spaceBlockEditor:One").readOnly);
            verify(!findChild(screen, "spaceBlockMenu:One").visible);
        }

        function test_aCommentOnAPageInTheTrashCannotBeResolved() {
            const comment = { id: "c1", blockText: "", body: "Note", resolved: false, byAgent: false };
            const screen = makeScreen({ comments: [comment], page: root.pageOf("p1", { trashed: true }) });
            screen.openSpace("s1");
            screen.openPage("p1");
            screen.showComments("");
            waitForRendering(screen);
            verify(!findChild(screen, "spaceCommentResolve:Note").visible);
        }

        function test_whatWasWrittenGoesToTheMcWhenTheEditorLosesFocus() {
            const screen = makeScreen({ blocks: [root.block("b1", "Draft")] });
            screen.openSpace("s1");
            screen.openPage("p1");
            waitForRendering(screen);
            const editor = findChild(screen, "spaceBlockEditor:Draft");
            editor.forceActiveFocus();
            verify(findChild(screen, "spaceEditDone").visible);
            editor.text = "Final";
            screen.stepBack();
            const update = dispatched("space.block.update")[0];
            compare(update.blockId, "b1");
            compare(update.text, "Final");
        }

        function test_whatWasWrittenIsNotLostWithTheScreen() {
            const screen = makeScreen({ blocks: [root.block("b1", "Draft")] });
            screen.openSpace("s1");
            screen.openPage("p1");
            waitForRendering(screen);
            const editor = findChild(screen, "spaceBlockEditor:Draft");
            editor.forceActiveFocus();
            editor.text = "Final";
            screen.destroy();
            tryCompare(Shell, "dispatchCount", 3);
            compare(dispatched("space.block.update")[0].text, "Final");
        }

        function chartBlock() {
            return root.block("c1", "Signups (a chart; Numbers from this page)", {
                kind: "chart",
                chart: { type: "bar", title: "Signups", labels: ["May", "June"], series: [{ name: "Signups", values: [3, 5] }], request: "signups", source: "Numbers from this page" }
            });
        }

        function openChart(row = chartBlock()) {
            const screen = makeScreen({ blocks: [row] });
            screen.openSpace("s1");
            screen.openPage("p1");
            waitForRendering(screen);
            return screen;
        }

        function test_aChartIsDrawnAndNotWrittenIn() {
            const screen = openChart();
            tryVerify(() => findChild(screen, "spaceChart") !== null);
            compare(findChild(screen, "spaceChartTitle").text, "Signups");
            compare(findChild(screen, "spaceChartSource").text, "Numbers from this page");
            verify(!findChild(screen, "spaceBlockEditor:Signups (a chart; Numbers from this page)").visible);
        }

        function test_aChartShowsItsNumbers() {
            const screen = openChart();
            tryVerify(() => findChild(screen, "spaceChartNumbers") !== null);
            mouseClick(findChild(screen, "spaceChartNumbers"));
            tryVerify(() => findChild(screen, "spaceChartCell:May") !== null);
        }

        function test_aChartWhoseNumbersDoNotMatchItsLabelsIsNotDrawn() {
            const row = chartBlock();
            row.chart.series[0].values = [3];
            const screen = openChart(row);
            tryVerify(() => findChild(screen, "spaceChartUnmatched") !== null);
            tryVerify(() => findChild(screen, "spaceChartUnmatched").visible);
            verify(findChild(screen, "spaceChartBar") === null);
        }

        function test_theAddMenuAsksForAChartWhereItWasOpened() {
            const screen = openChart();
            screen.addBlockMenu("c1");
            sheetOf(screen).choose("chart");
            dialogOf(screen).then("weekly turns");
            compare(dispatched("space.block.visualize")[0].request, "weekly turns");
            compare(dispatched("space.block.visualize")[0].afterBlockId, "c1");
        }

        function test_askingAgainOffersTheWordsAndReplacesTheChart() {
            const screen = openChart();
            screen.blockMenu(0, "c1", "", "signups");
            sheetOf(screen).choose("again");
            compare(dialogOf(screen).written, "signups");
            dialogOf(screen).then(dialogOf(screen).written);
            compare(dispatched("space.block.visualize")[0].request, "signups");
            compare(dispatched("space.block.visualize")[0].blockId, "c1");
        }

        function test_onlyAChartIsAskedForAgain() {
            const screen = makeScreen({ blocks: [root.block("b1", "One")] });
            screen.blockMenu(0, "b1", "One");
            verify(!sheetOf(screen).rows.some(row => row.id === "again"));
        }

        function test_aChartBeingDrawnIsShown() {
            const screen = openChart();
            verify(!findChild(screen, "spaceDrawing").visible);
            publishSpace({ drawing: true });
            tryVerify(() => findChild(screen, "spaceDrawing").visible);
        }

        function deckState(more) {
            return Object.assign({
                decks: [{ id: "d1", title: "Pitch" }],
                slides: [{ id: "s1", title: "One", body: "" }, { id: "s2", title: "Two", body: "" }, { id: "s3", title: "Three", body: "" }],
                deck: { id: "d1", title: "Pitch", trashed: false }
            }, more ?? {});
        }

        function test_aNewDeckOpensWhenItArrives() {
            const screen = makeScreen();
            screen.openSpace("s1");
            screen.askNewDeck();
            dialogOf(screen).then("Pitch");
            compare(dispatched("space.deck.create")[0].title, "Pitch");
            compare(screen.view, "pages");
            Spaces.deckId = "d9";
            compare(screen.view, "deck");
            compare(screen.openedDeckId, "d9");
        }

        function test_aDeckMadeFromAPageOpensWhenItArrives() {
            const screen = makeScreen();
            screen.openSpace("s1");
            screen.pageMenu("p1", "Roadmap", "");
            sheetOf(screen).choose("deck");
            compare(dispatched("space.deck.createFromPage")[0].pageId, "p1");
            Spaces.deckId = "d9";
            compare(screen.view, "deck");
        }

        function test_aRefusedDeckLeavesTheUserWhereTheyWere() {
            const screen = makeScreen();
            screen.openSpace("s1");
            screen.askNewDeck();
            dialogOf(screen).then("Pitch");
            publishSpace({ error: "No." });
            Spaces.deckId = "d9";
            compare(screen.view, "pages");
        }

        function test_backLeavesTheDeckForTheListOfPagesAndDecks() {
            const screen = makeScreen(deckState());
            screen.openSpace("s1");
            screen.openDeck("d1");
            compare(dispatched("space.selectDeck")[0].deckId, "d1");
            compare(screen.view, "deck");
            verify(screen.stepBack());
            compare(screen.view, "pages");
        }

        function test_aDeckThatGoesAwayLeadsBackToTheList() {
            const screen = makeScreen(deckState());
            screen.openSpace("s1");
            screen.openDeck("d1");
            Spaces.deckId = "";
            compare(screen.view, "pages");
        }

        function test_backLeavesThePresenterBeforeTheDeck() {
            const screen = makeScreen(deckState());
            screen.openSpace("s1");
            screen.openDeck("d1");
            Spaces.presenting = true;
            verify(screen.stepBack());
            compare(dispatched("space.deck.leave").length, 1);
            compare(screen.view, "deck");
            Spaces.presenting = false;
            verify(screen.stepBack());
            compare(screen.view, "pages");
        }

        function test_aTapOnTheLeftThirdOfThePresenterGoesBack() {
            const screen = makeScreen(deckState({ presenting: true, slide: { id: "s2", title: "Two", body: "" }, slideNumber: 2, slideCount: 3 }));
            const tap = findChild(Overlay.overlay ?? screen, "spacePresenterTap") ?? findChild(screen, "spacePresenterTap");
            tryVerify(() => tap.visible && tap.width > 0);
            mouseClick(tap, tap.width / 6, tap.height / 2);
            compare(dispatched("space.deck.step")[0].by, -1);
            mouseClick(tap, tap.width * 5 / 6, tap.height / 2);
            compare(dispatched("space.deck.step")[1].by, 1);
        }

        function test_aDeckScreenMadeAgainIsBackOnItsStep() {
            const first = makeScreen(deckState());
            first.openSpace("s1");
            first.openDeck("d1");
            const step = first.step;
            compare(makeScreen(deckState(), { resumeStep: step }).view, "deck");
            compare(makeScreen(deckState({ deck: { id: "d2", title: "Other", trashed: false } }), { resumeStep: step }).view, "pages");
        }

        function test_aSlideMovesToTheSlotOneRowAway_data() {
            return [
                { tag: "up to the top", row: 1, choice: "up", after: "" },
                { tag: "up", row: 2, choice: "up", after: "s1" },
                { tag: "down", row: 0, choice: "down", after: "s2" }
            ];
        }

        function test_aSlideMovesToTheSlotOneRowAway(data) {
            const screen = makeScreen(deckState());
            const ids = ["s1", "s2", "s3"];
            screen.slideMenu(data.row, ids[data.row]);
            sheetOf(screen).choose(data.choice);
            const move = dispatched("space.slide.move")[0];
            compare(move.slideId, ids[data.row]);
            compare(move.afterSlideId, data.after);
        }

        function test_aSlideCannotMovePastTheEnds() {
            const screen = makeScreen(deckState());
            const enabled = id => sheetOf(screen).rows.find(row => row.id === id).enabled;
            screen.slideMenu(0, "s1");
            compare(enabled("up"), false);
            screen.slideMenu(2, "s3");
            compare(enabled("down"), false);
        }

        function test_aDeckInTheTrashIsOnlyRead() {
            const screen = makeScreen(deckState({ decks: [], deckTrash: [{ id: "d1", title: "Pitch", trashedAt: "2026-10-01T10:00:00Z" }], deck: { id: "d1", title: "Pitch", trashed: true } }));
            screen.openSpace("s1");
            screen.openDeck("d1");
            tryVerify(() => findChild(screen, "spaceSlideTitle:0") !== null);
            verify(findChild(screen, "spaceDeckTrashedNotice").visible);
            verify(!findChild(screen, "spaceAddSlide").visible);
            verify(!findChild(screen, "spaceDeckPresent").visible);
            verify(findChild(screen, "spaceSlideTitle:0").readOnly);
            verify(!findChild(screen, "spaceSlideMenu:0").visible);
            screen.deckTrashMenu("d1");
            sheetOf(screen).choose("restore");
            compare(dispatched("space.deck.restore")[0].deckId, "d1");
        }

        function test_aSlideBeingWrittenSurvivesPickingADeckInTheTrash_data() {
            return [
                { tag: "title", field: "spaceSlideTitle:0", write: { title: "First" } },
                { tag: "body", field: "spaceSlideBody:0", write: { body: "First" } }
            ];
        }

        function test_aSlideBeingWrittenSurvivesPickingADeckInTheTrash(data) {
            const screen = makeScreen(deckState());
            screen.openSpace("s1");
            screen.openDeck("d1");
            tryVerify(() => findChild(screen, data.field) !== null);
            const editor = findChild(screen, data.field);
            editor.forceActiveFocus();
            editor.text = "First";
            Spaces.load(deckState({
                spaceId: "s1",
                spaceName: "Research",
                decks: [],
                deckTrash: [{ id: "d9", title: "Old", trashedAt: "2026-10-01T10:00:00Z" }],
                deck: { id: "d9", title: "Old", trashed: true },
                slides: [{ id: "s9", title: "Gone", body: "" }]
            }));
            tryVerify(() => dispatched("space.slide.update").length === 1);
            compare(dispatched("space.slide.update")[0], Object.assign({ spaceId: "s1", slideId: "s1" }, data.write));
        }

        function test_aSlideBeingWrittenIsNotLostWithTheScreen() {
            const screen = makeScreen(deckState());
            screen.openSpace("s1");
            screen.openDeck("d1");
            tryVerify(() => findChild(screen, "spaceSlideBody:0") !== null);
            const editor = findChild(screen, "spaceSlideBody:0");
            editor.forceActiveFocus();
            editor.text = "First";
            screen.destroy();
            tryVerify(() => dispatched("space.slide.update").length > 0);
            waitForRendering(root);
            compare(dispatched("space.slide.update"), [{ spaceId: "s1", slideId: "s1", body: "First" }]);
        }

        function test_leavingASlideKeepsAnEditFromAnotherClient_data() {
            return [
                { tag: "title", field: "spaceSlideTitle:0", role: "title" },
                { tag: "body", field: "spaceSlideBody:0", role: "body" }
            ];
        }

        function test_leavingASlideKeepsAnEditFromAnotherClient(data) {
            const screen = makeScreen(deckState());
            screen.openSpace("s1");
            screen.openDeck("d1");
            tryVerify(() => findChild(screen, data.field) !== null);
            const editor = findChild(screen, data.field);
            editor.forceActiveFocus();
            Spaces.slides.setProperty(0, data.role, "Theirs");
            editor.focus = false;
            compare(dispatched("space.slide.update"), []);
            compare(editor.text, "Theirs");
        }

        function test_writingOverAnEditFromAnotherClientIsTheUsersToMake() {
            const screen = makeScreen(deckState());
            screen.openSpace("s1");
            screen.openDeck("d1");
            tryVerify(() => findChild(screen, "spaceSlideTitle:0") !== null);
            const editor = findChild(screen, "spaceSlideTitle:0");
            editor.forceActiveFocus();
            editor.text = "Mine";
            Spaces.slides.setProperty(0, "title", "Theirs");
            editor.focus = false;
            compare(dispatched("space.slide.update"), [{ spaceId: "s1", slideId: "s1", title: "Mine" }]);
        }

        function test_leavingADeckInTheTrashWritesNothing() {
            const screen = makeScreen(deckState({ decks: [], deckTrash: [{ id: "d1", title: "Pitch", trashedAt: "2026-10-01T10:00:00Z" }], deck: { id: "d1", title: "Pitch", trashed: true } }));
            screen.openSpace("s1");
            screen.openDeck("d1");
            tryVerify(() => findChild(screen, "spaceSlideTitle:0") !== null);
            const title = findChild(screen, "spaceSlideTitle:0");
            title.forceActiveFocus();
            title.focus = false;
            screen.destroy();
            waitForRendering(root);
            compare(dispatched("space.slide.update"), []);
        }

        function test_aDeckInTheListOffersPresentingAndTheTrash() {
            const screen = makeScreen(deckState());
            screen.deckMenu("d1", "Pitch");
            sheetOf(screen).choose("present");
            compare(dispatched("space.deck.present")[0].deckId, "d1");
            screen.deckMenu("d1", "Pitch");
            sheetOf(screen).choose("trash");
            compare(dispatched("space.deck.trash")[0].deckId, "d1");
        }

        function test_aRenameAnsweredAfterTheSpaceChangedGoesToItsOwnSpace() {
            const screen = makeScreen(deckState());
            screen.deckMenu("d1", "Pitch");
            sheetOf(screen).choose("rename");
            Spaces.spaceId = "s2";
            dialogOf(screen).then("Renamed");
            const rename = dispatched("space.deck.rename")[0];
            compare(rename.spaceId, "s1");
            compare(rename.deckId, "d1");
            compare(rename.title, "Renamed");
        }

        function test_whatWasWrittenOnASlideGoesToTheMcWhenTheEditorLosesFocus() {
            const screen = makeScreen(deckState());
            screen.openSpace("s1");
            screen.openDeck("d1");
            tryVerify(() => findChild(screen, "spaceSlideBody:1") !== null);
            const editor = findChild(screen, "spaceSlideBody:1");
            editor.forceActiveFocus();
            verify(findChild(screen, "spaceDeckDone").visible);
            editor.text = "More to say";
            screen.stepBack();
            const update = dispatched("space.slide.update")[0];
            compare(update.spaceId, "s1");
            compare(update.slideId, "s2");
            compare(update.body, "More to say");
            verify(!("title" in update));
        }
    }
}
