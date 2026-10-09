import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// The Timeline brick over a ListModel with the TimelineModel's roles
// (features/timeline/scrolling-and-links.feature, tool-calls.feature).
Item {
    id: root
    width: 600
    height: 400

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
            files: [],
            time: "",
            icon: "",
            intent: "",
            attribution: "",
            meta: false,
            messageId: "",
            attachments: []
        }, fields);
    }

    ListModel {
        id: rows
    }

    ListModel {
        id: otherRows
    }

    // A model that can copy, revert and name its times, like TimelineModel.
    ListModel {
        id: actionRows
        property var copiedRows: []
        function checkpointOf(rowId) {
            return rowId === "reply" ? {
                checkpointId: "checkpoint:1",
                scopeId: "scope:1",
                turn: 1
            } : {};
        }
        function copy(rowId) {
            copiedRows = copiedRows.concat([rowId]);
            return true;
        }
        function timeTitle(rowId, entryId) {
            return "9:42 AM, 23rd September 2026";
        }
    }

    Component {
        id: timelineComponent
        Timeline {
            width: 600
            height: 400
            model: rows
        }
    }

    // A host that gives the timeline more room while the user reads, as the
    // composer resting on one line does (Composer.conversationScrolled).
    Component {
        id: roomyTimelineComponent
        Timeline {
            width: 600
            height: scrolledAway ? 700 : 400
            model: rows
        }
    }

    TestCase {
        name: "Timeline"
        when: windowShown

        function view(timeline) {
            for (let i = 0; i < timeline.children.length; ++i) {
                if (timeline.children[i].contentY !== undefined)
                    return timeline.children[i];
            }
            return null;
        }

        function atEnd(list) {
            return list.contentY + list.height >= list.originY + list.contentHeight - 4;
        }

        // A long thread whose last row is the reply being written.
        function longThread(component) {
            rows.clear();
            for (let i = 0; i < 30; ++i) {
                rows.append(root.row({
                    rowId: "message-" + i,
                    author: i % 2 === 0 ? "user" : "assistant",
                    text: "Message " + i + "\n\nSome more words to fill a line or two of the thread."
                }));
            }
            rows.append(root.row({
                rowId: "reply",
                text: "The cart",
                streaming: true
            }));
            const timeline = createTemporaryObject(component ?? timelineComponent, root);
            const list = view(timeline);
            tryVerify(() => atEnd(list) && list.contentHeight > list.height, 5000, "the thread opens at its end");
            return timeline;
        }

        function grow() {
            const last = rows.count - 1;
            rows.setProperty(last, "text", rows.get(last).text + "\n\nAnother paragraph of the reply, written just now.");
        }

        function scrollUp(timeline) {
            const list = view(timeline);
            for (let i = 0; i < 5; ++i)
                mouseWheel(list, list.width / 2, list.height / 2, 0, 360);
            tryVerify(() => !list.moving && !timeline.following, 5000, "scrolling up stops following");
        }

        // Scenario: The view follows new output while the user is at the end
        function test_followsNewOutputAtTheEnd() {
            const timeline = longThread();
            const list = view(timeline);
            const before = list.contentHeight;
            grow();
            grow();
            tryVerify(() => list.contentHeight > before && atEnd(list), 5000, "the new text stays in view");
            verify(timeline.following);
        }

        // Scenario: Scrolling away stops the view from following
        function test_scrollingAwayStopsFollowing() {
            const timeline = longThread();
            const list = view(timeline);
            scrollUp(timeline);
            const contentY = list.contentY;
            const before = list.contentHeight;
            grow();
            // How far a wheel notch scrolls is the platform's: a reply still laid
            // out grows the content, one scrolled out of the buffer changes nothing.
            if (list.itemAtIndex(rows.count - 1))
                tryVerify(() => list.contentHeight > before);
            wait(0);
            compare(list.contentY, contentY, "the view stays on the message being read");
            verify(findChild(timeline, "jumpToLatest").visible, "the user is offered a way to scroll to the end");
        }

        // Scenario: The user returns to the end of the thread
        function test_returnsToTheEnd() {
            const timeline = longThread();
            const list = view(timeline);
            scrollUp(timeline);
            const jump = findChild(timeline, "jumpToLatest");
            mouseClick(jump);
            tryVerify(() => atEnd(list) && timeline.following, 5000, "the latest output is shown");
            verify(!jump.visible);
            const before = list.contentHeight;
            grow();
            tryVerify(() => list.contentHeight > before && atEnd(list), 5000, "the view follows new output again");
        }

        // Scenario: The keyboard pages through the conversation
        function test_pageKeysScrollTheConversation() {
            const timeline = longThread();
            const list = view(timeline);
            list.forceActiveFocus();
            tryVerify(() => list.activeFocus, 2000, "the conversation has the keyboard");
            const end = list.contentY;
            keyClick(Qt.Key_PageUp);
            verify(list.contentY < end, "Page Up scrolls up");
            verify(list.contentY > end - list.height, "by less than a page");
            verify(!timeline.following, "the view stops following");
            verify(findChild(timeline, "jumpToLatest").visible);
            keyClick(Qt.Key_Home);
            compare(list.contentY, list.originY - list.topMargin, "Home goes to the start");
            keyClick(Qt.Key_PageDown);
            verify(list.contentY > list.originY - list.topMargin, "Page Down scrolls down");
            keyClick(Qt.Key_End);
            tryVerify(() => atEnd(list) && timeline.following, 5000, "End returns to the end and follows");
        }

        // The jump pill is a button: named, reached by Tab, pressed with Space.
        function test_jumpToTheEndIsAKeyboardButton() {
            const timeline = longThread();
            const list = view(timeline);
            scrollUp(timeline);
            const jump = findChild(timeline, "jumpToLatest");
            compare(jump.Accessible.role, Accessible.Button);
            compare(jump.Accessible.name, "Scroll to end");
            jump.forceActiveFocus();
            keyClick(Qt.Key_Space);
            tryVerify(() => atEnd(list) && timeline.following, 5000, "Space returns to the end");
        }

        // The work log is read by assistive technology: each line by its label.
        function test_workLinesAreNamed() {
            rows.clear();
            rows.append(root.row({
                rowId: "work:1",
                kind: "work",
                entries: [
                    {
                        id: "command:1",
                        label: "git status",
                        command: "bash -lc 'git status'",
                        detail: "clean",
                        statusLabel: ""
                    },
                    {
                        id: "file:1",
                        label: "src/cart.ts",
                        path: "/work/src/cart.ts",
                        detail: "+1 -0",
                        statusLabel: ""
                    }
                ]
            }));
            rows.append(root.row({
                rowId: "limit",
                kind: "error",
                title: "Usage limit reached. Retry after tomorrow at 10:00 AM.",
                icon: "circle-alert",
                warning: true
            }));
            rows.append(root.row({
                rowId: "crash",
                kind: "error",
                title: "Provider error",
                text: "It broke",
                icon: "circle-alert",
                warning: false
            }));
            const timeline = createTemporaryObject(timelineComponent, root);
            const list = view(timeline);
            tryVerify(() => list.itemAtIndex(0) !== null && list.itemAtIndex(1) !== null && list.itemAtIndex(2) !== null);
            const calls = [];
            const collect = item => {
                for (let i = 0; i < item.children.length; ++i) {
                    if (item.children[i].objectName === "workCall")
                        calls.push(item.children[i]);
                    collect(item.children[i]);
                }
            };
            collect(list.itemAtIndex(0));
            compare(calls.length, 2);
            compare(calls[0].Accessible.name, "git status");
            compare(calls[0].Accessible.role, Accessible.Button);
            compare(calls[1].Accessible.name, "src/cart.ts");
            const limit = findText(list.itemAtIndex(1), "Usage limit reached. Retry after tomorrow at 10:00 AM.");
            verify(limit !== null);
            compare(limit.color.toString(), timeline.warningColor.toString(), "a usage limit is a wait: the warning colour");
            compare(findText(list.itemAtIndex(2), "Provider error").color.toString(), timeline.errorColor.toString());
        }

        // Scenario: Scrolling away stops the view from following
        function test_roomMadeForReadingKeepsTheUserAway() {
            const timeline = longThread(roomyTimelineComponent);
            const list = view(timeline);
            // One notch: less than the room the host makes.
            mouseWheel(list, list.width / 2, list.height / 2, 0, 120);
            tryVerify(() => timeline.scrolledAway && !list.moving, 5000, "the host makes room once the scroll ends");
            wait(0);
            verify(!timeline.following, "the room made does not count as the user returning");
            verify(timeline.scrolledAway, "the room stays made");
            compare(timeline.height, 700);
            verify(findChild(timeline, "jumpToLatest").visible);
        }

        // Scenario: The user returns to the end of the thread
        function test_scrollingDownAtTheEndReturnsToIt() {
            const timeline = longThread(roomyTimelineComponent);
            const list = view(timeline);
            mouseWheel(list, list.width / 2, 100, 0, 120);
            tryVerify(() => timeline.scrolledAway && !list.moving, 5000, "the host makes room once the scroll ends");
            // The room made shows the end, without the user scrolling there.
            list.positionViewAtEnd();
            verify(!timeline.following);
            // Down where the list goes no further.
            mouseWheel(list, list.width / 2, 100, 0, -120);
            tryVerify(() => timeline.following && !timeline.scrolledAway && atEnd(list), 5000, "the view follows the end again");
            const before = list.contentHeight;
            grow();
            tryVerify(() => list.contentHeight > before && atEnd(list), 5000, "the view follows new output again");
        }

        // Scenario: Scrolling away stops the view from following
        function test_scrollingDownMidThreadOnlyScrolls() {
            const timeline = longThread(roomyTimelineComponent);
            const list = view(timeline);
            scrollUp(timeline);
            const away = list.contentY;
            mouseWheel(list, list.width / 2, 100, 0, -120);
            tryVerify(() => !list.moving && list.contentY > away, 5000, "the view scrolls down");
            verify(!timeline.following, "a scroll the list takes does not jump to the end");
            verify(!atEnd(list));
        }

        // Scenario: Scrolling away stops the view from following
        function test_scrollingDownOverTheJumpButtonMidThreadOnlyScrolls() {
            const timeline = longThread(roomyTimelineComponent);
            const list = view(timeline);
            scrollUp(timeline);
            const jump = findChild(timeline, "jumpToLatest");
            verify(jump.visible);
            mouseWheel(jump, jump.width / 2, jump.height / 2, 0, -120);
            tryVerify(() => !list.moving, 5000);
            wait(0);
            verify(!timeline.following, "only the button returns to the end from mid-thread");
            verify(!atEnd(list));
        }

        // Scenario: Another thread opens at its end however far the last was scrolled
        function test_anotherThreadOpensAtItsEnd() {
            const timeline = longThread(roomyTimelineComponent);
            const list = view(timeline);
            scrollUp(timeline);
            tryVerify(() => timeline.scrolledAway, 5000);
            otherRows.clear();
            for (let i = 0; i < 30; ++i) {
                otherRows.append(root.row({
                    rowId: "other-" + i,
                    text: "Other " + i + "\n\nSome more words to fill a line or two of the thread."
                }));
            }
            timeline.model = otherRows;
            verify(!timeline.scrolledAway, "the composer is not resting");
            verify(timeline.following);
            tryVerify(() => atEnd(list) && list.contentHeight > list.height, 5000, "the other thread shows its latest output");
            verify(!findChild(timeline, "jumpToLatest").visible);
        }

        // Scenario: The thread says a message is sending until its MC takes it
        function test_sendingShowsUntilTheAgentWorks() {
            rows.clear();
            const timeline = createTemporaryObject(timelineComponent, root);
            const label = findChild(timeline, "workingLabel");
            verify(!label.visible);
            timeline.sending = true;
            tryVerify(() => label.visible);
            compare(label.text, "Sending…");
            timeline.working = true;
            compare(label.text, "Working");
            timeline.sending = false;
            timeline.working = false;
            verify(!label.visible);
        }

        // Scenario: The previous tool calls can be shown and hidden again
        // (the brick asks its model; the model re-emits the row).
        function test_previousToolCallsToggleThroughTheModel() {
            rows.clear();
            rows.append(root.row({
                rowId: "work:1",
                kind: "work",
                hiddenCount: 4,
                entries: [
                    {
                        id: "command:5",
                        label: "Ran command",
                        command: "bun test cart-5",
                        detail: "5 passed",
                        statusLabel: ""
                    }
                ]
            }));
            const timeline = createTemporaryObject(timelineComponent, root);
            const spy = createTemporaryObject(signalSpyComponent, root, {
                target: timeline,
                signalName: "toggled"
            });
            const list = view(timeline);
            tryVerify(() => list.count === 1 && list.itemAtIndex(0) !== null);
            const previous = findText(list.itemAtIndex(0), "+4 previous tool calls");
            verify(previous !== null, "the other four are behind \"+4 previous tool calls\"");
            mouseClick(previous);
            compare(spy.count, 1);
            compare(spy.signalArguments[0][0], "work:1");
        }

        // A tool call opens into its command and output, and closes again.
        function test_toolCallOpensIntoItsDetails() {
            rows.clear();
            rows.append(root.row({
                rowId: "work:1",
                kind: "work",
                entries: [
                    {
                        id: "command:1",
                        label: "Ran command",
                        command: "bun test cart",
                        detail: "12 passed",
                        statusLabel: "Failed",
                        exitCode: 1
                    }
                ]
            }));
            const timeline = createTemporaryObject(timelineComponent, root);
            const list = view(timeline);
            tryVerify(() => list.itemAtIndex(0) !== null);
            const label = findText(list.itemAtIndex(0), "Ran command");
            const command = findText(list.itemAtIndex(0), "$ bun test cart");
            verify(!visibleIn(command), "details start closed");
            mouseClick(label);
            tryVerify(() => visibleIn(command), 2000, "the call shows its command");
            verify(visibleIn(findText(list.itemAtIndex(0), "Exit code 1")));
            // Streamed output keeps it open.
            rows.set(0, root.row({
                rowId: "work:1",
                kind: "work",
                entries: [
                {
                    id: "command:1",
                    label: "Ran command",
                    command: "bun test cart",
                    detail: "12 passed\n13 passed",
                    statusLabel: "Failed",
                    exitCode: 1
                }
            ]}));
            tryVerify(() => visibleIn(findText(list.itemAtIndex(0), "$ bun test cart")), 2000, "the call stays open");
            mouseClick(findText(list.itemAtIndex(0), "Ran command"));
            tryVerify(() => !visibleIn(findText(list.itemAtIndex(0), "$ bun test cart")), 2000, "the call closes");
        }

        // A call that streams changes its own line; the calls beside it are
        // not made again.
        function test_streamedCallLeavesTheOthersAsTheyAre() {
            const group = detail => root.row({
                rowId: "work:2",
                kind: "work",
                expanded: true,
                entries: [
                    {
                        id: "command:1",
                        label: "Ran command",
                        command: "bun test cart",
                        detail: "12 passed",
                        exitCode: 0
                    },
                    {
                        id: "reasoning:1",
                        type: "reasoning",
                        label: "Thinking",
                        detail: detail
                    }
                ]
            });
            rows.clear();
            rows.append(group("The total"));
            const timeline = createTemporaryObject(timelineComponent, root);
            const list = view(timeline);
            tryVerify(() => allNamed(list.itemAtIndex(0), "workCall").length === 2);
            const before = allNamed(list.itemAtIndex(0), "workCall");
            // Laid out one under the other, so a tap lands on one of them.
            tryVerify(() => before[1].parent.y > 0);
            mouseClick(findText(list.itemAtIndex(0), "Thinking"));
            tryVerify(() => visibleIn(findText(list.itemAtIndex(0), "The total")), 2000, "the thinking opens");

            rows.set(0, group("The total needs a tax line"));
            tryVerify(() => visibleIn(findText(list.itemAtIndex(0), "The total needs a tax line")), 2000, "the streamed text shows");
            const after = allNamed(list.itemAtIndex(0), "workCall");
            compare(after.length, 2);
            verify(after[0] === before[0] && after[1] === before[1], "both lines are the ones that were there");
            verify(list.itemAtIndex(0).openCalls["command:1"] !== true, "the command stays closed");
        }

        function allNamed(item, name, found) {
            found = found ?? [];
            if (!item)
                return found;
            if (item.objectName === name)
                found.push(item);
            for (let i = 0; i < item.children.length; ++i)
                allNamed(item.children[i], name, found);
            return found;
        }

        function conversation() {
            actionRows.clear();
            actionRows.copiedRows = [];
            actionRows.append(root.row({
                rowId: "question",
                author: "user",
                text: "Add tax to the cart",
                time: "9:41 AM"
            }));
            actionRows.append(root.row({
                rowId: "reply",
                text: "Tax is applied after discounts.",
                status: "completed",
                time: "9:42 AM",
                meta: true
            }));
        }

        // Scenario: A sent message shows its images
        function test_userMessageShowsItsImages() {
            actionRows.clear();
            actionRows.append(root.row({
                rowId: "question",
                author: "user",
                text: "",
                attachments: [{
                    id: "image-1",
                    name: "cart.png",
                    url: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
                }, {
                    id: "image-2",
                    name: "checkout.png",
                    url: ""
                }]
            }));
            const timeline = createTemporaryObject(actionTimelineComponent, root);
            const list = view(timeline);
            tryVerify(() => list.itemAtIndex(0) !== null);
            const question = list.itemAtIndex(0);
            const loaded = findNamed(question, "attachment-image-1");
            tryVerify(() => loaded.pictured, 2000, "the image is drawn");
            verify(!visibleIn(findText(question, "cart.png")), "a drawn image needs no name");
            verify(visibleIn(findText(question, "checkout.png")), "an image still on its way is named");
        }

        // The opacity a thing is drawn with, through its parents.
        function shownOpacity(item) {
            let opacity = 1;
            for (let current = item; current; current = current.parent)
                opacity *= current.opacity;
            return opacity;
        }

        // Without hover (touch screens), a message's time and actions are
        // always shown.
        function test_messageActionsShowWithoutHover() {
            conversation();
            const timeline = createTemporaryObject(actionTimelineComponent, root, {
                alwaysShowMeta: true
            });
            const list = view(timeline);
            tryVerify(() => list.itemAtIndex(1) !== null);
            const question = list.itemAtIndex(0);
            const reply = list.itemAtIndex(1);
            for (const [item, time] of [[question, "9:41 AM"], [reply, "9:42 AM"]]) {
                const copy = findNamed(item, "copyMessage");
                verify(visibleIn(copy), "each message offers Copy");
                compare(shownOpacity(copy), 1, "Copy is shown without the pointer over it");
                verify(visibleIn(findText(item, time)), "each message shows its time");
            }
            const revert = findNamed(reply, "revertToTurn");
            verify(visibleIn(revert), "the reply offers Revert without the pointer over it");
            compare(shownOpacity(revert), 1);
            verify(findNamed(question, "revertToTurn") === null, "a user message has no revert");
        }

        // Scenario: Only a turn's last reply carries its time and actions
        function test_commentaryHasNoActions() {
            conversation();
            actionRows.insert(1, root.row({
                rowId: "comment",
                text: "Looking at the cart first.",
                status: "completed",
                time: "9:41 AM"
            }));
            const timeline = createTemporaryObject(actionTimelineComponent, root, {
                alwaysShowMeta: true
            });
            const list = view(timeline);
            tryVerify(() => list.itemAtIndex(2) !== null);
            const comment = list.itemAtIndex(1);
            verify(!visibleIn(findNamed(comment, "copyMessage")), "commentary offers no Copy");
            verify(!visibleIn(findText(comment, "9:41 AM")), "commentary shows no time");
            verify(visibleIn(findNamed(list.itemAtIndex(2), "copyMessage")), "the turn's last reply does");
        }

        // With hover, a message's actions keep their place while hidden, so
        // showing them moves nothing and they still take a tap.
        function test_hiddenMessageActionsKeepTheirPlace() {
            conversation();
            const timeline = createTemporaryObject(actionTimelineComponent, root);
            const list = view(timeline);
            tryVerify(() => list.itemAtIndex(1) !== null);
            const question = list.itemAtIndex(0);
            const copy = findNamed(question, "copyMessage");
            mouseMove(list, list.width / 2, list.height - 2);
            tryCompare(copy.parent, "opacity", 0, 2000, "Copy is hidden away from the pointer");
            // The message's markdown is laid out.
            const markdown = findWith(question, "segmentCount");
            tryVerify(() => markdown.segmentCount > 0 && markdown.implicitHeight > 0 && question.height >= markdown.implicitHeight, 2000);
            const height = question.height;
            mouseMove(question, question.width / 2, 4);
            tryCompare(copy.parent, "opacity", 1, 2000, "Copy shows with the pointer over the message");
            compare(question.height, height, "showing the actions moves nothing");
            mouseClick(copy);
            compare(actionRows.copiedRows, ["question"]);
        }

        // Copy turns into a check for a moment once the message is copied.
        function test_copyShowsItIsDone() {
            conversation();
            const timeline = createTemporaryObject(actionTimelineComponent, root, {
                alwaysShowMeta: true
            });
            const spy = createTemporaryObject(signalSpyComponent, root, {
                target: timeline,
                signalName: "copied"
            });
            const list = view(timeline);
            tryVerify(() => list.itemAtIndex(1) !== null);
            const copy = findNamed(list.itemAtIndex(1), "copyMessage");
            compare(copy.icon, "copy");
            mouseClick(copy);
            compare(actionRows.copiedRows, ["reply"]);
            compare(spy.signalArguments[0][0], "reply");
            compare(copy.icon, "check", "Copy shows a check once copied");
            tryCompare(copy, "icon", "copy", 3000, "and goes back to Copy");
        }

        // Scenario: A tool call's icon says what kind of work it was
        function test_toolCallsShowTheirIcon() {
            rows.clear();
            rows.append(root.row({
                rowId: "work:1",
                kind: "work",
                expanded: true,
                entries: [
                    {
                        id: "command:1",
                        label: "Ran command",
                        icon: "terminal",
                        time: "9:41 AM"
                    },
                    {
                        id: "tool:2",
                        label: "Called a tool",
                        icon: "",
                        time: ""
                    }
                ]
            }));
            const timeline = createTemporaryObject(timelineComponent, root, {
                alwaysShowMeta: true
            });
            const list = view(timeline);
            tryVerify(() => list.itemAtIndex(0) !== null);
            const item = list.itemAtIndex(0);
            verify(visibleIn(findIcon(item, "terminal")), "a command shows the terminal icon");
            verify(visibleIn(findIcon(item, "hammer")), "a call without an icon shows the hammer");
            verify(visibleIn(findText(item, "9:41 AM")), "a call shows its time");
        }

        // Scenario: A delegated task's result shows as a notification row, not a user message
        function test_notificationRowIsOneLineInTheColumn() {
            rows.clear();
            const title = "Audit every settings page of the desktop client against the web one and list what differs ".repeat(3) + "finished";
            rows.append(root.row({
                rowId: "turn-item:user:1",
                kind: "marker",
                author: "user",
                icon: "zap",
                title: title
            }));
            const timeline = createTemporaryObject(timelineComponent, root);
            const list = view(timeline);
            tryVerify(() => list.itemAtIndex(0) !== null);
            const item = list.itemAtIndex(0);
            const label = findNamed(item, "markerTitle");
            verify(visibleIn(label), "the notification names what ended");
            compare(label.text, title);
            verify(visibleIn(findIcon(item, "zap")), "with the notification's icon");
            verify(label.truncated, "a long title is cut short");
            verify(label.mapToItem(item, 0, 0).x >= 0 && label.mapToItem(item, label.width, 0).x <= item.width, "and stays inside the row");
            verify(item.height < 60, "on one line");
            verify(!findNamed(item, "messageAttribution") || !visibleIn(findNamed(item, "messageAttribution")), "and is nobody's message");
        }

        function findWith(item, property) {
            if (!item)
                return null;
            if (item[property] !== undefined)
                return item;
            for (let i = 0; i < item.children.length; ++i) {
                const found = findWith(item.children[i], property);
                if (found)
                    return found;
            }
            return null;
        }

        // The shown icon of that name.
        function findIcon(item, name) {
            if (!item || !item.visible)
                return null;
            if (item.name === name && item.size !== undefined)
                return item;
            for (let i = 0; i < item.children.length; ++i) {
                const found = findIcon(item.children[i], name);
                if (found)
                    return found;
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

        function visibleIn(item) {
            for (let current = item; current; current = current.parent) {
                if (!current.visible)
                    return false;
            }
            return item !== null;
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

    Component {
        id: actionTimelineComponent
        Timeline {
            width: 600
            height: 400
            model: actionRows
        }
    }

    Component {
        id: signalSpyComponent
        SignalSpy {}
    }
}
