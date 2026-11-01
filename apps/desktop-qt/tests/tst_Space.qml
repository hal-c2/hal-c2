import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/space/pages.feature and visualize.feature: what the Space view asks of SpaceController
// as the user writes a page, and what it shows of the Space it is given.
Item {
    id: root
    width: 1200
    height: 800

    Component {
        id: workspaceComponent
        SpaceWorkspace {
            width: 1200
            height: 800
        }
    }

    function block(id, text, more) {
        return Object.assign({ id: id, kind: "paragraph", text: text, checked: false, linkedPageId: "", linkedTitle: "", byAgent: false, openComments: 0, imageId: "", imageState: "", imageUrl: "", imageWidth: 0, imageHeight: 0 }, more);
    }

    function pageRow(id, title, depth, parentPageId) {
        return { id: id, title: title, depth: depth, parentPageId: parentPageId, hasChildren: false, fromThread: false };
    }

    function imageRow(id, name, more) {
        return Object.assign({ id: id, name: name, prompt: "", mimeType: "image/png", width: 4, height: 3, generatedBy: "", url: "" }, more);
    }

    // The Space "Research" with "Roadmap" (and its subpage "Q3") open.
    function research(more) {
        Spaces.load(Object.assign({
            spaceId: "space-1",
            spaceName: "Research",
            spaces: [{ id: "space-1", name: "Research" }],
            pages: [root.pageRow("page-1", "Roadmap", 0, ""), root.pageRow("page-2", "Q3", 1, "page-1"), root.pageRow("page-3", "Ideas", 0, "")],
            blocks: [root.block("b1", "One"), root.block("b2", "Two"), root.block("b3", "Three")],
            page: { id: "page-1", title: "Roadmap", parentPageId: "", trashed: false, sourceThreadId: "", sourceThreadTitle: "" }
        }, more));
        return test.createTemporaryObject(workspaceComponent, root);
    }

    function dispatched(action) {
        return Shell.dispatchedActions.filter(entry => entry.action === action).map(entry => entry.payload);
    }

    TestCase {
        id: test

        name: "SpaceTests"
        when: windowShown

        function init() {
            Shell.reset();
            Spaces.reset();
        }

        function chartBlock(type) {
            return root.block("c1", "Signups (a chart; Numbers from this page)", {
                kind: "chart",
                chart: { type: type, title: "Signups", labels: ["May", "June"], series: [{ name: "Signups", values: [3, 5] }], request: "signups", source: "Numbers from this page" }
            });
        }

        function test_a_chart_draws_its_bars_and_says_where_its_numbers_came_from() {
            const view = root.research({ blocks: [chartBlock("bar")] });
            const chart = findChild(view, "spaceChart");
            tryVerify(() => chart !== null && chart.width > 0);
            compare(findChild(chart, "spaceChartTitle").text, "Signups");
            compare(findChild(chart, "spaceChartSource").text, "Numbers from this page");
            verify(findChild(chart, "spaceChartLabel:May") !== null);
            verify(findChild(chart, "spaceChartBar") !== null);
            verify(findChild(chart, "spaceChartLine") === null);
            verify(!findChild(chart, "spaceChartUnmatched").visible);
            verify(!findChild(chart, "spaceChartLegend").visible, "one series needs no legend");
            verify(!findChild(view, "spaceBlockEditor:" + chartBlock("bar").text).visible, "a chart is not edited as text");
        }

        function test_a_chart_keeps_a_long_label_inside_the_plot() {
            const row = chartBlock("line");
            row.chart.labels = ["The first week of the year", "The last week"];
            const view = root.research({ blocks: [row] });
            const chart = findChild(view, "spaceChart");
            tryVerify(() => chart !== null && chart.width > 0);
            const label = findChild(chart, "spaceChartLabel:The last week");
            verify(label.x + label.width <= chart.width);
            verify(findChild(chart, "spaceChartLabel:The first week of the year").x >= 0);
        }

        function test_a_chart_draws_its_line() {
            const view = root.research({ blocks: [chartBlock("line")] });
            const chart = findChild(view, "spaceChart");
            tryVerify(() => chart !== null && chart.width > 0);
            verify(findChild(chart, "spaceChartLine") !== null);
            verify(findChild(chart, "spaceChartBar") === null);
        }

        function test_a_chart_shows_the_numbers_behind_it_and_hides_them_again() {
            const view = root.research({ blocks: [chartBlock("bar")] });
            const chart = findChild(view, "spaceChart");
            tryVerify(() => chart !== null && chart.width > 0);
            verify(findChild(chart, "spaceChartCell:May") === null);
            mouseClick(findChild(chart, "spaceChartNumbers"));
            tryVerify(() => findChild(chart, "spaceChartCell:May") !== null);
            verify(findChild(chart, "spaceChartCell:5") !== null);
            // In its own column: the empty corner holds the first one's place.
            tryVerify(() => findChild(chart, "spaceChartCell:5").x > 0);
            compare(findChild(chart, "spaceChartCell:May").x, 0);
            compare(findChild(chart, "spaceChartCell:5").x, findChild(chart, "spaceChartCell:Signups").x);
            mouseClick(findChild(chart, "spaceChartNumbers"));
            tryVerify(() => !findChild(chart, "spaceChartTable").visible);
        }

        function test_a_chart_draws_nothing_when_its_numbers_do_not_match_its_labels() {
            for (const values of [[3], [3, 5, 8], [3, "5"], [3, -5]]) {
                const row = chartBlock("bar");
                row.chart.series[0].values = values;
                const view = root.research({ blocks: [row] });
                const chart = findChild(view, "spaceChart");
                tryVerify(() => chart !== null && chart.width > 0);
                verify(findChild(chart, "spaceChartUnmatched").visible, JSON.stringify(values));
                verify(findChild(chart, "spaceChartBar") === null);
                verify(findChild(chart, "spaceChartLabel:May") === null);
                verify(!findChild(chart, "spaceChartNumbers").visible);
                compare(findChild(chart, "spaceChartTitle").text, "Signups");
            }
        }

        function test_a_chart_shows_markup_as_plain_text() {
            const row = chartBlock("bar");
            row.chart.title = "<b>Signups</b>";
            const view = root.research({ blocks: [row] });
            const title = findChild(view, "spaceChartTitle");
            tryVerify(() => title !== null);
            compare(title.textFormat, Text.PlainText);
            compare(title.text, "<b>Signups</b>");
        }

        function test_a_visualize_request_asks_the_mc_and_is_not_written_as_a_block() {
            const view = root.research({});
            const composer = findChild(view, "spaceComposer");
            composer.forceActiveFocus();
            composer.text = "/visualize weekly turns";
            verify(!findChild(view, "spaceSlashMenu").visible);
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.block.visualize"), [{ pageId: "page-1", request: "/visualize weekly turns" }]);
            compare(root.dispatched("space.block.insert").length, 0);
            compare(composer.text, "");
        }

        function test_the_slash_menu_starts_a_visualize_request() {
            const view = root.research({});
            const composer = findChild(view, "spaceComposer");
            composer.forceActiveFocus();
            keyClick("/");
            keyClick("v");
            const slash = findChild(view, "spaceSlashMenu");
            tryVerify(() => slash.visible);
            compare(slash.shown.map(entry => entry.kind), ["chart"]);
            keyClick(Qt.Key_Return);
            tryVerify(() => !slash.visible);
            compare(composer.text, "/visualize ");
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.block.visualize").length, 0);
        }

        function test_asking_again_replaces_the_chart_and_can_be_dropped() {
            const view = root.research({ blocks: [chartBlock("bar")] });
            const again = findChild(view, "spaceAskAgain:" + chartBlock("bar").text);
            tryVerify(() => again !== null);
            again.clicked();
            const composer = findChild(view, "spaceComposer");
            compare(composer.text, "/visualize signups");
            const hint = findChild(view, "spaceReplacing");
            tryVerify(() => hint.visible);
            mouseClick(hint);
            tryVerify(() => !hint.visible);
            compare(composer.text, "");
            again.clicked();
            composer.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.block.visualize"), [{ pageId: "page-1", request: "/visualize signups", blockId: "c1" }]);
        }

        function test_writing_a_block_or_adding_below_ends_asking_again() {
            const blocks = [chartBlock("bar"), root.block("b2", "Below", {})];
            const view = root.research({ blocks: blocks });
            const again = findChild(view, "spaceAskAgain:" + blocks[0].text);
            tryVerify(() => again !== null);
            const hint = findChild(view, "spaceReplacing");
            const composer = findChild(view, "spaceComposer");
            again.clicked();
            tryVerify(() => hint.visible);
            composer.text = "A plain paragraph";
            composer.forceActiveFocus();
            keyClick(Qt.Key_Return);
            tryVerify(() => !hint.visible);
            again.clicked();
            tryVerify(() => hint.visible);
            findChild(view, "spaceBlock:" + blocks[1].text).addBelowRequested("b2");
            tryVerify(() => !hint.visible);
            composer.text = "/visualize signups";
            composer.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.block.visualize"), [{ pageId: "page-1", request: "/visualize signups", afterBlockId: "b2" }]);
        }

        function test_a_slash_picks_the_kind_of_the_next_block() {
            const view = root.research({});
            const composer = findChild(view, "spaceComposer");
            composer.forceActiveFocus();
            keyClick("/");
            keyClick("c");
            keyClick("h");
            keyClick("e");
            const slash = findChild(view, "spaceSlashMenu");
            tryVerify(() => slash.visible);
            compare(slash.shown.map(entry => entry.kind), ["checklist"]);
            keyClick(Qt.Key_Return);
            tryVerify(() => !slash.visible);
            compare(composer.text, "");
            compare(findChild(view, "spaceNewKind").text, "Checklist");
            keyClick("S");
            keyClick("h");
            keyClick("i");
            keyClick("p");
            keyClick(Qt.Key_Return);
            const inserts = root.dispatched("space.block.insert");
            compare(inserts.length, 1);
            compare(inserts[0].kind, "checklist");
            compare(inserts[0].text, "Ship");
            compare(inserts[0].pageId, "page-1");
            // No afterBlockId: the block goes last.
            verify(!("afterBlockId" in inserts[0]));
        }

        function test_a_block_added_below_another_goes_after_it() {
            const view = root.research({});
            mouseClick(findChild(view, "spaceAddBelow:One"));
            compare(findChild(view, "spaceInsertAfter").text, "Adding after “One”");
            keyClick("T");
            keyClick("w");
            keyClick("o");
            keyClick(Qt.Key_Return);
            const inserts = root.dispatched("space.block.insert");
            compare(inserts.length, 1);
            compare(inserts[0].afterBlockId, "b1");
            verify(!findChild(view, "spaceInsertAfter").visible);
        }

        function test_return_writes_an_edited_block_and_escape_drops_the_edit() {
            const view = root.research({});
            const editor = findChild(view, "spaceBlockEditor:One");
            editor.forceActiveFocus();
            editor.selectAll();
            keyClick("X");
            keyClick(Qt.Key_Escape);
            compare(editor.text, "One");
            compare(root.dispatched("space.block.update").length, 0);
            editor.forceActiveFocus();
            editor.selectAll();
            keyClick("F");
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.block.update"), [{ blockId: "b1", text: "F" }]);
        }

        function test_what_the_user_is_writing_is_not_overwritten_by_the_stream() {
            const view = root.research({});
            const editor = findChild(view, "spaceBlockEditor:One");
            editor.forceActiveFocus();
            editor.selectAll();
            keyClick("M");
            // Another client changes the block while the user writes in it.
            Spaces.blocks.setProperty(0, "text", "Theirs");
            compare(editor.text, "M");
            editor.focus = false;
            compare(root.dispatched("space.block.update"), [{ blockId: "b1", text: "M" }]);
        }

        function test_ticking_a_checklist_item_asks_for_the_new_tick() {
            const view = root.research({ blocks: [root.block("b1", "Ship it", { kind: "checklist" })] });
            mouseClick(findChild(view, "spaceTick:Ship it"));
            compare(root.dispatched("space.block.setChecked"), [{ blockId: "b1", checked: true }]);
            // Until the controller says so, the box shows the block's tick.
            verify(!findChild(view, "spaceTick:Ship it").checked);
        }

        function test_moving_a_block_names_the_block_it_goes_after() {
            const view = root.research({});
            tryVerify(() => findChild(view, "spaceBlock:Three") !== null);
            mouseClick(findChild(view, "spaceMoveUp:Three"));
            mouseClick(findChild(view, "spaceMoveUp:Two"));
            mouseClick(findChild(view, "spaceMoveDown:One"));
            compare(root.dispatched("space.block.move"), [{ blockId: "b3", afterBlockId: "b1" }, { blockId: "b2", afterBlockId: "" }, { blockId: "b1", afterBlockId: "b2" }]);
            verify(!findChild(view, "spaceMoveUp:One").enabled);
            verify(!findChild(view, "spaceMoveDown:Three").enabled);
        }

        function test_a_page_moves_into_any_page_but_its_own_subpages() {
            const view = root.research({});
            const sidebar = findChild(view, "spaceSidebar");
            compare(sidebar.movesFor(0).map(page => page.title), ["Ideas"]);
            // Q3 already sits in Roadmap.
            compare(sidebar.movesFor(1).map(page => page.title), ["Ideas"]);
            compare(sidebar.movesFor(2).map(page => page.title), ["Roadmap", "Q3"]);
        }

        function test_a_trashed_page_is_read_only_with_the_way_back() {
            const view = root.research({ page: { id: "page-1", title: "Roadmap", parentPageId: "", trashed: true, sourceThreadId: "", sourceThreadTitle: "" } });
            verify(findChild(view, "spaceTrashedBanner").visible);
            verify(!findChild(view, "spaceComposer").visible);
            verify(findChild(view, "spaceBlockEditor:One").readOnly);
            mouseClick(findChild(view, "spacePageRestore"));
            mouseClick(findChild(view, "spacePageDelete"));
            compare(Shell.dispatchedActions.map(entry => entry.action), ["space.page.restore", "space.page.delete"]);
        }

        function site(more) {
            return Object.assign({ id: "page-1", title: "Roadmap", parentPageId: "", trashed: false, sourceThreadId: "", sourceThreadTitle: "",
                                   site: { url: "http://192.168.1.20:3773/sites/space-1/token", localOnly: false, behind: false, publishedAt: "" } }, more);
        }

        function test_an_unpublished_page_shows_no_site_and_offers_publishing() {
            const view = root.research();
            verify(!findChild(view, "spaceSiteBanner").visible);
            mouseClick(findChild(view, "spacePageActions"));
            const publish = findChild(view, "spacePublish");
            verify(publish.visible);
            compare(publish.text, "Publish as a site");
            verify(!findChild(view, "spaceUnpublish").visible);
            verify(!findChild(view, "spaceCopySiteLink").visible);
            publish.triggered();
            compare(dispatched("space.page.publish"), [{ pageId: "page-1" }]);
        }

        function test_a_published_page_shows_its_link_and_the_ways_on_and_back() {
            const view = root.research({ page: site() });
            verify(findChild(view, "spaceSiteBanner").visible);
            compare(findChild(view, "spaceSiteLink").text, "http://192.168.1.20:3773/sites/space-1/token");
            compare(findChild(view, "spacePublish").text, "Publish again");
            verify(!findChild(view, "spaceSiteLocalOnly").visible);
            mouseClick(findChild(view, "spaceSiteCopy"));
            mouseClick(findChild(view, "spaceSiteRepublish"));
            mouseClick(findChild(view, "spaceSiteUnpublish"));
            compare(Shell.dispatchedActions.map(entry => entry.action), ["space.page.copySiteLink", "space.page.publish", "space.page.unpublish"]);
        }

        function test_the_page_says_when_its_site_is_behind() {
            const view = root.research({ page: site() });
            const upToDate = findChild(view, "spaceSiteStatus").text;
            Spaces.page = site({ site: { url: "http://mc/sites/s/t", localOnly: false, behind: true, publishedAt: "" } });
            verify(findChild(view, "spaceSiteStatus").text !== upToDate);
        }

        function test_a_link_only_this_machine_can_open_says_so_with_the_way_on() {
            const view = root.research({ page: site({ site: { url: "http://127.0.0.1:3773/sites/s/t", localOnly: true, behind: false, publishedAt: "" } }) });
            verify(findChild(view, "spaceSiteLocalOnly").visible);
            mouseClick(findChild(view, "spaceSiteTailscale"));
            compare(dispatched("space.page.publish"), [{ pageId: "page-1", tailscale: true }]);
        }

        function test_a_trashed_page_offers_no_publishing() {
            const view = root.research({ page: { id: "page-1", title: "Roadmap", parentPageId: "", trashed: true, sourceThreadId: "", sourceThreadTitle: "" } });
            mouseClick(findChild(view, "spacePageActions"));
            verify(!findChild(view, "spacePublish").visible);
            verify(findChild(view, "spaceCopyMarkdown").visible);
        }

        function test_the_trash_restores_and_deletes_for_good() {
            const view = root.research({ trash: [{ id: "page-9", title: "Old", trashedAt: "2026-09-23T10:00:00.000Z" }] });
            const trash = findChild(view, "spaceTrash");
            compare(trash.text, "Trash (1)");
            mouseClick(trash);
            mouseClick(findChild(view, "spaceRestore:Old"));
            mouseClick(findChild(view, "spaceDelete:Old"));
            compare(Shell.dispatchedActions.map(entry => [entry.action, entry.payload.pageId]), [["space.page.restore", "page-9"], ["space.page.delete", "page-9"]]);
        }

        function test_a_comment_goes_on_the_chosen_block_and_is_resolved_or_reopened() {
            const view = root.research({
                comments: [{ id: "c1", blockId: "b2", blockText: "Two", body: "Which week?", resolved: false, byAgent: false, createdAt: "" },
                           { id: "c2", blockId: "b2", blockText: "Two", body: "Done", resolved: true, byAgent: true, createdAt: "" }]
            });
            mouseClick(findChild(view, "spaceComment:One"));
            const comments = findChild(view, "spaceComments");
            verify(comments.visible);
            keyClick("O");
            keyClick("k");
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.comment.add"), [{ pageId: "page-1", blockId: "b1", body: "Ok" }]);
            mouseClick(findChild(view, "spaceCommentResolve:Which week?"));
            mouseClick(findChild(view, "spaceCommentReopen:Done"));
            compare(root.dispatched("space.comment.resolve"), [{ commentId: "c1" }]);
            compare(root.dispatched("space.comment.reopen"), [{ commentId: "c2" }]);
        }

        function test_an_empty_space_says_so_and_offers_a_first_page() {
            const view = root.research({ pages: [], blocks: [], page: {} });
            verify(!findChild(view, "spacePage").visible);
            compare(findChild(view, "spaceEmptyText").text, "Research has no pages yet.");
            mouseClick(findChild(view, "spaceEmptyNewPage"));
            const field = findChild(view, "spaceNameField");
            verify(field.visible);
            keyClick("R");
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.page.create"), [{ title: "R", parentPageId: "", link: false }]);
        }

        function test_a_subpage_made_from_the_link_menu_is_linked() {
            const view = root.research({});
            findChild(view, "spaceComposer").forceActiveFocus();
            keyClick("/");
            keyClick("l");
            keyClick(Qt.Key_Return);
            const menu = findChild(view, "spaceLinkMenu");
            tryVerify(() => menu.opened);
            mouseClick(findChild(view, "spaceLinkNewSubpage"));
            const field = findChild(view, "spaceNameField");
            tryVerify(() => field.visible);
            keyClick("Q");
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.page.create"), [{ title: "Q", parentPageId: "page-1", link: true }]);
        }

        function test_an_unreachable_mc_is_said_rather_than_an_empty_space() {
            const view = root.research({ status: "unreachable", pages: [], blocks: [], page: {} });
            compare(findChild(view, "spaceEmptyText").text, "The MC cannot be reached, so its Spaces cannot be shown.");
            verify(!findChild(view, "spaceEmptyNewPage").visible);
        }

        function test_renaming_the_page_writes_its_new_title() {
            const view = root.research({});
            const title = findChild(view, "spacePageTitle");
            compare(title.text, "Roadmap");
            title.forceActiveFocus();
            title.selectAll();
            keyClick("P");
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.page.rename"), [{ pageId: "page-1", title: "P" }]);
        }

        function test_an_image_block_is_placed_from_the_spaces_images() {
            const view = root.research({ images: [root.imageRow("image-1", "cat.png")] });
            findChild(view, "spaceComposer").forceActiveFocus();
            keyClick("/");
            keyClick("i");
            keyClick("m");
            keyClick(Qt.Key_Return);
            const menu = findChild(view, "spaceImageMenu");
            tryVerify(() => menu.opened);
            mouseClick(findChild(view, "spaceImageMenu:cat.png"));
            compare(root.dispatched("space.block.insert"), [{ pageId: "page-1", kind: "image", text: "cat.png", checked: false, imageId: "image-1" }]);
        }

        function test_an_image_block_says_what_became_of_its_image() {
            const view = root.research({ blocks: [root.block("b1", "cat.png", { kind: "image", imageId: "i1", imageState: "trashed" }), root.block("b2", "dog.png", { kind: "image", imageId: "i2", imageState: "deleted" })] });
            const trashed = findChild(view, "spaceBlockImage:cat.png");
            compare(findChild(trashed, "spaceBlockImageSays").text, "This image is in the trash.");
            mouseClick(findChild(trashed, "spaceBlockImageRestore"));
            compare(root.dispatched("space.image.restore"), [{ imageId: "i1" }]);
            tryVerify(() => findChild(view, "spaceBlockImage:dog.png") !== null);
            const deleted = findChild(view, "spaceBlockImage:dog.png");
            compare(findChild(deleted, "spaceBlockImageSays").text, "This image was deleted.");
            verify(!findChild(deleted, "spaceBlockImageRestore").visible);
        }

        function test_an_image_that_will_not_decode_says_so() {
            const view = root.research({ blocks: [root.block("b1", "cat.png", { kind: "image", imageId: "i1", imageState: "shown", imageUrl: "file:///nowhere/cat.png", imageWidth: 400, imageHeight: 200 })] });
            const holder = findChild(view, "spaceBlockImage:cat.png");
            tryCompare(findChild(holder, "spaceBlockImageSays"), "text", "This image could not be shown.");
            verify(findChild(holder, "spaceBlockPicture").asynchronous);
        }

        function test_an_image_keeps_its_place_before_it_loads() {
            const view = root.research({ blocks: [root.block("b1", "cat.png", { kind: "image", imageId: "i1", imageState: "shown", imageWidth: 400, imageHeight: 200 })] });
            const holder = findChild(view, "spaceBlockImage:cat.png");
            compare(holder.height, holder.width / 2);
            compare(findChild(holder, "spaceBlockPicture").sourceSize.width, 1440);
        }

        function test_the_images_browser_trashes_restores_and_deletes() {
            const view = root.research({ images: [root.imageRow("i1", "cat.png", { prompt: "a cat" })], imageTrash: [root.imageRow("i2", "dog.png")] });
            mouseClick(findChild(view, "spaceImages"));
            compare(root.dispatched("space.images.show"), [{ shown: true }]);
            const browser = findChild(view, "spaceImagesBrowser");
            tryVerify(() => browser.visible);
            verify(!findChild(view, "spacePage").visible);
            tryVerify(() => findChild(browser, "spaceImageTrash:cat.png") !== null);
            const trash = findChild(browser, "spaceImageTrash:cat.png");
            waitForItemPolished(findChild(browser, "spaceImageGrid").parent);
            mouseClick(trash);
            compare(root.dispatched("space.image.trash"), [{ imageId: "i1" }]);
            mouseClick(findChild(browser, "spaceImagesTrash"));
            tryVerify(() => findChild(browser, "spaceImageRestore:dog.png") !== null);
            mouseClick(findChild(browser, "spaceImageRestore:dog.png"));
            compare(root.dispatched("space.image.restore"), [{ imageId: "i2" }]);
            mouseClick(findChild(browser, "spaceImageDelete:dog.png"));
            compare(root.dispatched("space.image.delete"), [{ imageId: "i2" }]);
            mouseClick(findChild(browser, "spaceImagesClose"));
            tryVerify(() => !browser.visible);
            compare(root.dispatched("space.images.show"), [{ shown: true }, { shown: false }]);
        }

        function test_cards_stay_level_with_or_without_a_prompt() {
            const view = root.research({ images: [root.imageRow("i1", "cat.png", { prompt: "a cat" }), root.imageRow("i2", "dog.png")] });
            mouseClick(findChild(view, "spaceImages"));
            const browser = findChild(view, "spaceImagesBrowser");
            tryVerify(() => findChild(browser, "spaceImage:dog.png") !== null);
            waitForItemPolished(findChild(browser, "spaceImageGrid").contentItem);
            const nameOf = card => findChild(findChild(browser, card), "spaceImageName");
            tryCompare(nameOf("spaceImage:dog.png"), "y", nameOf("spaceImage:cat.png").y);
        }

        function test_the_generate_dialog_offers_only_who_can_generate() {
            Shell.state = Object.assign({}, Shell.state, { space: { imageProviders: { providers: [{ instanceId: "codex", status: "ready" }, { instanceId: "claudeAgent", status: "unsupported" }], selection: { instanceId: "codex", model: "gpt-5" } } } });
            const view = root.research({});
            mouseClick(findChild(view, "spaceImages"));
            mouseClick(findChild(view, "spaceImageGenerate"));
            const dialog = findChild(view, "spaceImageDialog");
            tryVerify(() => dialog.opened);
            compare(root.dispatched("space.image.providers").length, 1);
            compare(dialog.ready, ["codex"]);
            compare(findChild(dialog.contentItem, "spaceImageModel").onlyInstances, ["codex"]);
            compare(findChild(dialog.contentItem, "spaceImageNotHere").text, "Not supported here: claudeAgent");
            verify(!findChild(dialog.contentItem, "spaceImageSubmit").enabled);
            findChild(dialog.contentItem, "spaceImagePrompt").text = "a red fox";
            mouseClick(findChild(dialog.contentItem, "spaceImageSubmit"));
            compare(root.dispatched("space.image.generate"), [{ prompt: "a red fox", modelSelection: { instanceId: "codex", model: "gpt-5" } }]);
        }

        function test_the_generate_dialog_says_when_no_one_can_generate() {
            Shell.state = Object.assign({}, Shell.state, { space: { imageProviders: { providers: [{ instanceId: "claudeAgent", status: "unsupported" }], selection: null } } });
            const view = root.research({});
            mouseClick(findChild(view, "spaceImages"));
            mouseClick(findChild(view, "spaceImageGenerate"));
            const dialog = findChild(view, "spaceImageDialog");
            tryVerify(() => dialog.opened);
            verify(findChild(dialog.contentItem, "spaceImageNoProvider").visible);
            findChild(dialog.contentItem, "spaceImagePrompt").text = "a red fox";
            verify(!findChild(dialog.contentItem, "spaceImageSubmit").enabled);
        }

        function test_a_page_from_a_thread_names_its_thread() {
            const view = root.research({ page: { id: "page-1", title: "Roadmap", parentPageId: "", trashed: false, sourceThreadId: "t1", sourceThreadTitle: "Work" } });
            const source = findChild(view, "spacePageSource");
            verify(source.visible);
            compare(source.text, "Made from the thread “Work”");
        }
    }
}
