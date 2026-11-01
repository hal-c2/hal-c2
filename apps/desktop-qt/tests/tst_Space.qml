import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/space/pages.feature: what the Space view asks of SpaceController
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

        // "Roadmap" with its history open: "Final" now, "Draft" before it.
        function withHistory(more) {
            const versions = [
                { id: "12", version: 12, at: "2026-09-23T10:10:00Z", byAgent: true, threadTitle: "Work", restoredFromAt: "" },
                { id: "7", version: 7, at: "2026-09-23T10:00:00Z", byAgent: false, threadTitle: "", restoredFromAt: "" }
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
                    { id: "12", version: 12, at: "2026-09-23T10:10:00Z", byAgent: false, threadTitle: "", restoredFromAt: "" },
                    { id: "7", version: 7, at: "2026-09-23T10:00:00Z", byAgent: false, threadTitle: "", restoredFromAt: "" }
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
            const view = root.research({ comments: [{ id: "c1", blockId: "gone", blockText: "", body: "Why?", resolved: false, byAgent: false, createdAt: "" }] });
            view.commentsShown = true;
            const row = findChild(view, "spaceCommentRow:Why?");
            verify(row.blockGone);
        }

        function test_a_comment_on_the_page_itself_has_lost_no_block() {
            const view = root.research({ comments: [{ id: "c1", blockId: "", blockText: "", body: "Why?", resolved: false, byAgent: false, createdAt: "" }] });
            view.commentsShown = true;
            verify(!findChild(view, "spaceCommentRow:Why?").blockGone);
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

        function test_the_composer_asks_an_agent_and_writes_no_block() {
            const view = root.research({});
            findChild(view, "spaceComposer").forceActiveFocus();
            for (const key of "@agent tidy")
                keyClick(key);
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.agent.ask"), [{ pageId: "page-1", request: "@agent tidy" }]);
            compare(root.dispatched("space.block.insert"), []);
            compare(findChild(view, "spaceComposer").text, "@agent tidy");
            Spaces.agentAskAnswered("page-1", "@agent tidy", true);
            compare(findChild(view, "spaceComposer").text, "");
        }

        function test_an_ask_the_mc_refuses_keeps_its_words() {
            const view = root.research({});
            findChild(view, "spaceComposer").forceActiveFocus();
            for (const key of "@agent tidy")
                keyClick(key);
            keyClick(Qt.Key_Return);
            Spaces.agentAskAnswered("page-1", "@agent tidy", false);
            compare(findChild(view, "spaceComposer").text, "@agent tidy");
        }

        function test_words_changed_while_an_ask_is_answered_are_kept() {
            const view = root.research({});
            findChild(view, "spaceComposer").forceActiveFocus();
            for (const key of "@agent tidy")
                keyClick(key);
            keyClick(Qt.Key_Return);
            keyClick("!");
            Spaces.agentAskAnswered("page-1", "@agent tidy", true);
            compare(findChild(view, "spaceComposer").text, "@agent tidy!");
        }

        function test_a_word_that_only_starts_like_the_mention_is_a_block() {
            const view = root.research({});
            findChild(view, "spaceComposer").forceActiveFocus();
            for (const key of "@agents")
                keyClick(key);
            keyClick(Qt.Key_Return);
            compare(root.dispatched("space.agent.ask"), []);
            compare(root.dispatched("space.block.insert").length, 1);
        }

        function test_an_ask_the_page_cannot_take_yet_keeps_its_words() {
            const view = root.research({ agent: { status: "running", request: "tidy", threadId: "t9" } });
            const composer = findChild(view, "spaceComposer");
            composer.forceActiveFocus();
            for (const key of "@agent more")
                keyClick(key);
            keyClick(Qt.Key_Return);
            compare(composer.text, "@agent more");
        }

        function test_the_way_in_starts_the_words_of_an_ask() {
            const view = root.research({});
            Spaces.agentAskRequested();
            const composer = findChild(view, "spaceComposer");
            compare(composer.text, "@agent ");
            verify(composer.activeFocus);
        }

        function test_the_way_in_keeps_a_draft() {
            const view = root.research({});
            const composer = findChild(view, "spaceComposer");
            composer.text = "the plan";
            Spaces.agentAskRequested();
            compare(composer.text, "@agent the plan");
            compare(composer.cursorPosition, "@agent ".length);
            Spaces.agentAskRequested();
            compare(composer.text, "@agent the plan");
            verify(composer.activeFocus);
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

        function test_a_page_from_a_thread_names_its_thread() {
            const view = root.research({ page: { id: "page-1", title: "Roadmap", parentPageId: "", trashed: false, sourceThreadId: "t1", sourceThreadTitle: "Work" } });
            const source = findChild(view, "spacePageSource");
            verify(source.visible);
            compare(source.text, "Made from the thread “Work”");
        }
    }
}
