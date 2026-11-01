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
            verify(!findChild(generated, "spaceBlockEditor:Three **threads**").visible);
            tryVerify(() => findChild(generated, "spaceGenerated") !== null);
            compare(findChild(generated, "spaceGenerated").text, "Three **threads**");
            verify(findChild(view, "spaceBlockEditor:Mine").visible);
            // It can still be moved, deleted and commented on.
            verify(findChild(generated, "spaceDeleteBlock:Three **threads**").visible);
            verify(findChild(generated, "spaceComment:Three **threads**") !== null);
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
