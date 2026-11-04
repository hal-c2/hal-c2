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
        // the card sits beside the row, never over the rows above and below.
        function test_previewSitsBesideTheRow() {
            let row = createTemporaryObject(rowComponent, root, {
                width: 200,
                item: {
                    title: qsTr("Review"),
                    status: "ready",
                    branch: "main",
                    updatedAt: "2026-09-07T12:00:00Z",
                    preview: { project: "shop", branch: "main", activity: "Active 7d ago" }
                }
            });
            verify(!!row, "Component exists");
            mouseMove(row, 60, row.height / 2);
            tryVerify(() => row.previewCard !== null && row.previewCard.opened, 2000);
            const card = row.previewCard.contentItem.mapToItem(root, 0, 0);
            const rowLeft = row.mapToItem(root, 0, 0).x;
            verify(card.x >= rowLeft + row.width, "the card starts at " + card.x + ", over the row column that ends at " + (rowLeft + row.width));
            mouseMove(root, 390, 190);
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
