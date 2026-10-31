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
        return Object.assign({ id: id, kind: "paragraph", text: text, checked: false, linkedPageId: "", linkedTitle: "", byAgent: false, openComments: 0 }, more);
    }

    function pageRow(id, title, depth, parentPageId) {
        return { id: id, title: title, depth: depth, parentPageId: parentPageId, hasChildren: false, fromThread: false };
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
            compare(root.dispatched("space.slide.update")[0], { slideId: "s1", title: "First" });
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

        function test_a_page_from_a_thread_names_its_thread() {
            const view = root.research({ page: { id: "page-1", title: "Roadmap", parentPageId: "", trashed: false, sourceThreadId: "t1", sourceThreadTitle: "Work" } });
            const source = findChild(view, "spacePageSource");
            verify(source.visible);
            compare(source.text, "Made from the thread “Work”");
        }
    }
}
