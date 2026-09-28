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
            files: []
        }, fields);
    }

    ListModel {
        id: rows
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
        id: signalSpyComponent
        SignalSpy {}
    }
}
