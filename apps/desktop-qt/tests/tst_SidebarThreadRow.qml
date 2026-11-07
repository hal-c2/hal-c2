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

        // Scenario: Pinning a thread does not change its age (features/threads/unread-and-status.feature)
        function test_ageCountsFromTheRowsTimeNotItsUpdate() {
            let row = createTemporaryObject(rowComponent, root);
            verify(!!row, "Component exists");
            const now = Date.now();
            row.item = Object.assign({}, row.item, {
                updatedAt: new Date(now).toISOString(),
                timeAt: new Date(now - 3 * 3600 * 1000).toISOString()
            });
            row.ageNow = now;
            compare(row.ageLabel, qsTr("%1h").arg(3));
        }

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
            verify(!findChild(row, "unpinAction"), "the pin waits for the pointer");
            row.focused = true;
            let unpin = findChild(row, "unpinAction");
            verify(!!unpin, "a pinned row has the pin button");
            compare(unpin.Accessible.name, "Unpin thread");
            waitForRendering(row);
            let spy = createTemporaryObject(spyComponent, root, {
                target: row,
                signalName: "unpinRequested"
            });
            mouseClick(unpin);
            compare(spy.count, 1);
        }

        // Scenario: A thread with unsent text in its composer is marked on its row (features/threads/sidebar-list.feature)
        function test_unsentDraftIsMarkedAndDiscarded() {
            let row = createTemporaryObject(rowComponent, root);
            let mark = findChild(row, "unsentDraftMark");
            verify(!mark.visible, "no mark without an unsent draft");
            row.item = Object.assign({}, row.item, {
                unsentDraft: true
            });
            verify(mark.visible, "the row marks its unsent draft");
            compare(mark.Accessible.name, "Unsent draft");
            row.focused = true;
            let discard = findChild(row, "discardDraftAction");
            verify(discard.visible, "the row offers to discard the draft");
            compare(discard.Accessible.name, "Discard draft");
            waitForRendering(row);
            let spy = createTemporaryObject(spyComponent, root, {
                target: row,
                signalName: "discardDraftRequested"
            });
            mouseClick(discard);
            compare(spy.count, 1);
            verify(findChild(row, "settleAction").visible, "the row's other actions stay");
        }

        // Scenario: A thread row shows its project's icon (features/threads/sidebar-list.feature)
        function test_rowDrawsTheProjectIcon_data() {
            return [
                { tag: "slim", slim: true },
                { tag: "card", slim: false }
            ];
        }

        function test_rowDrawsTheProjectIcon(data) {
            let row = createTemporaryObject(rowComponent, root, {
                slim: data.slim,
                projectName: "Hal"
            });
            let mark = findChild(row, "projectMark");
            verify(!!mark);
            const monogram = findChild(mark, "projectIconMonogram");
            verify(monogram.visible, "a project without an icon shows its initial");
            compare(findChild(monogram, "projectIconMonogramText").text, "H");
            // Centred on the title's line, slim or two lines.
            waitForRendering(row);
            const middle = mark.mapToItem(row, 0, mark.height / 2).y;
            const title = findChild(row, "cardTitle");
            const line = title.mapToItem(row, 0, title.height / 2).y;
            verify(Math.abs(middle - line) <= 1, "the mark's middle is at " + middle + ", the title's line at " + line);
            compare(mark.width, 14);
            row.projectIcon = { kind: "emoji", text: "🚀" };
            verify(!monogram.visible, "the icon replaces the initial");
            verify(findChild(mark, "projectIconEmoji").visible);
            row.projectIcon = { kind: "monogram", text: "HC" };
            compare(findChild(monogram, "projectIconMonogramText").text, "HC");
            row.projectIcon = null;
            compare(findChild(monogram, "projectIconMonogramText").text, "H");
            row.projectIcon = { kind: "image", url: "file:///nonexistent/hal-c2-project-icon.png" };
            tryCompare(findChild(mark, "projectIconImage"), "status", Image.Error);
            verify(monogram.visible, "an image that cannot load leaves the initial");
            compare(findChild(monogram, "projectIconMonogramText").text, "H");
            // A favicon brings the project's monogram and colour for meanwhile.
            row.projectIcon = { kind: "image", url: "file:///nonexistent/hal-c2-favicon.png", text: "HC", tint: "#22c55e" };
            tryCompare(findChild(mark, "projectIconImage"), "status", Image.Error);
            compare(findChild(monogram, "projectIconMonogramText").text, "HC");
            verify(Qt.colorEqual(findChild(monogram, "projectIconMonogramText").color, "#22c55e"), "the letters keep the project's colour");
        }

        function shown(item, name) {
            for (const child of item.children) {
                if (!child.visible) {
                    continue;
                }
                if (child.objectName === name) {
                    return child;
                }
                const found = shown(child, name);
                if (found) {
                    return found;
                }
            }
            return null;
        }

        function sceneRect(item) {
            const p = item.mapToItem(null, 0, 0);
            return Qt.rect(p.x, p.y, item.width, item.height);
        }

        // Scenario: A resting row gives its title the status slot's room (features/threads/sidebar-list.feature)
        function test_restingRowGivesTheTitleTheSlot() {
            let row = createTemporaryObject(rowComponent, root);
            row.item = Object.assign({}, row.item, {
                title: "A long title that fills the whole row and then some more"
            });
            const slot = findChild(row, "statusSlot");
            const title = findChild(row, "cardTitle");
            const age = findChild(row, "rowAge");
            waitForRendering(row);
            compare(row.slot, "age");
            verify(slot.width <= 28, "a slot with just the age is " + slot.width + " wide");
            compare(slot.width, Math.min(Math.ceil(age.implicitWidth), row.restingSlotWidth));
            const resting = title.width;
            // The actions claim the whole slot back.
            row.focused = true;
            compare(row.slot, "actions");
            tryCompare(slot, "width", row.slotWidth);
            verify(title.width < resting, "the title gives the actions their room");
            row.focused = false;
            tryCompare(title, "width", resting);
        }

        // An age wider than the resting slot keeps every letter.
        function test_longAgeIsNeverCut() {
            let row = createTemporaryObject(rowComponent, root);
            row.item = Object.assign({}, row.item, {
                title: "A long title that fills the whole row and then some more",
                updatedAt: new Date(Date.now() - 330 * 86400000).toISOString()
            });
            const slot = findChild(row, "statusSlot");
            const age = findChild(row, "rowAge");
            waitForRendering(row);
            compare(age.text, "11mo");
            verify(!age.truncated);
            compare(slot.width, Math.min(Math.ceil(age.implicitWidth), row.restingSlotWidth));
            const title = findChild(row, "cardTitle");
            verify(age.mapToItem(row, 0, 0).x >= title.mapToItem(row, 0, 0).x + title.width, "the age does not run into the title");
        }

        // The jump key takes the status slot's place instead of covering the title.
        function test_jumpHintTakesTheStatusSlot_data() {
            return [
                { tag: "slim", slim: true },
                { tag: "card", slim: false }
            ];
        }

        function test_jumpHintTakesTheStatusSlot(data) {
            let row = createTemporaryObject(rowComponent, root, { slim: data.slim });
            verify(!shown(row, "jumpHint"), "no hint before the modifier is held");
            row.item = Object.assign({}, row.item, {
                title: "A long title that fills the whole row and then some more",
                jumpLabel: "⌘3"
            });
            const hint = shown(row, "jumpHint");
            verify(!!hint, "the hint shows");
            verify(!row.showActions);
            waitForRendering(row);
            const hintRect = sceneRect(hint);
            if (!data.slim) {
                const title = findChild(row, "cardTitle");
                const titleRect = sceneRect(title);
                verify(hintRect.x >= titleRect.x + titleRect.width, "the hint does not cover the title");
            }
            verify(hintRect.x + hintRect.width <= sceneRect(row).x + row.width, "the hint stays in the row");
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
