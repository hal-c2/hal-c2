import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/space/pages.feature and slides.feature: what the Space view asks of
// SpaceController as the user writes a page or a deck, and what it shows of the
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
            composer.forceActiveFocus();
            keyClick("/");
            keyClick("c");
            keyClick("h");
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
