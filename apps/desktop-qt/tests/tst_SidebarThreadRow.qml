import QtQuick
import QtTest
import "../qml/HalC2/Bricks"

Item {
    id: root
    width: 400
    height: 180

    Component {
        id: rowComponent

        SidebarThreadRow {
            width: 360
            height: 78
            active: false
            item: ({
                title: "Review",
                status: "ready",
                unread: false,
                wokeAt: null,
                wakeLabel: null,
                canSettle: true,
                canSnooze: true,
                branch: "main",
                updatedAt: new Date(Date.now() - 61000).toISOString()
            })
        }
    }

    Component {
        id: spyComponent
        SignalSpy {}
    }

    TestCase {
        name: "SidebarThreadRowTests"
        when: windowShown

        // Scenario: The age keeps up while nothing changes (features/threads/unread-and-status.feature)
        function test_relativeAgeRefreshesWhileIdle() {
            let row = createTemporaryObject(rowComponent, root);
            verify(!!row, "Component exists");
            let timer = findChild(row, "ageRefreshTimer");
            verify(!!timer, "Object exists");
            row.ageNow = Date.parse(row.item.updatedAt) + 1000;
            compare(row.ageLabel, qsTr("now"));

            timer.interval = 25;
            timer.restart();

            tryCompare(row, "ageLabel", qsTr("1m"), 2000);
        }
        // Scenario: An idle thread shows its age (features/threads/unread-and-status.feature)
        function test_idleAge_data() {
            return [
                { tag: "20 seconds", ago: 20, age: "now" },
                { tag: "5 minutes", ago: 5 * 60, age: "5m" },
                { tag: "3 hours", ago: 3 * 3600, age: "3h" },
                { tag: "2 days", ago: 2 * 86400, age: "2d" },
                { tag: "3 months", ago: 92 * 86400, age: "3mo" }
            ];
        }

        function test_idleAge(data) {
            let row = createTemporaryObject(rowComponent, root);
            const now = Date.parse("2026-09-07T12:00:00Z");
            row.item = Object.assign({}, row.item, {
                updatedAt: new Date(now - data.ago * 1000).toISOString()
            });
            row.ageNow = now;
            compare(row.statusWord, "");
            compare(row.ageLabel, data.age);
        }

        // Scenario: Threads that need nothing step back (features/threads/unread-and-status.feature)
        function test_readIdleRowRecedes() {
            let read = createTemporaryObject(rowComponent, root);
            let unread = createTemporaryObject(rowComponent, root);
            unread.item = Object.assign({}, unread.item, {
                unread: true
            });
            compare(read.recedes, true);
            compare(unread.recedes, false);
            compare(unread.statusWord, "Done");
        }

        // Scenario: The menu opens as soon as the secondary button is pressed (features/threads/menu-and-selection.feature)
        function test_menuOpensOnPress() {
            let row = createTemporaryObject(rowComponent, root);
            let spy = createTemporaryObject(spyComponent, root, {
                target: row,
                signalName: "menuRequested"
            });
            mousePress(row, 100, 30, Qt.RightButton);
            compare(spy.count, 1);
            mouseRelease(row, 100, 30, Qt.RightButton);
            compare(spy.count, 1);
        }

        // Scenario: A pinned thread shows a pin that unpins it (features/threads/pinning-and-order.feature)
        function test_pinnedRowOffersUnpin() {
            let row = createTemporaryObject(rowComponent, root);
            verify(!findChild(row, "unpinAction"), "no pin on an unpinned row");
            row.item = Object.assign({}, row.item, {
                pinned: true
            });
            let unpin = findChild(row, "unpinAction");
            verify(!!unpin, "a pinned row has the pin button");
            compare(unpin.Accessible.name, "Unpin thread");
            let spy = createTemporaryObject(spyComponent, root, {
                target: row,
                signalName: "unpinRequested"
            });
            mouseClick(unpin);
            compare(spy.count, 1);
        }

        // Scenario: A thread row shows its project's icon (features/threads/sidebar-list.feature)
        function test_rowDrawsTheProjectIcon_data() {
            return [
                { tag: "slim", slim: true, mark: "projectMark" },
                { tag: "card", slim: false, mark: "cardProjectMark" }
            ];
        }

        function test_rowDrawsTheProjectIcon(data) {
            let row = createTemporaryObject(rowComponent, root, {
                slim: data.slim,
                projectName: "Hal"
            });
            let mark = findChild(row, data.mark);
            verify(!!mark);
            verify(!findChild(mark, "projectIconMonogram"), "a folder without an icon");
            row.projectIcon = { kind: "monogram", text: "HC" };
            const monogram = findChild(mark, "projectIconMonogram");
            verify(!!monogram, "the monogram replaces the folder");
            compare(monogram.visible, true);
            row.projectIcon = null;
            tryVerify(() => !findChild(mark, "projectIconMonogram"));
        }

        // Scenario: The thread list announces only the threads it shows (features/threads/sidebar-list.feature)
        function test_hiddenRowIsNotAnnounced() {
            let row = createTemporaryObject(rowComponent, root);
            compare(row.Accessible.ignored, false);
            row.visible = false;
            compare(row.Accessible.ignored, true);
        }
    }
}
