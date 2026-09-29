import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

Item {
    id: root
    width: 400
    height: 500

    Component {
        id: sidebarComponent
        Sidebar {
            width: 272
            height: 450
            showScope: false
            showFooter: false
        }
    }

    Component {
        id: scopedSidebarComponent
        Sidebar {
            width: 272
            height: 450
            showFooter: false
        }
    }

    TestCase {
        name: "SidebarTests"
        when: windowShown

        function init() {
            Shell.state = {
                sidebar: {
                    projects: [
                        {
                            key: "project",
                            displayName: qsTr("Project")
                        }
                    ],
                    scopeProjectKey: null,
                    activeThreadKey: null,
                    activeDraftId: null,
                    drafts: [],
                    pinned: [],
                    snoozed: [],
                    settled: [],
                    settledTotal: 0,
                    active: [
                        {
                            key: "thread",
                            projectKey: "project",
                            title: qsTr("Review"),
                            status: "working",
                            canSettle: true,
                            canSnooze: true,
                            branch: "main",
                            updatedAt: "2026-09-07T12:00:00Z"
                        }
                    ]
                }
            };
        }

        function cleanup() {
            Shell.reset();
        }

        // Scenario: A thread row keeps its place while the list updates (features/threads/sidebar-list.feature)
        function test_publicationKeepsHoveredRow() {
            let sidebar = createTemporaryObject(sidebarComponent, root);
            verify(!!sidebar, "Component exists");
            let list = findChild(sidebar, "list");
            verify(!!list, "Object exists");
            tryCompare(list, "count", 1);
            let row = findChild(sidebar, "threadRow:thread");
            verify(!!row, "Object exists");
            mouseMove(row, 100, 40);
            tryCompare(row, "showActions", true);
            const next = JSON.parse(JSON.stringify(Shell.state.sidebar));
            next.active[0].title = qsTr("Review updated");
            Shell.state = {
                sidebar: next
            };
            tryVerify(() => findChild(sidebar, "threadRow:thread").item.title === qsTr("Review updated"));
            compare(findChild(sidebar, "threadRow:thread"), row);
            tryCompare(row, "showActions", true);
        }

        function test_customModelFiltersRowsAndKeepsNavigation() {
            let sidebar = createTemporaryObject(sidebarComponent, root);
            verify(!!sidebar, "Component exists");
            const source = JSON.parse(JSON.stringify(Shell.state.sidebar));
            source.active.push(Object.assign({}, source.active[0], {
                key: "other", title: qsTr("Other"), projectKey: "other-project"
            }));
            Shell.state = { sidebar: source };
            sidebar.model = Qt.binding(() => Shell.state.sidebar ? Object.assign({}, Shell.state.sidebar, {
                active: Shell.state.sidebar.active.filter(item => item.projectKey === "project")
            }) : null);
            let list = findChild(sidebar, "list");
            verify(!!list, "Object exists");
            tryCompare(list, "count", 1);
            let row = findChild(sidebar, "threadRow:thread");
            verify(!!row, "Object exists");
            mouseClick(row, 100, 40);
            tryCompare(Shell, "dispatchCount", 1);
            compare(Shell.dispatchedActions[0].action, "thread.open");
            compare(Shell.dispatchedActions[0].payload.key, "thread");
            const updated = JSON.parse(JSON.stringify(source));
            updated.active[0].title = qsTr("Filtered publication");
            Shell.state = { sidebar: updated };
            tryCompare(row.item, "title", qsTr("Filtered publication"));
            compare(Shell.state.sidebar.active.length, 2);
        }

        function test_reorderParkFoldAndRemove() {
            let sidebar = createTemporaryObject(sidebarComponent, root);
            verify(!!sidebar, "Component exists");
            let list = findChild(sidebar, "list");
            verify(!!list, "Object exists");
            tryCompare(list, "count", 1);
            let row = findChild(sidebar, "threadRow:thread");
            verify(!!row, "Object exists");
            let next = JSON.parse(JSON.stringify(Shell.state.sidebar));
            next.active.unshift(Object.assign({}, next.active[0], {
                key: "second",
                title: qsTr("Second")
            }));
            Shell.state = {
                sidebar: next
            };
            tryCompare(list, "count", 2);
            compare(findChild(sidebar, "threadRow:thread"), row);

            next = JSON.parse(JSON.stringify(next));
            next.active.reverse();
            Shell.state = {
                sidebar: next
            };
            compare(findChild(sidebar, "threadRow:thread"), row);
            mouseClick(row, 100, 40);
            tryCompare(Shell, "dispatchCount", 1);
            compare(Shell.dispatchedActions[0].payload.key, "thread");

            next = JSON.parse(JSON.stringify(next));
            next.snoozed = [next.active.shift()];
            Shell.state = {
                sidebar: next
            };
            tryCompare(list, "count", 3);
            tryCompare(row, "slim", true);
            tryCompare(row, "section", "snoozed");
            sidebar.toggleSection("snoozed");
            tryCompare(list, "count", 2);
            sidebar.toggleSection("snoozed");
            tryCompare(list, "count", 3);

            next = JSON.parse(JSON.stringify(next));
            next.active = [];
            next.snoozed = [];
            Shell.state = {
                sidebar: next
            };
            tryCompare(list, "count", 0);
        }
        function thread(key, title) {
            return {
                key: key,
                projectKey: "project",
                title: title,
                status: "ready",
                canSettle: true,
                canSnooze: true,
                branch: "main",
                updatedAt: "2026-09-07T12:00:00Z"
            };
        }

        // Alpha, Beta and Gamma are active, Beta is open; Old is settled.
        function publishList() {
            const next = JSON.parse(JSON.stringify(Shell.state.sidebar));
            next.active = [thread("alpha", "Alpha"), thread("beta", "Beta"), thread("gamma", "Gamma")];
            next.settled = [thread("old", "Old")];
            next.settledTotal = 1;
            next.activeThreadKey = "beta";
            Shell.state = {
                sidebar: next
            };
        }

        function focusedList(cursor) {
            publishList();
            let sidebar = createTemporaryObject(sidebarComponent, root);
            verify(!!sidebar, "Component exists");
            let list = findChild(sidebar, "list");
            tryCompare(list, "count", 5);
            // Delegates land on the next polish, after the count.
            tryVerify(() => list.itemAtIndex(4) !== null);
            // The folder dialog test hands activation to its dialog; take it back.
            root.Window.window.requestActivate();
            tryVerify(() => root.Window.active);
            list.forceActiveFocus();
            tryCompare(list, "activeFocus", true);
            if (cursor !== undefined) {
                list.cursorKey = cursor;
            }
            return list;
        }

        // Scenario: Tab reaches the thread list (features/navigation/focus.feature)
        function test_focusLandsOnCurrentThread() {
            publishList();
            let sidebar = createTemporaryObject(sidebarComponent, root);
            let list = findChild(sidebar, "list");
            tryCompare(list, "count", 5);
            compare(list.activeFocusOnTab, true);
            tryVerify(() => list.itemAtIndex(4) !== null);
            root.Window.window.requestActivate();
            tryVerify(() => root.Window.active);
            list.forceActiveFocus(Qt.TabFocusReason);
            tryCompare(list, "cursorKey", "beta");
            tryCompare(findChild(sidebar, "threadRow:beta"), "focused", true);
            compare(findChild(sidebar, "threadRow:alpha").focused, false);
        }

        // Scenario: Moving through the list with the keyboard (features/threads/sidebar-list.feature)
        // Scenario: Home and End jump to the ends of the thread list (features/navigation/focus.feature)
        function test_cursorKeys_data() {
            return [
                { tag: "Down", key: Qt.Key_Down, cursor: "gamma" },
                { tag: "Up", key: Qt.Key_Up, cursor: "alpha" },
                { tag: "Home", key: Qt.Key_Home, cursor: "alpha" },
                { tag: "End", key: Qt.Key_End, cursor: "old" }
            ];
        }

        function test_cursorKeys(data) {
            let list = focusedList("beta");
            keyClick(data.key);
            compare(list.cursorKey, data.cursor);
            compare(Shell.dispatchCount, 0);
        }

        // Scenario: Moving through the list with the keyboard (features/threads/sidebar-list.feature)
        // Scenario: Enter and Space open the highlighted thread (features/navigation/focus.feature)
        function test_openKeys_data() {
            return [
                { tag: "Enter", key: Qt.Key_Return },
                { tag: "Space", key: Qt.Key_Space }
            ];
        }

        function test_openKeys(data) {
            focusedList("gamma");
            keyClick(data.key);
            tryCompare(Shell, "dispatchCount", 1);
            compare(Shell.dispatchedActions[0].action, "thread.open");
            compare(Shell.dispatchedActions[0].payload.key, "gamma");
        }

        // Scenario: Moving through the list with the keyboard (features/threads/sidebar-list.feature)
        // Scenario: The menu key opens the highlighted thread's menu (features/navigation/focus.feature)
        function test_menuKeys_data() {
            return [
                { tag: "Shift+F10", key: Qt.Key_F10, modifiers: Qt.ShiftModifier },
                { tag: "Menu", key: Qt.Key_Menu, modifiers: Qt.NoModifier }
            ];
        }

        function test_menuKeys(data) {
            let list = focusedList("beta");
            keyClick(data.key, data.modifiers);
            tryCompare(Shell, "dispatchCount", 1);
            const sent = Shell.dispatchedActions[0];
            compare(sent.action, "thread.menu");
            compare(sent.payload.key, "beta");
            // Beside the row: the point is inside it.
            const row = list.itemAtIndex(list.cursorIndex);
            const local = row.mapFromItem(null, sent.payload.x, sent.payload.y);
            verify(local.x > 0 && local.x < row.width && local.y > 0 && local.y < row.height);
        }

        function test_plainF10DoesNothing() {
            focusedList("beta");
            keyClick(Qt.Key_F10);
            compare(Shell.dispatchCount, 0);
        }

        // Scenario: Enter on a shelf header folds the shelf (features/threads/sidebar-list.feature)
        function test_enterFoldsShelf() {
            let list = focusedList("header:settled");
            keyClick(Qt.Key_Return);
            tryCompare(list, "count", 4);
            compare(Shell.dispatchCount, 0);
            keyClick(Qt.Key_Return);
            tryCompare(list, "count", 5);
        }

        // Scenario: Collapsing and expanding a shelf (features/threads/sidebar-list.feature)
        function test_collapseAndExpandShelf() {
            publishList();
            let sidebar = createTemporaryObject(sidebarComponent, root);
            let list = findChild(sidebar, "list");
            tryCompare(list, "count", 5);
            tryVerify(() => !!findChild(sidebar, "threadRow:old"));
            let header = findChild(sidebar, "header:settled");
            verify(!!header, "Object exists");
            compare(findChild(header, "headerCount").visible, false);
            mouseClick(header);
            tryCompare(list, "count", 4);
            compare(sidebar.rows.some(r => r.rowKey === "old"), false);
            header = findChild(sidebar, "header:settled");
            const count = findChild(header, "headerCount");
            compare(count.visible, true);
            compare(count.text, "1");
            mouseClick(header);
            tryCompare(list, "count", 5);
            compare(sidebar.rows.some(r => r.rowKey === "old"), true);
            tryVerify(() => list.itemAtIndex(4) !== null && list.itemAtIndex(4).modelData.rowKey === "old");
        }

        // Scenario: Empty thread lists explain themselves (features/threads/sidebar-list.feature)
        function test_emptyListMessage_data() {
            return [
                { tag: "not published", sidebar: undefined, message: "Waiting for the app…" },
                { tag: "no projects", sidebar: { projects: [] }, message: "No projects yet" },
                { tag: "no threads", sidebar: {}, message: "No threads yet" }
            ];
        }

        function test_emptyListMessage(data) {
            if (data.sidebar === undefined) {
                Shell.state = {};
            } else {
                const next = Object.assign(JSON.parse(JSON.stringify(Shell.state.sidebar)), { active: [] }, data.sidebar);
                Shell.state = {
                    sidebar: next
                };
            }
            let sidebar = createTemporaryObject(sidebarComponent, root);
            let list = findChild(sidebar, "list");
            tryCompare(list, "count", 0);
            const empty = findChild(sidebar, "emptyText");
            compare(empty.visible, true);
            compare(empty.text, data.message);
        }

        // Scenario: Adding a project from the thread list (features/threads/sidebar-list.feature)
        function test_addProjectChoosesAFolder() {
            Shell.localFolderImportEnabled = true;
            const next = Object.assign(JSON.parse(JSON.stringify(Shell.state.sidebar)), { localEnvironmentId: "env" });
            Shell.state = {
                sidebar: next
            };
            let sidebar = createTemporaryObject(scopedSidebarComponent, root);
            let button = findChild(sidebar, "addProject");
            verify(!!button, "Object exists");
            let dialog = findChild(sidebar, "addProjectDialog");
            verify(!!dialog, "Object exists");
            mouseClick(button);
            tryCompare(dialog, "visible", true);
            dialog.reject();
            tryCompare(dialog, "visible", false);
            compare(Shell.dispatchCount, 0);
        }
    }
}
