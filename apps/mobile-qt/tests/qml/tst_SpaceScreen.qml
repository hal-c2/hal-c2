import QtQuick
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
            const comment = { id: "c1", blockId: "", blockText: "", blockGone: false, body: "Note", resolved: false, byAgent: false };
            const screen = makeScreen({ comments: [comment], page: root.pageOf("p1", { trashed: true }) });
            screen.openSpace("s1");
            screen.openPage("p1");
            screen.showComments("");
            waitForRendering(screen);
            verify(!findChild(screen, "spaceCommentResolve:Note").visible);
        }

        function version(id, more) {
            return Object.assign({ version: id, at: "2026-10-31T10:00:00Z", byAgent: false, threadTitle: "", restoredFromAt: "" }, more ?? {});
        }

        function openHistory(history, state) {
            const screen = makeScreen(Object.assign({ history: Object.assign({ pageId: "p1", versions: [version(3), version(1)] }, history ?? {}) }, state ?? {}));
            screen.openSpace("s1");
            screen.openPage("p1");
            Spaces.history.shown = true;
            screen.view = "history";
            waitForRendering(screen);
            return screen;
        }

        function test_aPageMenuOpensTheHistoryOnThatPage() {
            const screen = makeScreen();
            screen.openSpace("s1");
            screen.pageMenu("p2", "Q3", "p1");
            sheetOf(screen).choose("history");
            compare(screen.view, "history");
            compare(dispatched("space.selectPage")[0].pageId, "p2");
            compare(dispatched("space.history.open")[0].pageId, "p2");
        }

        function test_theTrashMenuOpensTheHistoryToo() {
            const screen = makeScreen();
            screen.openSpace("s1");
            screen.trashMenu("p9");
            sheetOf(screen).choose("history");
            compare(screen.view, "history");
            compare(dispatched("space.history.open")[0].pageId, "p9");
        }

        function test_theNewestVersionCannotBeRestored() {
            const screen = openHistory();
            verify(!findChild(screen, "spaceHistoryRestore:0").visible);
            verify(findChild(screen, "spaceHistoryRestore:1").visible);
            findChild(screen, "spaceHistoryRestore:1").clicked();
            compare(dispatched("space.history.restore")[0].version, 1);
        }

        function test_aVersionSaysWhoWroteIt() {
            const screen = openHistory({ versions: [version(3, { byAgent: true, threadTitle: "Work" }), version(1)] });
            compare(findChild(screen, "spaceHistoryRow:0").threadTitle, "Work");
            verify(findChild(screen, "spaceHistoryRow:0").byAgent);
            verify(!findChild(screen, "spaceHistoryRow:1").byAgent);
        }

        function test_aTrashedPageOffersNoRestoreAndSaysWhy() {
            const screen = openHistory({}, { page: root.pageOf("p1", { trashed: true }) });
            verify(!findChild(screen, "spaceHistoryRestore:1").visible);
            verify(findChild(screen, "spaceHistoryNote").text.indexOf("trash") >= 0);
        }

        function test_aHistoryThatFailedCanBeAskedForAgain() {
            const screen = openHistory({ versions: [], failed: true });
            verify(findChild(screen, "spaceHistoryRetry").visible);
            findChild(screen, "spaceHistoryRetry").clicked();
            compare(dispatched("space.history.open")[0].pageId, "p1");
        }

        function test_moreVersionsComeOnlyWhenAskedFor() {
            const screen = openHistory({ hasMore: true });
            compare(dispatched("space.history.more").length, 0);
            findChild(screen, "spaceHistoryMore").clicked();
            compare(dispatched("space.history.more").length, 1);
        }

        function test_aVersionIsOnlyRead() {
            const screen = openHistory({ reading: true, version: { version: 1, at: "2026-10-31T10:00:00Z", title: "Roadmap" }, blocks: [root.block("b1", "Draft")] });
            screen.readVersion(1);
            compare(dispatched("space.history.read")[0].version, 1);
            waitForRendering(screen);
            verify(findChild(screen, "spaceVersionRestore").visible);
            const list = findChild(screen, "spaceVersionBlocks");
            verify(list.visible);
            compare(list.count, 1);
            verify(list.itemAtIndex(0).readOnly);
        }

        function test_theNewestVersionOffersNoRestoreWhileRead() {
            const screen = openHistory({ reading: true, version: { version: 3, at: "2026-10-31T10:00:00Z", title: "Roadmap" } });
            screen.readVersion(3);
            verify(!findChild(screen, "spaceVersionRestore").visible);
        }

        function test_backStepsThroughTheVersionsToThePage() {
            const screen = openHistory({ reading: true, version: { version: 1, title: "Roadmap" } });
            screen.readVersion(1);
            verify(screen.stepBack());
            compare(screen.view, "history");
            compare(dispatched("space.history.back").length, 1);
            verify(screen.stepBack());
            compare(screen.view, "page");
            compare(dispatched("space.history.close").length, 1);
        }

        function test_aRestoreReturnsToTheVersions() {
            const screen = openHistory({ reading: true, version: { version: 1, title: "Roadmap" } });
            screen.readVersion(1);
            Spaces.history.reading = false;
            compare(screen.view, "history");
        }

        function test_theHistoryOfAPageThatWentClosesWithIt() {
            const screen = openHistory();
            Spaces.pageId = "p4";
            compare(screen.view, "pages");
            compare(dispatched("space.history.close").length, 1);
        }

        function test_aRebuiltScreenReturnsToTheHistoryIfStillOpen() {
            const shown = makeScreen({ history: { shown: true, pageId: "p1" } }, { resumeStep: { view: "history", spaceId: "s1", pageId: "p1" } });
            compare(shown.view, "history");
            const closed = makeScreen({}, { resumeStep: { view: "version", spaceId: "s1", pageId: "p1" } });
            compare(closed.view, "page");
        }

        function test_aCommentSaysItsBlockIsGone() {
            const screen = makeScreen({ blocks: [root.block("b1", "Draft")], comments: [
                { id: "c1", blockId: "b9", blockText: "", blockGone: true, body: "Why?", resolved: false, byAgent: false, createdAt: "" },
                { id: "c2", blockId: "", blockText: "", blockGone: false, body: "Page", resolved: false, byAgent: false, createdAt: "" },
                { id: "c3", blockId: "b1", blockText: "Draft", blockGone: false, body: "Here", resolved: false, byAgent: false, createdAt: "" }
            ] });
            screen.openSpace("s1");
            screen.openPage("p1");
            screen.showComments("");
            waitForRendering(screen);
            compare(findChild(screen, "spaceCommentBlock:Why?").text, "On a block no longer on this page");
            compare(findChild(screen, "spaceCommentBlock:Page").text, "");
            compare(findChild(screen, "spaceCommentBlock:Here").text, "Draft");
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
    }
}
