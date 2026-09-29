import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// The centre for thread and draft routes over a ListModel with the
// TimelineModel's roles (features/desktop/centre-view.feature, by scenario).
Item {
    id: root
    width: 700
    height: 500

    function row(fields) {
        return Object.assign({
            rowId: "",
            kind: "message",
            author: "assistant",
            text: "",
            streaming: false,
            title: "",
            status: "",
            statusLabel: "",
            marker: "",
            entries: [],
            hiddenCount: 0,
            expanded: false,
            files: []
        }, fields);
    }

    ListModel {
        id: rows
        property string status: "live"
        property string problem: ""
        property var copies: []
        function checkpointOf(rowId) {
            return rowId === "reply:1" ? {
                checkpointId: "checkpoint-1",
                scopeId: "scope-1",
                turn: 1
            } : {};
        }
        function copy(rowId) {
            copies = copies.concat([rowId]);
            return true;
        }
    }

    Component {
        id: viewComponent
        ThreadView {
            width: 700
            height: 500
        }
    }

    TestCase {
        name: "ThreadView"
        when: windowShown

        function init() {
            Shell.reset();
            Threads.reset();
            rows.clear();
            rows.status = "live";
            rows.problem = "";
            rows.copies = [];
        }

        function route(kind) {
            Shell.state = Object.assign({}, Shell.state, {
                route: {
                    kind: kind,
                    threadId: "thread-1"
                }
            });
        }

        function openThread() {
            Threads.activeThread = "env-1:thread-1";
            Threads.timeline = rows;
            route("thread");
            return createTemporaryObject(viewComponent, root);
        }

        function placeholder(view) {
            return findChild(view, "threadPlaceholder");
        }

        function visibleIn(item) {
            for (let current = item; current; current = current.parent) {
                if (!current.visible)
                    return false;
            }
            return item !== null;
        }

        function list(view) {
            const timeline = findChild(view, "threadTimeline");
            for (let i = 0; i < timeline.children.length; ++i) {
                if (timeline.children[i].contentY !== undefined)
                    return timeline.children[i];
            }
            return null;
        }

        function findNamed(item, name) {
            if (!item)
                return null;
            if (item.objectName === name)
                return item;
            for (let i = 0; i < item.children.length; ++i) {
                const found = findNamed(item.children[i], name);
                if (found)
                    return found;
            }
            return null;
        }

        function dispatched(action) {
            return Shell.dispatchedActions.filter(entry => entry.action === action);
        }

        // A thread whose first turn's reply has a checkpoint.
        function answeredThread() {
            rows.append(root.row({
                rowId: "message:1",
                author: "user",
                text: "Add a tax line to the cart"
            }));
            rows.append(root.row({
                rowId: "reply:1",
                text: "The cart adds tax now.",
                files: [
                    {
                        path: "src/cart.ts",
                        additions: 3,
                        deletions: 1
                    }
                ]
            }));
            rows.append(root.row({
                rowId: "work:1",
                kind: "work",
                entries: [
                    {
                        id: "file:1",
                        label: "Edited cart.ts",
                        path: "src/cart.ts",
                        detail: "+ const tax = 0.2;"
                    }
                ]
            }));
            const view = openThread();
            const timeline = list(view);
            tryVerify(() => timeline.count === 3 && timeline.itemAtIndex(1) !== null && timeline.itemAtIndex(2) !== null);
            return view;
        }

        function test_aThreadOrDraftRouteShowsTheConversationInThePagesPlace() {
            rows.append(root.row({
                rowId: "reply:1",
                text: "The cart adds tax now."
            }));
            const view = openThread();
            verify(visibleIn(findChild(view, "threadTimeline")), "the thread's conversation is shown");
            verify(!visibleIn(placeholder(view)), "nothing covers the conversation");
            // Which routes take the page's place is centreViews.js; that
            // the page hides and shows again with them is tst_ShellExamples.
        }

        function test_aThreadSaysItIsLoadingWithoutMoving() {
            rows.status = "loading";
            const view = openThread();
            compare(placeholder(view).text, "Loading…");
            verify(visibleIn(placeholder(view)));
            // A thread the store has not opened yet loads too.
            Threads.timeline = null;
            compare(placeholder(view).text, "Loading…");
        }

        function test_aThreadWithoutMessagesSaysHowToStart() {
            const view = openThread();
            compare(placeholder(view).text, "Send a message to start the conversation.");
            verify(visibleIn(placeholder(view)));
        }

        function test_aNewThreadsDraftSaysWhereItWillRun() {
            Shell.state = Object.assign({}, Shell.state, {
                workspace: {
                    projectTitle: "shop",
                    envModeLabel: "New worktree",
                    branch: "main"
                }
            });
            route("draft");
            const view = createTemporaryObject(viewComponent, root);
            compare(placeholder(view).text, "What should we build in shop?");
            compare(findChild(view, "draftContext").text, "New worktree · main");
            verify(!visibleIn(findChild(view, "threadTimeline")), "a draft has no conversation yet");
        }

        function test_aThreadWhoseNodeCannotBeReachedOffersARetry() {
            rows.status = "unreachable";
            rows.problem = "stream closed";
            const view = openThread();
            const problem = findChild(view, "threadProblem");
            verify(visibleIn(problem));
            verify(findText(problem, "This thread's node cannot be reached: stream closed") !== null);
            mouseClick(findChild(view, "threadRetry"));
            compare(Threads.reloads, ["env-1:thread-1"]);
        }

        function test_linksInAReplyLeadWhereTheyPoint_data() {
            return [
                {
                    tag: "a project path",
                    link: "src/cart.ts#L12",
                    path: "src/cart.ts",
                    line: 12,
                    external: ""
                },
                {
                    tag: "a file url",
                    link: "file:///work/shop/a.ts:7:3",
                    path: "/work/shop/a.ts",
                    line: 7,
                    external: ""
                },
                {
                    tag: "a web address",
                    link: "https://example.com/docs",
                    path: "",
                    external: "https://example.com/docs"
                }
            ];
        }

        function test_linksInAReplyLeadWhereTheyPoint(data) {
            const view = openThread();
            let external = "";
            view.openExternally = url => external = url;
            findChild(view, "threadTimeline").linkActivated(data.link);
            const opened = dispatched("panel.open");
            if (data.path.length > 0) {
                compare(opened.length, 1);
                compare(opened[0].payload.tab, "files");
                compare(opened[0].payload.path, data.path);
                compare(opened[0].payload.line, data.line);
            } else {
                compare(opened.length, 0, "nothing opens in the right panel");
            }
            compare(external, data.external);
        }

        function test_aFileATurnChangedOpensInTheRightPanel() {
            const view = answeredThread();
            const timeline = list(view);
            mouseClick(findNamed(timeline.itemAtIndex(1), "changedFile"));
            let opened = dispatched("panel.open");
            compare(opened.length, 1);
            compare(opened[0].payload.tab, "diff");
            compare(opened[0].payload.path, "src/cart.ts");
            compare(opened[0].payload.turn, 1, "on the reply's turn");
            mouseClick(findNamed(timeline.itemAtIndex(2), "openFile"));
            opened = dispatched("panel.open");
            compare(opened.length, 2);
            compare(opened[1].payload.tab, "files");
            compare(opened[1].payload.path, "src/cart.ts");
            const details = findText(timeline.itemAtIndex(2), "+ const tax = 0.2;");
            verify(details !== null);
            verify(!visibleIn(details), "opening the file leaves the call's details closed");
        }

        function hoverReply(view) {
            const reply = list(view).itemAtIndex(1);
            mouseMove(reply, 20, 10);
            const revert = findNamed(reply, "revertToTurn");
            tryVerify(() => revert.visible, 2000, "hovering a reply offers its revert");
            // The actions line lays the revert out after Copy.
            waitForItemPolished(revert.parent);
            return reply;
        }

        function test_theUserCopiesAMessage() {
            const view = answeredThread();
            const reply = hoverReply(view);
            mouseClick(findNamed(reply, "copyMessage"));
            compare(rows.copies, ["reply:1"]);
        }

        function test_revertingAsksFirst() {
            const view = answeredThread();
            mouseClick(findNamed(hoverReply(view), "revertToTurn"));
            const dialog = findChild(view, "revertDialog");
            tryVerify(() => dialog.opened);
            compare(dialog.title, "Revert to turn 1?");
            compare(Threads.reverts.length, 0, "nothing is reverted before the user answers");
            mouseClick(findNamed(dialog.contentItem, "revertFiles"));
            compare(Threads.reverts.length, 1);
            compare(Threads.reverts[0].threadKey, "env-1:thread-1");
            compare(Threads.reverts[0].rowId, "reply:1");
            compare(Threads.reverts[0].restoreFiles, true);
            tryVerify(() => !dialog.visible);
        }

        function test_theUserCancelsARevert() {
            const view = answeredThread();
            mouseClick(findNamed(hoverReply(view), "revertToTurn"));
            const dialog = findChild(view, "revertDialog");
            tryVerify(() => dialog.opened);
            mouseClick(findNamed(dialog.contentItem, "revertCancel"));
            tryVerify(() => !dialog.visible);
            compare(Threads.reverts.length, 0, "the thread is not reverted");
        }

        function test_aReplyWithoutACheckpointOffersNoRevert() {
            const view = answeredThread();
            const question = list(view).itemAtIndex(0);
            mouseMove(question, 20, 10);
            verify(findNamed(question, "revertToTurn") === null, "a user message has no revert");
        }

        function test_jumpToLatestIsACommand() {
            const view = openThread();
            verify(Keybindings.commands.contains("timeline.jumpToLatest"));
            compare(Keybindings.commands.entries["timeline.jumpToLatest"].title, "Jump to latest");
            verify(Keybindings.commands.run("timeline.jumpToLatest"));
        }

        function findText(item, text) {
            if (!item)
                return null;
            if (item.text === text)
                return item;
            for (let i = 0; i < item.children.length; ++i) {
                const found = findText(item.children[i], text);
                if (found)
                    return found;
            }
            return null;
        }
    }
}
