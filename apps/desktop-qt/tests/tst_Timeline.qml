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
        function longThread() {
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
            const timeline = createTemporaryObject(timelineComponent, root);
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
