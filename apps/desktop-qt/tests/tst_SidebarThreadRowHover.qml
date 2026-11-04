import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

Item {
    id: root
    width: 400
    height: 200

    Component {
        id: rowComponent
        SidebarThreadRow {
            width: 272
            height: 78
            active: false
            item: ({
                    title: qsTr("Review"),
                    status: "ready",
                    canSettle: true,
                    canSnooze: true,
                    branch: "main",
                    updatedAt: "2026-09-07T12:00:00Z"
                })
        }
    }

    TestCase {
        id: testCase
        name: "SidebarThreadRowHoverTests"
        when: windowShown
        property var observedBackground: null
        property real darkest: 1

        Connections {
            target: testCase.observedBackground
            function onColorChanged() {
                const c = testCase.observedBackground.color;
                testCase.darkest = Math.min(testCase.darkest, c.r * c.a + (1 - c.a) * 0.98);
            }
        }

        function cleanup() {
            observedBackground = null;
            Theme.colors = {};
        }

        // Scenario: Pointing at a row does not flash it (features/threads/unread-and-status.feature)
        function test_lightHoverNeverFlashesGray() {
            Theme.colors = {
                sidebarRowHover: "#fff7f4"
            };
            let row = createTemporaryObject(rowComponent, root);
            verify(!!row, "Component exists");
            let background = findChild(row, "rowBackground");
            verify(!!background, "Object exists");
            observedBackground = background;
            darkest = 0.98;
            mouseMove(row, 100, 40);
            tryCompare(background, "color", "#fff7f4");
            verify(darkest >= 0.98);
            mouseMove(root, 380, 150);
            tryCompare(background, "color", Qt.alpha("#fff7f4", 0));
            verify(darkest >= 0.98);
        }

        // Scenario: Moving across a row's actions keeps the row highlighted (features/threads/unread-and-status.feature)
        function test_hoverAcrossActions() {
            let row = createTemporaryObject(rowComponent, root);
            verify(!!row, "Component exists");
            mouseMove(row, 10, 12);
            tryCompare(row, "showActions", true);
            for (let x = 180; x < 264; ++x) {
                mouseMove(row, x, 15, 20);
                tryCompare(row, "showActions", true, 100);
            }
            mouseMove(root, 380, 150);
            tryCompare(row, "showActions", false);
        }

        // Scenario: Pointing at a thread previews it (features/threads/unread-and-status.feature):
        // the tip stays in the row's column, under the row, and never reaches
        // the thread beside the list; at the window's bottom it sits over the row.
        function test_previewStaysInTheRowColumn_data() {
            return [
                { tag: "top", rowY: 0, below: true },
                { tag: "bottom", rowY: 150, below: false }
            ];
        }

        function test_previewStaysInTheRowColumn(data) {
            // Inset like the sidebar's list.
            let row = createTemporaryObject(rowComponent, root, {
                x: 8,
                y: data.rowY,
                width: 200,
                height: 48,
                item: {
                    title: qsTr("Review the sidebar's preview so that it never covers the reply"),
                    status: "ready",
                    branch: "main",
                    updatedAt: "2026-09-07T12:00:00Z",
                    preview: { project: "shop", branch: "feature/a-branch-with-a-long-name", activity: "Active 7d ago" }
                }
            });
            verify(!!row, "Component exists");
            mouseMove(row, 60, row.height / 2);
            tryVerify(() => row.previewCard !== null && row.previewCard.opened, 2000);
            const card = row.previewCard;
            const at = card.background.mapToItem(root, 0, 0);
            const rowAt = row.mapToItem(root, 0, 0);
            verify(at.x >= rowAt.x && at.x + card.width <= rowAt.x + row.width,
                   "the tip spans " + at.x + "–" + (at.x + card.width) + ", outside the row's column " + rowAt.x + "–" + (rowAt.x + row.width));
            if (data.below) {
                verify(at.y >= rowAt.y + row.height, "the tip starts at " + at.y + ", over the row that ends at " + (rowAt.y + row.height));
            } else {
                verify(at.y + card.height <= rowAt.y, "the tip ends at " + (at.y + card.height) + ", under the row that starts at " + rowAt.y);
            }
            mouseMove(root, 390, data.below ? 190 : 10);
            tryCompare(row, "previewCard", null);
        }

        function test_multiLineTitleHoldsStillOnHover() {
            let row = createTemporaryObject(rowComponent, root, {
                item: {
                    title: "We need to integrate:\nhttps://example.com/one",
                    status: "ready",
                    canSettle: true,
                    canSnooze: true,
                    branch: "main",
                    updatedAt: "2026-09-07T12:00:00Z"
                }
            });
            verify(!!row, "Component exists");
            let title = findChild(row, "cardTitle");
            compare(title.lineCount, 1);
            const restY = title.mapToItem(row, 0, 0).y;
            mouseMove(row, 100, 40);
            tryCompare(row, "showActions", true);
            compare(title.mapToItem(row, 0, 0).y, restY);
        }
    }
}
