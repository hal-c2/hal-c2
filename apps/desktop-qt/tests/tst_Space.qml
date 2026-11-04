import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/space/pages.feature, visualize.feature and slides.feature: what the Space view
// asks of SpaceController as the user writes a page or a deck, and what it shows of the
// Space it is given.
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

    // Reads the clipboard back.
    TextEdit {
        id: pasteTarget
        visible: false
        textFormat: TextEdit.PlainText
    }

    function block(id, text, more) {
        return Object.assign({ id: id, kind: "paragraph", text: text, checked: false, linkedPageId: "", linkedTitle: "", byAgent: false, openComments: 0, level: 0, language: "", imageId: "", imageState: "", imageUrl: "", imageWidth: 0, imageHeight: 0 }, more);
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
        // The prompt aimed at the open page, as ComposerController publishes it.
        Shell.state = Object.assign({}, Shell.state, {
            composer: Object.assign({}, Shell.state.composer, {
                target: "page#page-1",
                routeKind: "page",
                pageId: "page-1",
                project: { id: "shop", title: "shop" },
                projects: [{ id: "shop", title: "shop" }, { id: "docs", title: "docs" }],
                followUpBehavior: ""
            })
        });
        return test.createTemporaryObject(workspaceComponent, root);
    }

    // The controller's part of a page's prompt (ComposerController::submitPage):
    // words that are not an ask come back to the page to be written.
    Connections {
        target: Shell
        function onActionRequested(action, payload) {
            if (action === "composer.submit" && Shell.state.composer.routeKind === "page" && !/^@agent(\s|$)/i.test(payload.text.trim()) && payload.text.trim() !== "")
                Shell.actionRequested("space.prompt.write", { pageId: Shell.state.composer.pageId, text: payload.text.trim() });
        }
    }

    function dispatched(action) {
        return Shell.dispatchedActions.filter(entry => entry.action === action).map(entry => entry.payload);
    }

    // Whether `name` is in `view` and shown.
    function showing(view, name) {
        const item = test.findChild(view, name);
        return item !== null && item.visible;
    }

    // The source editor of the block with `text`, shown as a click on its
    // drawn text shows it.
    function editorOf(view, text) {
        const shown = test.findChild(view, "spaceBlock:" + text);
        if (shown.editor === null)
            shown.edit();
        return shown.editor;
    }

    TestCase {
        id: test

        name: "SpaceTests"
        when: windowShown

        function init() {
            Shell.reset();
            Spaces.reset();
            Diagrams.reset();
        }

        // "Roadmap" with its history open: "Final" now, "Draft" before it.
        function withHistory(more) {
            const versions = [
                { id: "12", version: 12, at: "2026-09-23T10:10:00Z", byAgent: true, byUpdate: false, byFile: false, threadTitle: "Work", restoredFromAt: "" },
                { id: "7", version: 7, at: "2026-09-23T10:00:00Z", byAgent: false, byUpdate: false, byFile: false, threadTitle: "", restoredFromAt: "" }
            ];
            return root.research({ history: Object.assign({ shown: true, pageId: "page-1", versions: versions }, more) });
        }

        function test_the_page_menu_opens_its_history() {
            const view = root.research({});
            findChild(view, "spaceHistoryOpen").triggered();
            compare(root.dispatched("space.history.open"), [{ pageId: "page-1" }]);
        }

        function test_only_a_version_before_the_newest_can_be_restored() {
            const view = withHistory({});
            const panel = findChild(view, "spaceHistoryPanel");
            verify(panel.visible);
            tryVerify(() => findChild(view, "spaceHistoryRow:1") !== null);
            verify(!findChild(view, "spaceHistoryRestore:0").visible);
            const restore = findChild(view, "spaceHistoryRestore:1");
            verify(restore.visible);
            mouseClick(restore);
            compare(root.dispatched("space.history.restore"), [{ version: 7 }]);
        }

        function test_a_page_in_the_trash_restores_no_version() {
            const view = root.research({
                page: { id: "page-1", title: "Roadmap", parentPageId: "", trashed: true, sourceThreadId: "", sourceThreadTitle: "" },
                history: { shown: true, pageId: "page-1", versions: [
                    { id: "12", version: 12, at: "2026-09-23T10:10:00Z", byAgent: false, byUpdate: false, byFile: false, threadTitle: "", restoredFromAt: "" },
                    { id: "7", version: 7, at: "2026-09-23T10:00:00Z", byAgent: false, byUpdate: false, byFile: false, threadTitle: "", restoredFromAt: "" }
                ] }
            });
            tryVerify(() => findChild(view, "spaceHistoryRow:1") !== null);
            verify(!findChild(view, "spaceHistoryRestore:1").visible);
        }

        function test_a_version_read_takes_the_page_place_and_has_a_way_back() {
            const view = withHistory({
                reading: true,
                version: { version: 7, at: "2026-09-23T10:00:00Z", title: "Roadmap" },
                blocks: [root.block("b1", "Draft")]
            });
            const reader = findChild(view, "spaceVersionView");
            verify(reader.visible);
            tryVerify(() => findChild(reader, "spaceBlock:Draft") !== null);
            mouseClick(findChild(view, "spaceVersionBack"));
            compare(root.dispatched("space.history.back").length, 1);
            mouseClick(findChild(view, "spaceVersionRestore"));
            compare(root.dispatched("space.history.restore"), [{ version: 7 }]);
        }

        function test_a_version_read_draws_its_chart_and_cannot_ask_again() {
            const row = chartBlock("bar");
            const view = withHistory({
                reading: true,
                version: { version: 7, at: "2026-09-23T10:00:00Z", title: "Roadmap" },
                blocks: [row]
            });
            const chart = findChild(findChild(view, "spaceVersionView"), "spaceChart");
            tryVerify(() => chart !== null && chart.width > 0);
            compare(findChild(chart, "spaceChartTitle").text, "Signups");
            verify(!findChild(view, "spaceAskAgain:" + row.text).visible);
        }

        function test_reading_the_newest_version_offers_no_restore() {
            const view = withHistory({
                reading: true,
                version: { version: 12, at: "2026-09-23T10:10:00Z", title: "Roadmap" },
                blocks: [root.block("b1", "Final")]
            });
            verify(!findChild(view, "spaceVersionRestore").visible);
        }

        function test_history_that_could_not_load_says_so_and_can_be_asked_again() {
            const view = root.research({ history: { shown: true, pageId: "page-1", failed: true } });
            compare(findChild(view, "spaceHistoryNote").text, "The history could not be loaded.");
            mouseClick(findChild(view, "spaceHistoryRetry"));
            compare(root.dispatched("space.history.open"), [{ pageId: "page-1" }]);
        }

        function test_opening_comments_closes_the_history() {
            const view = withHistory({});
            view.showComments("b1");
            compare(root.dispatched("space.history.close").length, 1);
        }

        function test_a_comment_whose_block_a_restore_took_away_says_so() {
            const view = root.research({ comments: [{ id: "c1", blockId: "gone", blockText: "", blockGone: true, body: "Why?", resolved: false, byAgent: false, createdAt: "" }] });
            view.commentsShown = true;
            compare(findChild(view, "spaceCommentBlock:Why?").text, "On a block no longer on this page");
        }

        function test_a_comment_on_the_page_itself_has_lost_no_block() {
            const view = root.research({ comments: [{ id: "c1", blockId: "", blockText: "", blockGone: false, body: "Why?", resolved: false, byAgent: false, createdAt: "" }] });
            view.commentsShown = true;
            verify(findChild(view, "spaceCommentBlock:Why?").text !== "On a block no longer on this page");
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
            verify(!root.showing(view, "spaceBlockEditor:" + chartBlock("bar").text), "a chart is not edited as text");
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
            composer.focusInput();
            composer.editor.text = "/visualize weekly turns";
            verify(!findChild(view, "spaceSlashMenu").visible);
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.block.visualize"), [{ pageId: "page-1", request: "/visualize weekly turns" }]);
            compare(root.dispatched("space.block.insert").length, 0);
            compare(composer.editor.text, "");
        }

        function test_the_slash_menu_starts_a_visualize_request() {
            const view = root.research({});
            const composer = findChild(view, "spaceComposer");
            composer.focusInput();
            keyClick("/");
            keyClick("v");
            const slash = findChild(view, "spaceSlashMenu");
            tryVerify(() => slash.visible);
            compare(slash.shown.map(entry => entry.kind), ["chart"]);
            keyClick(Qt.Key_Return);
            tryVerify(() => !slash.visible);
            compare(composer.editor.text, "/visualize ");
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.block.visualize").length, 0);
        }

        function test_asking_again_replaces_the_chart_and_can_be_dropped() {
            const view = root.research({ blocks: [chartBlock("bar")] });
            const again = findChild(view, "spaceAskAgain:" + chartBlock("bar").text);
            tryVerify(() => again !== null);
            again.clicked();
            const composer = findChild(view, "spaceComposer");
            compare(composer.editor.text, "/visualize signups");
            const hint = findChild(view, "spaceReplacing");
            tryVerify(() => hint.visible);
            mouseClick(hint);
            tryVerify(() => !hint.visible);
            compare(composer.editor.text, "");
            again.clicked();
            composer.focusInput();
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
            composer.editor.text = "A plain paragraph";
            composer.focusInput();
            keyClick(Qt.Key_Return);
            tryVerify(() => !hint.visible);
            again.clicked();
            tryVerify(() => hint.visible);
            findChild(view, "spaceBlock:" + blocks[1].text).addBelowRequested("b2");
            tryVerify(() => !hint.visible);
            composer.editor.text = "/visualize signups";
            composer.focusInput();
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.block.visualize"), [{ pageId: "page-1", request: "/visualize signups", afterBlockId: "b2" }]);
        }

        function pitch(more) {
            const view = root.research(Object.assign({
                deck: { id: "deck-1", title: "Pitch", trashed: false },
                decks: [{ id: "deck-1", title: "Pitch" }],
                slides: [{ id: "s1", title: "One", body: "" }, { id: "s2", title: "Two", body: "" }, { id: "s3", title: "Three", body: "" }]
            }, more));
            tryVerify(() => findChild(view, "spaceSlideTitle:2"));
            return view;
        }

        function test_an_open_deck_shows_in_place_of_the_page() {
            const view = pitch({});
            verify(findChild(view, "spaceDeck").visible);
            verify(!findChild(view, "spacePage").visible);
            compare(findChild(view, "spaceDeckTitle").text, "Pitch");
            compare(findChild(view, "spaceSlideTitle:1").text, "Two");
        }

        function test_the_images_give_way_to_a_deck_chosen_beside_them() {
            const view = pitch({ images: [root.imageRow("i1", "cat.png")] });
            mouseClick(findChild(view, "spaceImages"));
            const browser = findChild(view, "spaceImagesBrowser");
            tryVerify(() => browser.visible);
            verify(!findChild(view, "spaceDeck").visible);
            mouseClick(findChild(view, "spaceDeckRow:Pitch"));
            tryVerify(() => !browser.visible);
            verify(findChild(view, "spaceDeck").visible);
        }

        function test_slides_move_up_and_down_past_their_neighbours() {
            const view = pitch({});
            mouseClick(findChild(view, "spaceSlideUp:1"));
            compare(root.dispatched("space.slide.move")[0].afterSlideId, "");
            mouseClick(findChild(view, "spaceSlideUp:2"));
            compare(root.dispatched("space.slide.move")[1].afterSlideId, "s1");
            mouseClick(findChild(view, "spaceSlideDown:0"));
            compare(root.dispatched("space.slide.move")[2].afterSlideId, "s2");
        }

        function test_a_slide_is_written_when_the_user_leaves_the_field() {
            const view = pitch({});
            const title = findChild(view, "spaceSlideTitle:0");
            title.forceActiveFocus();
            title.text = "First";
            title.focus = false;
            compare(root.dispatched("space.slide.update")[0], { spaceId: "space-1", slideId: "s1", title: "First" });
        }

        function test_a_title_being_written_goes_to_its_own_deck() {
            const view = pitch({});
            const title = findChild(view, "spaceDeckTitle");
            title.forceActiveFocus();
            title.text = "Keynote";
            Spaces.deck = { id: "deck-2", title: "Other", trashed: false };
            compare(root.dispatched("space.deck.rename"), [{ spaceId: "space-1", deckId: "deck-1", title: "Keynote" }]);
            compare(title.text, "Other");
            title.focus = false;
            compare(root.dispatched("space.deck.rename").length, 1);
        }

        function test_a_title_being_written_goes_to_the_space_its_deck_is_in() {
            const view = pitch({});
            const title = findChild(view, "spaceDeckTitle");
            title.forceActiveFocus();
            title.text = "Keynote";
            Spaces.spaceId = "space-2";
            Spaces.deck = {};
            compare(root.dispatched("space.deck.rename"), [{ spaceId: "space-1", deckId: "deck-1", title: "Keynote" }]);
        }

        function test_picking_another_deck_renames_nothing_when_nothing_was_written() {
            const view = pitch({});
            const title = findChild(view, "spaceDeckTitle");
            title.forceActiveFocus();
            Spaces.deck = { id: "deck-2", title: "Other", trashed: false };
            compare(title.text, "Other");
            Spaces.deck = {};
            title.focus = false;
            compare(root.dispatched("space.deck.rename"), []);
        }

        function test_leaving_the_title_keeps_a_rename_from_another_client() {
            const view = pitch({});
            const title = findChild(view, "spaceDeckTitle");
            title.forceActiveFocus();
            Spaces.deck = { id: "deck-1", title: "Theirs", trashed: false };
            title.focus = false;
            compare(root.dispatched("space.deck.rename"), []);
            compare(title.text, "Theirs");
        }

        function test_a_slide_being_written_goes_to_the_space_it_is_in() {
            const view = pitch({});
            const title = findChild(view, "spaceSlideTitle:0");
            title.forceActiveFocus();
            title.text = "First";
            Spaces.load({ spaceId: "space-2", spaceName: "Lab", spaces: [], pages: [], blocks: [], slides: [] });
            tryVerify(() => root.dispatched("space.slide.update").length === 1);
            compare(root.dispatched("space.slide.update")[0], { spaceId: "space-1", slideId: "s1", title: "First" });
        }

        function test_a_slide_being_written_survives_picking_a_deck_in_the_trash_data() {
            return [
                { tag: "title", field: "spaceSlideTitle:0", write: { title: "First" } },
                { tag: "body", field: "spaceSlideBody:0", write: { body: "First" } }
            ];
        }

        function test_a_slide_being_written_survives_picking_a_deck_in_the_trash(data) {
            const view = pitch({});
            const field = findChild(view, data.field);
            field.forceActiveFocus();
            field.text = "First";
            Spaces.load({
                spaceId: "space-1",
                spaceName: "Research",
                deck: { id: "deck-9", title: "Old", trashed: true },
                deckTrash: [{ id: "deck-9", title: "Old", trashedAt: "t" }],
                slides: [{ id: "s9", title: "Gone", body: "" }]
            });
            tryVerify(() => root.dispatched("space.slide.update").length === 1);
            compare(root.dispatched("space.slide.update")[0], Object.assign({ spaceId: "space-1", slideId: "s1" }, data.write));
        }

        function test_leaving_a_slide_keeps_an_edit_from_another_client_data() {
            return [
                { tag: "title", field: "spaceSlideTitle:0", role: "title" },
                { tag: "body", field: "spaceSlideBody:0", role: "body" }
            ];
        }

        function test_leaving_a_slide_keeps_an_edit_from_another_client(data) {
            const view = pitch({});
            const field = findChild(view, data.field);
            field.forceActiveFocus();
            Spaces.slides.setProperty(0, data.role, "Theirs");
            field.focus = false;
            compare(root.dispatched("space.slide.update"), []);
            compare(field.text, "Theirs");
        }

        function test_escape_on_a_slide_keeps_an_edit_from_another_client() {
            const view = pitch({});
            const title = findChild(view, "spaceSlideTitle:0");
            title.forceActiveFocus();
            title.text = "Mine";
            Spaces.slides.setProperty(0, "title", "Theirs");
            keyClick(Qt.Key_Escape);
            compare(root.dispatched("space.slide.update"), []);
            compare(title.text, "Theirs");
        }

        function test_an_edit_from_another_client_does_not_replace_what_is_being_typed_data() {
            return [
                { tag: "title", field: "spaceSlideTitle:0", role: "title" },
                { tag: "body", field: "spaceSlideBody:0", role: "body" }
            ];
        }

        function test_an_edit_from_another_client_does_not_replace_what_is_being_typed(data) {
            const view = pitch({ slides: [{ id: "s1", title: "", body: "" }, { id: "s2", title: "Two", body: "" }, { id: "s3", title: "Three", body: "" }] });
            const field = findChild(view, data.field);
            field.forceActiveFocus();
            keyClick(Qt.Key_M);
            compare(field.text, "m");
            Spaces.slides.setProperty(0, data.role, "Theirs");
            compare(field.text, "m");
        }

        function test_writing_over_an_edit_from_another_client_is_the_users_to_make() {
            const view = pitch({});
            const title = findChild(view, "spaceSlideTitle:0");
            title.forceActiveFocus();
            title.text = "Mine";
            Spaces.slides.setProperty(0, "title", "Theirs");
            title.focus = false;
            compare(root.dispatched("space.slide.update"), [{ spaceId: "space-1", slideId: "s1", title: "Mine" }]);
        }

        function test_leaving_a_slide_of_a_trashed_deck_writes_nothing() {
            const view = pitch({ deck: { id: "deck-1", title: "Pitch", trashed: true }, decks: [], deckTrash: [{ id: "deck-1", title: "Pitch", trashedAt: "t" }] });
            const title = findChild(view, "spaceSlideTitle:0");
            title.forceActiveFocus();
            title.focus = false;
            const body = findChild(view, "spaceSlideBody:0");
            body.forceActiveFocus();
            body.focus = false;
            compare(root.dispatched("space.slide.update"), []);
        }

        function test_a_slide_goes_below_the_one_the_user_added_from() {
            const view = pitch({});
            mouseClick(findChild(view, "spaceSlideAdd:0"));
            compare(root.dispatched("space.slide.insert")[0].afterSlideId, "s1");
            mouseClick(findChild(view, "spaceSlideDelete:1"));
            compare(root.dispatched("space.slide.delete")[0].slideId, "s2");
        }

        function test_a_trashed_deck_is_read_only_with_the_way_back() {
            const view = pitch({ deck: { id: "deck-1", title: "Pitch", trashed: true }, decks: [], deckTrash: [{ id: "deck-1", title: "Pitch", trashedAt: "t" }] });
            verify(findChild(view, "spaceDeckTrashedBanner").visible);
            verify(findChild(view, "spaceSlideTitle:0").readOnly);
            verify(!findChild(view, "spaceDeckPresent").enabled);
            mouseClick(findChild(view, "spaceDeckRestore"));
            compare(root.dispatched("space.deck.restore")[0].deckId, "deck-1");
        }

        function test_the_trash_holds_decks_beside_pages() {
            const view = root.research({
                trash: [{ id: "page-9", title: "Old page", trashedAt: "t" }],
                deckTrash: [{ id: "deck-9", title: "Old deck", trashedAt: "t" }]
            });
            mouseClick(findChild(view, "spaceTrash"));
            compare(findChild(view, "spaceTrash").text, "Trash (2)");
            mouseClick(findChild(view, "spaceRestoreDeck:Old deck"));
            compare(root.dispatched("space.deck.restore")[0].deckId, "deck-9");
            mouseClick(findChild(view, "spaceDeleteDeck:Old deck"));
            compare(root.dispatched("space.deck.delete")[0].deckId, "deck-9");
        }

        function test_a_page_makes_a_deck_from_its_menu() {
            const view = root.research({});
            findChild(view, "spaceMakeDeck").triggered();
            compare(root.dispatched("space.deck.createFromPage")[0].pageId, "page-1");
        }

        function test_the_presenter_steps_by_key_and_leaves_with_escape() {
            const view = pitch({ presenting: true, slide: { id: "s2", title: "Two", body: "Words" }, slideNumber: 2, slideCount: 3 });
            const keys = findChild(view, "spacePresenterKeys");
            tryVerify(() => keys.activeFocus);
            compare(findChild(view, "spacePresenterTitle").text, "Two");
            compare(findChild(view, "spacePresenterCount").text, "2 / 3");
            keyClick(Qt.Key_Right);
            keyClick(Qt.Key_Space);
            keyClick(Qt.Key_Left);
            compare(root.dispatched("space.deck.step").map(entry => entry.by), [1, 1, -1]);
            keyClick(Qt.Key_Escape);
            compare(root.dispatched("space.deck.leave").length, 1);
        }

        function test_a_tap_on_the_left_goes_back_and_elsewhere_goes_on() {
            const view = pitch({ presenting: true, slide: { id: "s1", title: "One", body: "" }, slideNumber: 1, slideCount: 3 });
            const tap = findChild(view, "spacePresenterTap");
            tryVerify(() => tap.visible && tap.width > 0);
            mouseClick(tap, 10, 10);
            mouseClick(tap, tap.width - 10, 10);
            compare(root.dispatched("space.deck.step").map(entry => entry.by), [-1, 1]);
        }

        function test_a_slash_picks_the_kind_of_the_next_block() {
            const view = root.research({});
            const composer = findChild(view, "spaceComposer");
            composer.focusInput();
            keyClick("/");
            keyClick("c");
            keyClick("h");
            keyClick("e");
            const slash = findChild(view, "spaceSlashMenu");
            tryVerify(() => slash.visible);
            compare(slash.shown.map(entry => entry.kind), ["checklist"]);
            keyClick(Qt.Key_Return);
            tryVerify(() => !slash.visible);
            compare(composer.editor.text, "");
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

        // A diagram as the MC imports a "mermaid" fence: a code block in "mermaid"
        // holding the bare source (HalC2.Space.Markdown; space/markdown.feature,
        // Mermaid diagrams).
        function mermaidBlock(source) {
            return root.block("d1", source, { kind: "code", language: "mermaid" });
        }

        function test_a_mermaid_block_is_drawn_in_place_of_its_source() {
            const source = "flowchart LR\n  A --> B";
            const row = mermaidBlock(source);
            const view = root.research({ blocks: [row] });
            const note = findChild(findChild(view, "spaceDiagramNote:" + row.text), "mermaidStatus");
            verify(note.visible);
            compare(note.text, "Drawing the diagram…");
            verify(findChild(view, "spaceBlockEditor:" + row.text).visible, "its source shows until it is drawn");

            Diagrams.answer(source, "dark", { status: "drawn", kind: "flowchart", url: "", width: 200, height: 80 });
            const diagram = findChild(view, "spaceDiagram:" + row.text);
            verify(diagram.visible);
            compare(findChild(diagram, "mermaidImage").width, 200);
            verify(!root.showing(view, "spaceBlockEditor:" + row.text));
            verify(!note.visible);

            // The source is the way to edit it, and what is saved is drawn.
            mouseClick(findChild(view, "spaceDiagramSource:" + row.text));
            verify(findChild(view, "spaceBlockEditor:" + row.text).visible);
            verify(!diagram.visible);
            const edited = source + "\n  B --> C";
            Spaces.blocks.setProperty(0, "text", edited);
            verify(("dark\n" + edited) in Diagrams.asked, "the new source is asked for");
            Diagrams.answer(edited, "dark", { status: "drawn", kind: "flowchart", url: "", width: 200, height: 120 });
            verify(findChild(view, "spaceDiagram:" + edited).visible, "drawn again with the new node");
        }

        // Another client's or an agent's edit arriving mid-sentence neither
        // hides the source nor takes the keyboard away.
        function test_an_edit_from_elsewhere_leaves_the_diagram_source_being_written() {
            const source = "flowchart LR\n  A --> B";
            const row = mermaidBlock(source);
            const view = root.research({ blocks: [row] });
            Diagrams.answer(source, "dark", { status: "drawn", kind: "flowchart", url: "", width: 200, height: 80 });
            mouseClick(findChild(view, "spaceDiagramSource:" + row.text));
            const editor = findChild(view, "spaceBlockEditor:" + row.text);
            editor.forceActiveFocus();
            verify(editor.activeFocus);

            const theirs = source + "\n  B --> C";
            Spaces.blocks.setProperty(0, "text", theirs);
            Diagrams.answer(theirs, "dark", { status: "drawn", kind: "flowchart", url: "", width: 200, height: 120 });
            verify(editor.visible, "the source stays");
            verify(editor.activeFocus, "the user is still writing");
            compare(root.dispatched("space.block.update").length, 0);
        }

        function test_a_mermaid_block_with_a_mistake_shows_its_source_and_where() {
            const source = "flowchart LR\n  A[open --> B";
            const row = mermaidBlock(source);
            const view = root.research({ blocks: [row] });
            Diagrams.answer(source, "dark", { status: "invalid", kind: "flowchart", reason: "An unclosed bracket.", line: 2, column: 3 });
            verify(findChild(view, "spaceBlockEditor:" + row.text).visible);
            verify(!findChild(view, "spaceDiagram:" + row.text).visible);
            const note = findChild(findChild(view, "spaceDiagramNote:" + row.text), "mermaidStatus");
            verify(note.visible);
            compare(note.text, "Line 2: An unclosed bracket.");
            verify(!findChild(view, "spaceDiagramSource:" + row.text).visible);
        }

        // A fence the MC keeps as written (indented, or with a space before
        // its language) is a raw block, and is drawn too.
        function test_a_mermaid_fence_kept_as_written_is_drawn_too() {
            const view = root.research({ blocks: [
                root.block("r1", "``` mermaid\nflowchart LR\n  A --> B\n```", { kind: "raw" }),
                root.block("r2", "  ~~~Mermaid\nsequenceDiagram\n  A->>B: hi\n  ~~~", { kind: "raw" })
            ] });
            tryVerify(() => findChild(view, "spaceBlockEditor:  ~~~Mermaid\nsequenceDiagram\n  A->>B: hi\n  ~~~"), 1000, "every block is on the page");
            compare(Object.keys(Diagrams.asked).sort(), ["dark\nflowchart LR\n  A --> B", "dark\nsequenceDiagram\n  A->>B: hi"]);
        }

        function test_only_a_mermaid_code_block_or_fence_is_a_diagram() {
            const view = root.research({ blocks: [
                root.block("c1", "const a = 1;", { kind: "code", language: "js" }),
                root.block("c2", "flowchart LR\n  A --> B", { kind: "code" }),
                root.block("r1", "```js\nconst a = 1;\n```", { kind: "raw" }),
                root.block("r2", "Before\n```mermaid\nflowchart LR\n  A --> B\n```", { kind: "raw" }),
                root.block("p1", "```mermaid\nflowchart LR\n  A --> B\n```"),
                root.block("t1", "| mermaid |\n| --- |", { kind: "table" })
            ] });
            tryVerify(() => findChild(view, "spaceBlockText:| mermaid |\n| --- |"), 1000, "every block is on the page");
            // A paragraph is drawn as the chat's Markdown, where a fence is code.
            compare(Object.keys(Diagrams.asked), ["dark\nflowchart LR\n  A --> B"]);
        }

        function test_return_writes_an_edited_block_and_escape_drops_the_edit() {
            const view = root.research({});
            let editor = root.editorOf(view, "One");
            editor.selectAll();
            keyClick("X");
            keyClick(Qt.Key_Escape);
            compare(root.dispatched("space.block.update").length, 0);
            const shown = findChild(view, "spaceBlock:One");
            compare(shown.editor, null, "the block is drawn again");
            compare(findChild(shown, "spaceBlockText:One").text, "One");
            editor = root.editorOf(view, "One");
            compare(editor.text, "One");
            editor.selectAll();
            keyClick("F");
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.block.update"), [{ blockId: "b1", text: "F" }]);
        }

        // features/space/markdown.feature: Markdown a page keeps as written.
        function test_a_raw_block_is_its_source_and_return_starts_a_line_in_it() {
            const table = "| Step | Owner |\n| ---- | ----- |\n|   MC | Ada   |";
            const view = root.research({ blocks: [root.block("b1", table, { kind: "raw" })] });
            const editor = findChild(view, "spaceBlockEditor:" + table);
            compare(editor.text, table);
            compare(editor.wrapMode, TextEdit.NoWrap);
            compare(editor.textFormat, TextEdit.PlainText);
            editor.forceActiveFocus();
            editor.cursorPosition = editor.length;
            keyClick(Qt.Key_Return);
            keyClick("|");
            compare(root.dispatched("space.block.update").length, 0);
            keyClick(Qt.Key_Return, Qt.ControlModifier);
            compare(root.dispatched("space.block.update"), [{ blockId: "b1", text: table + "\n|" }]);
        }

        // features/space/markdown.feature, Tables and Code (#854): a table and
        // a code block are drawn as the chat draws them until they are edited,
        // then edited as their source.
        function test_a_table_is_drawn_as_a_grid_and_edited_as_its_source() {
            const table = "| Step | Owner | Done |\n| :--- | :---: | ---: |\n| **MC** | a \\| b | 3 |";
            const view = root.research({ blocks: [root.block("b1", table, { kind: "table" })] });
            tryVerify(() => findChild(view, "spaceBlockText:" + table) !== null);
            const shown = findChild(view, "spaceBlock:" + table);
            compare(shown.editor, null, "a drawn table holds no editor");
            const grid = findChild(findChild(shown, "spaceBlockText:" + table), "markdownTable");
            verify(grid !== null && grid.visible, "the table is a grid");
            compare(grid.spec.header.length, 3);
            compare(grid.spec.align, ["left", "center", "right"]);
            verify(/<(b|strong)>MC<\/(b|strong)>/.test(grid.spec.rows[0][0]), grid.spec.rows[0][0]);
            compare(grid.spec.rows[0][1], "a | b");

            // A click on a cell edits the table's source, line for line.
            mouseClick(grid, 20, 10);
            const editor = shown.editor;
            verify(editor !== null && editor.activeFocus);
            compare(editor.text, table);
            compare(editor.wrapMode, TextEdit.NoWrap);
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.block.update").length, 0, "Return starts a line");
            keyClick(Qt.Key_Escape);
            compare(shown.editor, null, "left, it is drawn again");
        }

        function test_a_code_block_is_drawn_as_code_and_copied_without_its_fence() {
            const code = "const a = 1;\n```\nnot the end";
            const view = root.research({ blocks: [root.block("b1", code, { kind: "code", language: "ts" })] });
            tryVerify(() => findChild(view, "spaceBlockText:" + code) !== null);
            const shown = findChild(view, "spaceBlock:" + code);
            const drawn = findChild(shown, "spaceBlockText:" + code);
            compare(drawn.text, "````ts\n" + code + "\n````", "a fence longer than the one it holds");
            const box = findChild(drawn, "markdownCode");
            verify(box !== null);
            compare(box.code, code);
            compare(findChild(box, "codeLabel").text, "ts");
            compare(findChild(box, "codeText").font.family, Theme.fontMono.length > 0 ? Theme.fontMono : "monospace");

            // Its copy is the brick's, and copying edits nothing.
            tryVerify(() => box.height > 30 && drawn.height >= box.height, 1000, "the code is laid out");
            mouseClick(findChild(box, "copyCode"));
            compare(shown.editor, null, "copying does not edit");
            pasteTarget.text = "";
            pasteTarget.paste();
            compare(pasteTarget.text, code);

            // Elsewhere edits the code, as before: Ctrl+Return writes it.
            mouseClick(findChild(box, "codeText"), 4, 4);
            const editor = shown.editor;
            verify(editor !== null && editor.activeFocus);
            compare(editor.text, code);
            compare(editor.font.family, Theme.fontMono.length > 0 ? Theme.fontMono : "monospace");
            editor.cursorPosition = editor.length;
            keyClick("!");
            keyClick(Qt.Key_Return, Qt.ControlModifier);
            compare(root.dispatched("space.block.update"), [{ blockId: "b1", text: code + "!" }]);
        }

        // Math stays the source the MC fences (a diagram its picture, above).
        function test_math_is_not_drawn_as_code() {
            const view = root.research({ blocks: [root.block("m1", "E = mc^2", { kind: "code", language: "math", markdownAbove: "$$", markdownBelow: "$$" })] });
            tryVerify(() => findChild(view, "spaceBlock:E = mc^2") !== null);
            const shown = findChild(view, "spaceBlock:E = mc^2");
            verify(shown.editor !== null, "math is its source");
            compare(findChild(shown, "spaceBlockText:E = mc^2"), null);
        }

        function test_a_scrolled_raw_block_comes_back_when_its_lines_get_shorter() {
            const long = "| " + "x".repeat(400) + " |";
            const view = root.research({ blocks: [root.block("b1", long, { kind: "raw" })] });
            const scroller = findChild(view, "spaceBlockScroll:" + long);
            verify(scroller.contentWidth > scroller.width);
            mouseWheel(scroller, 10, 10, -100000, 0);
            verify(scroller.contentX > 0);
            compare(scroller.contentX, scroller.contentWidth - scroller.width);
            // A wider page shows more of the line, and none of it past its end.
            const narrow = scroller.width;
            view.width += 300;
            tryVerify(() => scroller.width > narrow);
            tryCompare(scroller, "contentX", scroller.contentWidth - scroller.width);
            // Another client writes it shorter: the start of its lines shows again.
            Spaces.blocks.setProperty(0, "text", "| x |");
            tryCompare(scroller, "contentX", 0);
        }

        function test_headings_step_down_in_size_from_level_one() {
            const levels = [1, 2, 3, 4, 5, 6];
            const headings = levels.map(level => root.block("h" + level, "Level " + level, { kind: "heading", level: level }));
            const view = root.research({ blocks: headings.concat([root.block("h", "Plain", { kind: "heading" })]) });
            tryVerify(() => findChild(view, "spaceBlockText:Plain") !== null);
            const sizes = levels.map(level => findChild(view, "spaceBlockText:Level " + level).fontSize);
            for (let i = 1; i < sizes.length; ++i)
                verify(sizes[i] < sizes[i - 1], "level " + (i + 1) + " is smaller than level " + i + ": " + sizes);
            // Level 2 is the page's usual heading, and so is a heading with no level.
            compare(findChild(view, "spaceBlockText:Plain").fontSize, sizes[1]);
            // Its source is written at the size it is drawn.
            compare(root.editorOf(view, "Level 1").font.pixelSize, sizes[0]);
        }

        function test_what_the_user_is_writing_is_not_overwritten_by_the_stream() {
            const view = root.research({});
            const editor = root.editorOf(view, "One");
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

        // features/space/markdown.feature, Inline formatting: a text block is
        // drawn through the chat's Markdown brick, untrusted, until it is edited.
        function test_a_block_is_drawn_with_its_inline_formatting() {
            const source = "Ship **soon**, ~~later~~ with `mix test` and [the docs](https://example.com \"Docs\")";
            const view = root.research({ blocks: [root.block("b1", source)] });
            const shown = findChild(view, "spaceBlock:" + source);
            compare(shown.editor, null, "an idle block holds no editor");
            const drawn = findChild(shown, "spaceBlockText:" + source);
            verify(drawn.visible);
            verify(!drawn.trusted);
            const html = findChild(drawn, "markdownProse").text;
            verify(/<(b|strong)>soon<\/(b|strong)>/.test(html), html);
            verify(/<s>later<\/s>/.test(html), html);
            verify(/class="c"[^>]*>(<span[^>]*> <\/span>)?mix test</.test(html), "inline code: " + html);
            verify(html.includes("href=\"https://example.com\""), html);
            verify(!html.includes("**") && !html.includes("~~"), "no markers show: " + html);
        }

        // An image is a link to it, and nothing is fetched until it is followed.
        function test_a_link_in_a_block_never_loads_anything_by_itself() {
            const source = "![cat](https://example.com/cat.png)";
            const view = root.research({ blocks: [root.block("b1", source)] });
            const html = findChild(findChild(view, "spaceBlockText:" + source), "markdownProse").text;
            verify(!html.includes("<img"), html);
            verify(html.includes("href=\"https://example.com/cat.png\""), html);
            compare(Shell.openedExternally, []);
        }

        // features/space/markdown.feature, Lists: an item's further lines stay
        // in it, and a text the brick would read as no item (a rule of the
        // bullet's dashes, a quote, a table) is drawn after its marker in the lead.
        function test_an_item_keeps_text_that_reads_as_no_item() {
            const item = { kind: "bullet", markdownLead: "- " };
            const view = root.research({ blocks: [root.block("b1", "--", item), root.block("b2", "> quoted", item), root.block("b4", "\t> tabbed", item), root.block("b5", "Name | Age\n---|---", item), root.block("b6", "| just text", item), root.block("b3", "First\n\nSecond", item)] });
            tryVerify(() => findChild(view, "spaceBlock:First\n\nSecond") !== null);
            for (const text of ["--", "> quoted", "\t> tabbed", "Name | Age\n---|---"]) {
                const shown = findChild(view, "spaceBlock:" + text);
                compare(shown.marker, "", text);
                compare(findChild(shown, "spaceBlockText:" + text).text, text);
                compare(findChild(view, "spaceMarkdownLead:" + text).text, "- ", text);
            }
            // A pipe over no delimiter row is no table: the item is drawn.
            compare(findChild(view, "spaceBlock:| just text").marker, "- ");
            const both = findChild(view, "spaceBlock:First\n\nSecond");
            compare(both.marker, "- ");
            compare(findChild(both, "spaceBlockText:First\n\nSecond").text, "- First\n  \n  Second");
        }

        // A click on a link opens it as a link in the chat does; anywhere else
        // in the text edits its source, with the caret where it was clicked.
        function test_a_click_opens_a_link_and_elsewhere_edits_the_source() {
            const source = "[docs](https://example.com) and more words after it";
            const view = root.research({ blocks: [root.block("b1", source)] });
            const shown = findChild(view, "spaceBlock:" + source);
            const drawn = findChild(shown, "spaceBlockText:" + source);
            const prose = findChild(drawn, "markdownProse");
            const link = drawn.mapFromItem(prose, 4, prose.height / 2);
            compare(drawn.linkAt(link.x, link.y), "https://example.com");
            mouseClick(drawn, link.x, link.y);
            compare(Shell.openedExternally, ["https://example.com"]);
            compare(shown.editor, null, "a link is followed, not edited");

            mouseClick(drawn, prose.implicitWidth - 2, prose.height / 2);
            const editor = shown.editor;
            verify(editor !== null);
            verify(editor.activeFocus);
            compare(editor.text, source);
            compare(Shell.openedExternally, ["https://example.com"]);
            // Leaving it draws it again.
            editor.focus = false;
            compare(shown.editor, null);
            verify(findChild(shown, "spaceBlockText:" + source).visible);
        }

        // A link to a path or an anchor, which nothing opens, edits like any
        // text, and shows no hand.
        function test_a_link_nothing_opens_edits_the_source() {
            const source = "[spec](./spec.md) and more words after it";
            const view = root.research({ blocks: [root.block("b1", source)] });
            const shown = findChild(view, "spaceBlock:" + source);
            const drawn = findChild(shown, "spaceBlockText:" + source);
            const prose = findChild(drawn, "markdownProse");
            const link = drawn.mapFromItem(prose, 4, prose.height / 2);
            compare(drawn.linkAt(link.x, link.y), "./spec.md");
            mouseMove(drawn, link.x, link.y);
            compare(findChild(shown, "spaceBlockPointer").cursorShape, Qt.IBeamCursor);
            mouseClick(drawn, link.x, link.y);
            compare(Shell.openedExternally, []);
            verify(shown.editor !== null && shown.editor.activeFocus);
            compare(shown.editor.text, source);
        }

        // Where plain words are drawn as written, the caret lands on the word clicked.
        function test_the_caret_lands_where_the_drawn_text_was_clicked() {
            const source = "Plain words in a row";
            const view = root.research({ blocks: [root.block("b1", source)] });
            tryVerify(() => findChild(view, "spaceBlockText:" + source) !== null);
            const shown = findChild(view, "spaceBlock:" + source);
            const drawn = findChild(shown, "spaceBlockText:" + source);
            const prose = findChild(drawn, "markdownProse");
            const at = drawn.mapFromItem(prose, prose.implicitWidth - 2, prose.height / 2);
            mouseClick(drawn, at.x, at.y);
            verify(shown.editor.activeFocus);
            verify(shown.editor.cursorPosition >= source.length - 1, "the caret is at the click: " + shown.editor.cursorPosition);
        }

        // The keyboard reaching a drawn block edits it, the caret at its end.
        function test_focusing_a_drawn_block_edits_its_source() {
            const view = root.research({});
            tryVerify(() => findChild(view, "spaceBlock:Two") !== null);
            const shown = findChild(view, "spaceBlock:Two");
            findChild(shown, "spaceBlockText:Two").parent.forceActiveFocus();
            verify(shown.editor !== null && shown.editor.activeFocus);
            compare(shown.editor.cursorPosition, 3);
            keyClick("s");
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.block.update"), [{ blockId: "b2", text: "Twos" }]);
            compare(shown.editor, null);
        }

        // A ticked item is drawn struck out, a heading at its size.
        function test_a_ticked_item_is_drawn_struck_out() {
            const view = root.research({ blocks: [root.block("b1", "Ship *it*", { kind: "checklist", checked: true }), root.block("b2", "Plan", { kind: "heading", level: 1 })] });
            tryVerify(() => findChild(view, "spaceBlockText:Plan") !== null);
            verify(findChild(view, "spaceBlockText:Ship *it*").struck);
            verify(!findChild(view, "spaceBlockText:Plan").struck);
            compare(findChild(view, "spaceBlockText:Plan").fontWeight, Font.DemiBold);
        }

        // A page of hundreds of blocks: the ones drawn hold Text, no TextEdit,
        // until one is edited. Logs the time to lay the page out and scroll it.
        function test_a_long_page_draws_its_blocks_without_editors() {
            const blocks = [];
            for (let i = 0; i < 400; ++i)
                blocks.push(root.block("b" + i, "Block " + i + " has **bold**, `code` and [a link](https://example.com/" + i + ")", { kind: i % 10 === 0 ? "heading" : i % 7 === 0 ? "checklist" : "paragraph" }));
            const started = Date.now();
            const view = root.research({ blocks: blocks });
            const list = findChild(view, "spaceBlocks");
            tryVerify(() => list.count === 400);
            list.forceLayout();
            const laidOut = Date.now() - started;
            const editors = item => {
                let count = item.cursorRectangle !== undefined ? 1 : 0;
                for (const child of item.children)
                    count += editors(child);
                return count;
            };
            let seen = 0;
            const scrolled = Date.now();
            for (let at = 0; at < 400; at += 20) {
                list.positionViewAtIndex(at, ListView.Beginning);
                list.forceLayout();
                for (const child of list.contentItem.children) {
                    if (child.blockId === undefined)
                        continue;
                    ++seen;
                    compare(editors(child), 0, "block " + child.text + " holds no TextEdit");
                }
            }
            console.log("400-block page: laid out in " + laidOut + " ms, scrolled through in " + (Date.now() - scrolled) + " ms");
            verify(seen > 0);
        }

        function test_a_trashed_page_is_read_only_with_the_way_back() {
            const view = root.research({ page: { id: "page-1", title: "Roadmap", parentPageId: "", trashed: true, sourceThreadId: "", sourceThreadTitle: "" } });
            verify(findChild(view, "spaceTrashedBanner").visible);
            verify(!findChild(view, "spaceComposer").visible);
            verify(root.editorOf(view, "One").readOnly);
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

        // "Roadmap" as the file docs/roadmap.md of Shop (features/space/project-files.feature).
        function filed(file) {
            return Object.assign({ id: "page-1", title: "Roadmap", parentPageId: "", trashed: false, sourceThreadId: "", sourceThreadTitle: "",
                                   file: Object.assign({ projectId: "shop", projectTitle: "Shop", path: "docs/roadmap.md", missing: false, unwritten: false, conflictAt: "" }, file) });
        }

        function test_a_page_that_is_a_file_says_which_with_the_way_to_it() {
            const view = root.research({ page: filed({}) });
            verify(findChild(view, "spacePageFile").visible);
            compare(findChild(view, "spacePageFilePath").text, "The file docs/roadmap.md of Shop");
            compare(findChild(view, "spaceTrailSpace").text, "Shop");
            verify(!findChild(view, "spacePageFileGone").visible);
            verify(!findChild(view, "spacePageFileConflict").visible);
            mouseClick(findChild(view, "spacePageFileShow"));
            mouseClick(findChild(view, "spacePageActions"));
            verify(findChild(view, "spaceShowFile").visible);
            compare(Shell.dispatchedActions.map(entry => entry.action), ["space.page.showFile"]);
        }

        function test_an_ordinary_page_says_nothing_of_a_file() {
            const view = root.research();
            verify(!findChild(view, "spacePageFile").visible);
            mouseClick(findChild(view, "spacePageActions"));
            verify(!findChild(view, "spaceShowFile").visible);
        }

        // "shop" with Space files, as SpaceProjects lists it: collapsed, or open on its tree.
        function sections(expanded, more) {
            const rows = [{ id: "project:shop", kind: "project", projectId: "shop", path: "", name: "shop", depth: 0, expanded: expanded, pageId: "" }];
            if (expanded)
                rows.push({ id: "folder:shop:docs", kind: "folder", projectId: "shop", path: "docs", name: "docs", depth: 1, expanded: true, pageId: "" },
                          { id: "file:shop:docs/guide.md", kind: "file", projectId: "shop", path: "docs/guide.md", name: "guide.md", depth: 2, expanded: false, pageId: "page-9" },
                          { id: "file:shop:README.md", kind: "file", projectId: "shop", path: "README.md", name: "README.md", depth: 1, expanded: false, pageId: "" });
            return root.research(Object.assign({ projects: rows }, more));
        }

        function test_a_project_section_comes_after_the_spaces_pages_and_expands_on_a_click() {
            const view = sections(false);
            const list = findChild(view, "spaceProjects");
            verify(list.visible);
            tryVerify(() => findChild(view, "spaceProject:shop") !== null);
            // The layout gives the list its height a polish after the header exists.
            tryVerify(() => list.height >= findChild(view, "spaceProject:shop").height);
            const tree = findChild(view, "spacePageTree");
            verify(list.mapToItem(view, 0, 0).y >= tree.mapToItem(view, 0, 0).y + tree.height);
            verify(findChild(view, "spaceProjectFile:shop:README.md") === null);
            mouseClick(findChild(view, "spaceProject:shop"));
            compare(dispatched("space.project.setExpanded"), [{ projectId: "shop", expanded: true }]);
        }

        function test_an_expanded_section_shows_its_files_by_folder_and_collapses_on_a_click() {
            const view = sections(true);
            tryVerify(() => findChild(view, "spaceProjectFile:shop:README.md") !== null);
            const folder = findChild(view, "spaceProjectFolder:shop:docs");
            const guide = findChild(view, "spaceProjectFile:shop:docs/guide.md");
            verify(guide.y > folder.y);
            verify(findChild(view, "spaceProjectFile:shop:README.md").y > guide.y);
            mouseClick(findChild(view, "spaceProject:shop"));
            compare(dispatched("space.project.setExpanded"), [{ projectId: "shop", expanded: false }]);
        }

        function test_a_folder_in_a_section_folds_on_a_click() {
            const view = sections(true);
            tryVerify(() => findChild(view, "spaceProjectFolder:shop:docs") !== null);
            const folder = findChild(view, "spaceProjectFolder:shop:docs");
            compare(folder.Accessible.name, "Collapse docs");
            mouseClick(folder);
            compare(dispatched("space.project.setExpanded"), [{ projectId: "shop", path: "docs", expanded: false }]);
            compare(dispatched("space.openFile"), []);
        }

        function test_a_section_and_a_folder_fold_from_the_keyboard() {
            const view = sections(true);
            tryVerify(() => findChild(view, "spaceProjectFolder:shop:docs") !== null);
            const folder = findChild(view, "spaceProjectFolder:shop:docs");
            folder.forceActiveFocus();
            keyClick(Qt.Key_Right);
            compare(dispatched("space.project.setExpanded"), []);
            keyClick(Qt.Key_Left);
            compare(dispatched("space.project.setExpanded"), [{ projectId: "shop", path: "docs", expanded: false }]);
            Shell.dispatchedActions = [];
            findChild(view, "spaceProject:shop").forceActiveFocus();
            keyClick(Qt.Key_Space);
            compare(dispatched("space.project.setExpanded"), [{ projectId: "shop", expanded: false }]);
            Shell.dispatchedActions = [];
            findChild(view, "spaceProjectFile:shop:README.md").forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(dispatched("space.openFile"), [{ projectId: "shop", relativePath: "README.md" }]);
        }

        function test_a_file_in_a_section_is_edited_as_a_page_and_shows_as_chosen() {
            const view = sections(true);
            tryVerify(() => findChild(view, "spaceProjectFile:shop:README.md") !== null);
            mouseClick(findChild(view, "spaceProjectFile:shop:README.md"));
            compare(dispatched("space.openFile"), [{ projectId: "shop", relativePath: "README.md" }]);
            verify(!findChild(view, "spaceProjectFile:shop:docs/guide.md").selected);
            Spaces.fileSpaceId = "project-space-shop";
            Spaces.pageId = "page-9";
            verify(findChild(view, "spaceProjectFile:shop:docs/guide.md").selected);
        }

        function test_no_project_has_space_files_and_no_section_shows() {
            const view = root.research();
            verify(!findChild(view, "spaceProjects").visible);
        }

        function test_a_page_whose_file_is_gone_says_so_and_whether_it_was_edited_since() {
            const view = root.research({ page: filed({ missing: true }) });
            const gone = findChild(view, "spacePageFileGone");
            verify(gone.visible);
            verify(!findChild(view, "spacePageFileShow").visible);
            const untouched = gone.text;
            Spaces.page = filed({ missing: true, unwritten: true });
            verify(gone.text !== untouched);
            verify(gone.text.indexOf("it wins") >= 0);
        }

        function test_a_file_that_won_over_an_edit_says_so_with_the_way_to_the_history() {
            const view = root.research({ page: filed({ conflictAt: "2026-09-23T10:20:00Z" }) });
            verify(findChild(view, "spacePageFileConflict").visible);
            mouseClick(findChild(view, "spacePageFileHistory"));
            compare(dispatched("space.history.open"), [{ pageId: "page-1" }]);
        }

        function picking(listed) {
            Shell.state = Object.assign({}, Shell.state, { space: {
                picking: "shop",
                projects: [{ id: "shop", title: "Shop" }, { id: "docs", title: "Docs" }],
                files: listed === undefined ? {} : { shop: listed }
            } });
            return root.research();
        }

        function test_the_file_picker_lists_the_projects_files_and_opens_one() {
            const view = picking({ config: "default", paths: {
                "docs/roadmap.md": { kind: "markdown", spaceId: "space-1", pageId: "page-1", title: "Roadmap" },
                "README.md": { kind: "markdown", spaceId: "", pageId: "", title: "" }
            } });
            const picker = findChild(view, "spaceFilePicker");
            tryVerify(() => picker.opened);
            compare(findChild(picker.contentItem, "spaceFilePickerProject").text, "Shop");
            tryVerify(() => findChild(picker.contentItem, "spaceFilePickerFile:docs/roadmap.md") !== null);
            const opened = findChild(picker.contentItem, "spaceFilePickerFile:docs/roadmap.md");
            compare(opened.text, "docs/roadmap.md (the page Roadmap)");
            mouseClick(findChild(picker.contentItem, "spaceFilePickerFile:README.md"));
            compare(dispatched("space.openFile"), [{ projectId: "shop", relativePath: "README.md" }]);
        }

        function test_the_file_picker_says_when_a_project_has_no_files_and_offers_the_scan() {
            const view = picking({ config: "default", paths: {} });
            const picker = findChild(view, "spaceFilePicker");
            tryVerify(() => picker.opened);
            const empty = findChild(picker.contentItem, "spaceFilePickerEmpty");
            verify(empty.visible);
            verify(empty.text.indexOf("Shop has no files") === 0);
            mouseClick(findChild(picker.contentItem, "spaceFilePickerScan"));
            compare(dispatched("space.files.scan"), [{ projectId: "shop" }]);
            picker.close();
            compare(dispatched("space.files.pickClose"), [{}]);
        }

        function test_the_file_picker_says_why_a_refused_list_has_no_files() {
            const view = picking({ config: "", paths: {}, error: "The project could not be read." });
            const picker = findChild(view, "spaceFilePicker");
            tryVerify(() => picker.opened);
            const empty = findChild(picker.contentItem, "spaceFilePickerEmpty");
            verify(empty.visible);
            compare(empty.text, "The files of Shop could not be listed: The project could not be read.");
            picker.close();
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
                comments: [{ id: "c1", blockId: "b2", blockText: "Two", blockGone: false, body: "Which week?", resolved: false, byAgent: false, createdAt: "" },
                           { id: "c2", blockId: "b2", blockText: "Two", blockGone: false, body: "Done", resolved: true, byAgent: true, createdAt: "" }]
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
            const empty = findChild(view, "spaceEmpty");
            compare(empty.title, "Research has no pages yet");
            mouseClick(findChild(empty, "emptyStateAction"));
            const field = findChild(view, "spaceNameField");
            verify(field.visible);
            keyClick("R");
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.page.create"), [{ title: "R", parentPageId: "", link: false }]);
        }

        function test_a_subpage_made_from_the_link_menu_is_linked() {
            const view = root.research({});
            findChild(view, "spaceComposer").focusInput();
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
            const empty = findChild(view, "spaceEmpty");
            compare(empty.status, "error");
            compare(empty.description, "The MC cannot be reached. Its Spaces show again once it answers.");
            verify(!findChild(empty, "emptyStateAction").visible);
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

        // The controller sends an ask (ComposerController::submitPage); the page writes no block.
        function test_the_prompt_sends_an_ask_and_writes_no_block() {
            const view = root.research({});
            findChild(view, "spaceComposer").focusInput();
            for (const key of "@agent tidy")
                keyClick(key);
            keyClick(Qt.Key_Return);
            compare(root.dispatched("composer.submit").map(entry => entry.text), ["@agent tidy"]);
            compare(root.dispatched("space.block.insert"), []);
        }

        function test_an_ask_says_the_project_it_runs_in_and_can_change_it() {
            const view = root.research({});
            const project = findChild(view, "spaceAskProject");
            const kind = findChild(view, "spaceNewKind");
            verify(!project.visible);
            verify(kind.visible);
            findChild(view, "spaceComposer").focusInput();
            for (const key of "@agent ")
                keyClick(key);
            tryVerify(() => project.visible);
            verify(!kind.visible);
            compare(project.text, "shop");
            // The row of actions places the button once it shows.
            waitForPolish(project.parent);
            mouseClick(project);
            const menu = findChild(view, "spaceAskProjectMenu");
            tryVerify(() => menu.opened && menu.count === 2);
            menu.itemAt(1).triggered();
            compare(root.dispatched("composer.project.set"), [{ projectId: "docs" }]);
        }

        function test_a_word_that_only_starts_like_the_mention_is_a_block() {
            const view = root.research({});
            findChild(view, "spaceComposer").focusInput();
            for (const key of "@agents")
                keyClick(key);
            verify(!findChild(view, "spaceAskProject").visible);
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.block.insert").length, 1);
        }

        // The page's menu starts an ask from what is typed; the controller puts `@agent` ahead of it.
        function test_the_page_menu_starts_an_ask_from_the_draft() {
            const view = root.research({});
            const composer = findChild(view, "spaceComposer");
            composer.editor.text = "the plan";
            findChild(view, "spaceAskAgent").triggered();
            compare(root.dispatched("composer.ask").length, 1);
            compare(Shell.state.composer.text, "the plan");
            const actions = Shell.dispatchedActions.map(entry => entry.action);
            verify(actions.lastIndexOf("composer.text.set") < actions.indexOf("composer.ask"));
        }

        function test_words_the_controller_sends_back_are_written() {
            const view = root.research({});
            Shell.actionRequested("space.prompt.write", { pageId: "page-1", text: "Ship" });
            compare(root.dispatched("space.block.insert").map(entry => entry.text), ["Ship"]);
            Shell.actionRequested("space.prompt.write", { pageId: "page-9", text: "Elsewhere" });
            compare(root.dispatched("space.block.insert").length, 1);
        }

        function test_a_working_agent_can_be_followed_and_stopped() {
            const view = root.research({ agent: { status: "running", request: "tidy this", threadId: "t9" } });
            compare(findChild(view, "spaceAgentText").text, "An agent is working on “tidy this”.");
            verify(!findChild(view, "spaceAgentDismiss").visible);
            mouseClick(findChild(view, "spaceAgentStop"));
            compare(root.dispatched("space.agent.stop").length, 1);
            mouseClick(findChild(view, "spaceAgentOpenThread"));
            compare(root.dispatched("space.agent.openThread").length, 1);
        }

        function test_a_stopping_agent_can_be_stopped_again() {
            const view = root.research({ agent: { status: "stopping", request: "tidy", threadId: "t9" } });
            compare(findChild(view, "spaceAgentText").text, "Stopping the agent…");
            mouseClick(findChild(view, "spaceAgentStop"));
            compare(root.dispatched("space.agent.stop").length, 1);
            verify(findChild(view, "spaceAgentOpenThread").visible);
        }

        function test_an_ended_agent_says_how_and_can_be_dismissed() {
            const says = [
                [{ status: "completed", edited: true }, "The agent finished and changed this page."],
                [{ status: "completed", edited: false }, "The agent finished without changing this page."],
                [{ status: "stopped" }, "The agent was stopped."],
                [{ status: "stopped", error: "its thread was deleted" }, "The agent stopped: its thread was deleted."],
                [{ status: "stopped", error: "It was cut off.\n" }, "The agent stopped: It was cut off."],
                [{ status: "failed", error: "The agent's turn failed." }, "The agent failed: The agent's turn failed. The page stays as it last wrote it."],
                [{ status: "failed", error: "out of credits" }, "The agent failed: out of credits. The page stays as it last wrote it."]
            ];
            const view = root.research({});
            for (const [agent, text] of says) {
                Spaces.agent = Object.assign({ request: "tidy", threadId: "t9" }, agent);
                compare(findChild(view, "spaceAgentText").text, text);
                verify(!findChild(view, "spaceAgentStop").visible);
                verify(findChild(view, "spaceAgentHistory").visible);
                mouseClick(findChild(view, "spaceAgentDismiss"));
            }
            compare(root.dispatched("space.agent.dismiss").length, says.length);
        }

        function test_a_page_with_no_agent_says_nothing() {
            const view = root.research({});
            verify(!findChild(view, "spaceAgentStrip").visible);
        }

        function update(more) {
            return { schedule: Object.assign({ instruction: "Summarise", cadence: { type: "interval", everyMs: 7200000 }, cadenceLabel: "Every 2 hours", enabled: true, nextRunAt: "2026-11-01T09:00:00.000Z", lastRunStatus: "never" }, more), writtenAt: "" };
        }

        function pageWith(fields) {
            return { page: Object.assign({ id: "page-1", title: "Roadmap", parentPageId: "", trashed: false, sourceThreadId: "", sourceThreadTitle: "" }, fields) };
        }

        function test_a_page_without_an_update_shows_none() {
            const view = root.research({});
            verify(!findChild(view, "spacePageUpdate").visible);
            compare(findChild(view, "spaceUpdateMenu").text, "Update itself…");
        }

        function test_the_update_says_what_it_does_and_when() {
            const view = root.research(pageWith(update({})));
            verify(findChild(view, "spacePageUpdate").visible);
            compare(findChild(view, "spaceUpdateSays").text, "Summarise");
            verify(findChild(view, "spaceUpdateWhen").text.startsWith("Every 2 hours, next run "));
            compare(findChild(view, "spaceUpdateWritten").text, "Not written yet");
            verify(!findChild(view, "spaceUpdateFailure").visible);
            compare(findChild(view, "spaceUpdateMenu").text, "Change its update…");
        }

        function test_the_update_is_run_paused_and_removed_from_the_page() {
            const view = root.research(pageWith(update({})));
            mouseClick(findChild(view, "spaceUpdateRun"));
            compare(dispatched("space.page.schedule.runNow"), [{ pageId: "page-1" }]);
            mouseClick(findChild(view, "spaceUpdatePause"));
            compare(dispatched("space.page.schedule.setEnabled"), [{ pageId: "page-1", enabled: false }]);
            mouseClick(findChild(view, "spaceUpdateRemove"));
            compare(dispatched("space.page.schedule.remove"), [{ pageId: "page-1" }]);
        }

        function test_a_paused_update_says_so_and_offers_to_resume() {
            const view = root.research(pageWith(update({ enabled: false, nextRunAt: null })));
            compare(findChild(view, "spaceUpdateWhen").text, "Every 2 hours, paused");
            compare(findChild(view, "spaceUpdatePause").text, "Resume");
            mouseClick(findChild(view, "spaceUpdatePause"));
            compare(dispatched("space.page.schedule.setEnabled"), [{ pageId: "page-1", enabled: true }]);
        }

        function test_a_run_under_way_cannot_be_started_again() {
            const view = root.research(pageWith(update({ lastRunStatus: "running" })));
            compare(findChild(view, "spaceUpdateWritten").text, "Writing now…");
            verify(!findChild(view, "spaceUpdateRun").enabled);
        }

        function test_a_failed_run_shows_on_the_page() {
            const view = root.research(pageWith(update({ lastRunStatus: "failed", lastRunError: "the model is overloaded" })));
            compare(findChild(view, "spaceUpdateFailure").text, "Last run failed: the model is overloaded");
            verify(findChild(view, "spaceUpdateFailure").visible);
        }

        function test_a_trashed_page_shows_its_update_stopped_and_offers_nothing() {
            const view = root.research(pageWith(Object.assign(update({ nextRunAt: null }), { trashed: true })));
            verify(findChild(view, "spaceUpdateWhen").text.includes("stopped while this page is in the trash"));
            verify(!findChild(view, "spaceUpdateRun").visible);
            verify(!findChild(view, "spaceUpdateMenu").enabled);
        }

        function test_the_dialog_writes_an_interval_and_needs_an_instruction() {
            const view = root.research({});
            const dialog = findChild(view, "spaceUpdateDialog");
            dialog.ask();
            tryVerify(() => dialog.opened);
            verify(!findChild(dialog, "spaceUpdateSave").enabled);
            findChild(dialog, "spaceUpdateInstruction").text = " Summarise ";
            verify(findChild(dialog, "spaceUpdateSave").enabled);
            findChild(dialog, "spaceUpdateEvery").text = "0";
            verify(!findChild(dialog, "spaceUpdateSave").enabled);
            findChild(dialog, "spaceUpdateEvery").text = "3";
            mouseClick(findChild(dialog, "spaceUpdateSave"));
            compare(dispatched("space.page.schedule.set"), [{ pageId: "page-1", instruction: "Summarise", cadence: { type: "interval", everyMs: 10800000 } }]);
            tryVerify(() => !dialog.visible);
        }

        function test_the_dialog_writes_a_time_of_day_and_starts_from_what_the_page_has() {
            const view = root.research(pageWith(update({ cadence: { type: "fixed_time", timeOfDay: "07:30", weekdays: [1, 3] } })));
            const dialog = findChild(view, "spaceUpdateDialog");
            dialog.ask();
            tryVerify(() => dialog.opened);
            compare(findChild(dialog, "spaceUpdateInstruction").text, "Summarise");
            compare(findChild(dialog, "spaceUpdateMode").currentIndex, 0);
            compare(findChild(dialog, "spaceUpdateTime").text, "07:30");
            findChild(dialog, "spaceUpdateTime").text = "25:00";
            verify(!findChild(dialog, "spaceUpdateSave").enabled);
            findChild(dialog, "spaceUpdateTime").text = "09:15";
            mouseClick(findChild(dialog, "spaceUpdateSave"));
            compare(dispatched("space.page.schedule.set"), [{ pageId: "page-1", instruction: "Summarise", cadence: { type: "fixed_time", timeOfDay: "09:15", weekdays: [1, 3] } }]);
        }

        function test_the_dialog_starts_from_an_interval_in_minutes() {
            const view = root.research(pageWith(update({ cadence: { type: "interval", everyMs: 900000 } })));
            const dialog = findChild(view, "spaceUpdateDialog");
            dialog.ask();
            tryVerify(() => dialog.opened);
            compare(findChild(dialog, "spaceUpdateEvery").text, "15");
            compare(findChild(dialog, "spaceUpdateUnit").currentIndex, 1);
        }

        function test_the_generated_part_shows_as_markdown_and_cannot_be_edited() {
            const view = root.research({ blocks: [root.block("b1", "Mine"), root.block("b2", "Three **threads**", { kind: "generated" })] });
            tryVerify(() => findChild(view, "spaceBlock:Three **threads**") !== null);
            const generated = findChild(view, "spaceBlock:Three **threads**");
            verify(!root.showing(generated, "spaceBlockEditor:Three **threads**"));
            tryVerify(() => findChild(generated, "spaceGenerated") !== null);
            compare(findChild(generated, "spaceGenerated").text, "Three **threads**");
            verify(findChild(view, "spaceBlockText:Mine").visible);
            // It can still be moved, deleted and commented on.
            verify(findChild(generated, "spaceDeleteBlock:Three **threads**").visible);
            verify(findChild(generated, "spaceComment:Three **threads**") !== null);
        }

        function test_an_image_block_is_placed_from_the_spaces_images() {
            const view = root.research({ images: [root.imageRow("image-1", "cat.png")] });
            findChild(view, "spaceComposer").focusInput();
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

        function test_nobodyElseTakesNoRoom() {
            const view = root.research({ viewers: { devices: [], agents: [] } });
            verify(!findChild(view, "spaceViewers").visible);
        }

        function test_whoElseIsOnThePageIsNamed() {
            const view = root.research({ viewers: { devices: ["HAL-C2 on SM-F741B"], agents: ["Work"] } });
            const viewers = findChild(view, "spaceViewers");
            verify(viewers.visible);
            compare(viewers.text, "Also here: HAL-C2 on SM-F741B, the agent of “Work”");
        }
    }
}
