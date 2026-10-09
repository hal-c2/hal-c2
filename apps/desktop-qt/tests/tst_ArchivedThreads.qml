import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/threads/archive-delete.feature: the Archive section draws what
// ArchivedThreadsController publishes.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: archiveComponent
        ArchivedThreads {
            width: 880
            height: 680
        }
    }

    function thread(overrides) {
        return Object.assign({ key: "env-a:t1", environmentId: "env-a", threadId: "t1", title: "Old spike",
                               description: "Archived 2h ago · Created 3d ago", busy: false }, overrides);
    }

    TestCase {
        name: "ArchivedThreadsTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_nothing_listed_says_why() {
            Shell.state = { archivedThreads: { open: true, status: "empty", title: "No archived threads",
                                               description: "Archived threads will appear here.", groups: [] } };
            const page = createTemporaryObject(archiveComponent, root);
            verify(findChild(page, "placeholder").visible);
            compare(findChild(page, "placeholderTitle").text, "No archived threads");
        }

        function test_a_thread_is_unarchived_and_deleted_from_its_row() {
            Shell.state = { archivedThreads: { open: true, status: "ready", title: "", description: "",
                                               groups: [{ key: "env-a:shop", title: "shop", threads: [root.thread({})] }] } };
            const page = createTemporaryObject(archiveComponent, root);
            verify(!findChild(page, "placeholder").visible);
            const row = findChild(page, "thread_env-a:t1");
            mouseClick(findChild(row, "unarchive"));
            compare(Shell.dispatchedActions[0].action, "archivedThreads.unarchive");
            compare(Shell.dispatchedActions[0].payload.threadId, "t1");
            compare(Shell.dispatchedActions[0].payload.environmentId, "env-a");
            mouseClick(findChild(row, "delete"));
            compare(Shell.dispatchedActions[1].action, "archivedThreads.delete");
        }

        function test_a_thread_with_an_action_running_cannot_be_acted_on_again() {
            Shell.state = { archivedThreads: { open: true, status: "ready", title: "", description: "",
                                               groups: [{ key: "env-a:shop", title: "shop", threads: [root.thread({ busy: true })] }] } };
            const page = createTemporaryObject(archiveComponent, root);
            const row = findChild(page, "thread_env-a:t1");
            verify(!findChild(row, "unarchive").enabled);
            verify(!findChild(row, "delete").enabled);
        }

        function test_the_page_is_titled_under_settings_and_delete_reads_destructive() {
            Shell.state = { archivedThreads: { open: true, status: "ready", title: "", description: "",
                                               groups: [{ key: "env-a:shop", title: "shop", threads: [root.thread()] }] } };
            const page = createTemporaryObject(archiveComponent, root);
            compare(findChild(page, "settingsBreadcrumb").text, "Settings / Archive");
            const row = findChild(page, "thread_env-a:t1");
            compare(findChild(row, "delete").tint, Theme.palette.color("error", "#ef4444"));
            verify(findChild(row, "unarchive").tint !== findChild(row, "delete").tint);
        }
    }
}
