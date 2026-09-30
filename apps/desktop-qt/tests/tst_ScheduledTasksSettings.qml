import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/settings/scheduled-tasks.feature: the Scheduled Tasks section draws
// what ScheduledTasksController publishes, and its editor saves its own draft.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: tasksComponent
        ScheduledTasksSettings {
            width: 880
            height: 680
        }
    }

    function task(overrides) {
        return Object.assign({ id: "t1", title: "Check Sentry", prompt: "Look", schedule: "Daily at 09:00",
                               when: "Next run in 5m", enabled: true, lastRunStatus: "succeeded", lastRunError: "",
                               busy: false }, overrides);
    }

    function draft() {
        return { title: "", prompt: "", enabled: true, scheduleMode: "fixed", intervalMinutes: "15", timeOfDay: "09:00",
                 weekdays: [0, 1, 2, 3, 4, 5, 6], projectId: "api", threadId: "", workspaceMode: "worktree",
                 baseRef: "main", startFromOrigin: true, checkoutPath: "", modelKey: "codex:gpt" };
    }

    TestCase {
        name: "ScheduledTasksSettingsTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_a_failed_task_shows_its_error_and_a_row_acts_on_its_task() {
            Shell.state = { scheduledTasks: { open: true, canCreate: true, editor: null, environments: [
                { id: "env-a", label: "This machine", heading: false, status: "ready", tasks: [
                    root.task({ lastRunStatus: "failed", lastRunError: "The server stopped during this run." })] }] } };
            const page = createTemporaryObject(tasksComponent, root);
            const row = findChild(page, "scheduledTask:t1");
            verify(findChild(row, "lastError").visible);
            verify(!findChild(page, "notice").visible);
            mouseClick(findChild(row, "enabled"));
            compare(Shell.dispatchedActions[0].action, "scheduledTasks.enable");
            compare(Shell.dispatchedActions[0].payload.enabled, false);
            compare(Shell.dispatchedActions[0].payload.environmentId, "env-a");
        }

        function test_a_disconnected_environment_offers_to_reconnect() {
            Shell.state = { scheduledTasks: { open: true, canCreate: false, editor: null, environments: [
                { id: "laptop", label: "laptop", heading: false, status: "disconnected",
                  message: "Reconnect laptop to view its scheduled tasks.", tasks: [] }] } };
            const page = createTemporaryObject(tasksComponent, root);
            const reconnect = findChild(page, "reconnect");
            verify(reconnect.visible);
            mouseClick(reconnect);
            compare(Shell.dispatchedActions[0].action, "connections.open");
        }

        function test_the_editor_saves_what_was_typed_and_keeps_it_across_updates() {
            const state = { open: true, canCreate: true, environments: [],
                            editor: { seq: 1, environmentId: "env-a", environments: [{ id: "env-a", label: "This machine" }],
                                      editing: false, connected: true, saving: false, draft: root.draft(),
                                      projects: [{ id: "api", title: "api" }], models: [{ key: "codex:gpt", label: "Codex · gpt" }] } };
            Shell.state = { scheduledTasks: state };
            const page = createTemporaryObject(tasksComponent, root);
            const editor = findChild(page, "scheduledTaskEditor");
            tryVerify(() => editor.opened);
            const title = findChild(editor, "title");
            title.forceActiveFocus();
            keyClick(Qt.Key_A);
            // A republish of the same editor keeps the typing.
            Shell.state = { scheduledTasks: Object.assign({}, state) };
            compare(editor.draft.title, "a");
            mouseClick(findChild(editor, "save"));
            const saved = Shell.dispatchedActions.find(entry => entry.action === "scheduledTasks.save");
            compare(saved.payload.draft.title, "a");
            compare(saved.payload.draft.workspaceMode, "worktree");
        }

        function editorState(overrides, draftOverrides) {
            return { open: true, canCreate: true, environments: [],
                     editor: Object.assign({ seq: 1, environmentId: "env-a", environments: [{ id: "env-a", label: "This machine" }],
                                             editing: true, connected: true, saving: false, missing: false, error: "",
                                             legacyInterval: false, branches: [], branchesTotal: 0, branchesLoading: false,
                                             draft: Object.assign(root.draft(), draftOverrides ?? {}),
                                             projects: [{ id: "api", title: "api" }],
                                             models: [{ key: "codex:gpt", label: "Codex · gpt" }] }, overrides) };
        }

        function test_a_row_previews_its_prompt_and_badges_its_last_run() {
            Shell.state = { scheduledTasks: { open: true, canCreate: true, editor: null, environments: [
                { id: "env-a", label: "This machine", heading: false, status: "ready", tasks: [
                    root.task({ prompt: "one\ntwo\nthree\nfour", lastRun: "Succeeded" })] }] } };
            const page = createTemporaryObject(tasksComponent, root);
            const row = findChild(page, "scheduledTask:t1");
            const preview = findChild(row, "promptPreview");
            compare(preview.lineCount, 2);
            verify(preview.truncated);
            const badge = findChild(row, "lastRun");
            verify(badge.visible);
            compare(badge.text, "Succeeded");
        }

        function test_the_last_weekday_stays_chosen() {
            Shell.state = { scheduledTasks: editorState({}, { weekdays: [3] }) };
            const page = createTemporaryObject(tasksComponent, root);
            const editor = findChild(page, "scheduledTaskEditor");
            tryVerify(() => editor.opened);
            mouseClick(findChild(editor.contentItem, "weekday3"));
            compare(editor.draft.weekdays, [3]);
            mouseClick(findChild(editor.contentItem, "weekday1"));
            mouseClick(findChild(editor.contentItem, "weekday3"));
            compare(editor.draft.weekdays, [1]);
        }

        function test_the_editor_says_when_its_task_is_gone_or_uses_a_legacy_interval() {
            Shell.state = { scheduledTasks: editorState({ missing: true, legacyInterval: true }, { scheduleMode: "interval", intervalMinutes: "1" }) };
            const page = createTemporaryObject(tasksComponent, root);
            const editor = findChild(page, "scheduledTaskEditor");
            tryVerify(() => editor.opened);
            const missing = findChild(editor, "missing");
            verify(missing.visible);
            compare(missing.text, "This scheduled task no longer exists.");
            verify(findChild(editor, "legacyInterval").visible);
        }

        function test_the_base_branch_is_picked_from_the_projects_branches() {
            Shell.state = { scheduledTasks: editorState({ editing: false, branches: [
                { name: "main", current: false, isDefault: true, isRemote: false },
                { name: "release", current: false, isDefault: false, isRemote: false }], branchesTotal: 2 }) };
            const page = createTemporaryObject(tasksComponent, root);
            const editor = findChild(page, "scheduledTaskEditor");
            tryVerify(() => editor.opened);
            findChild(editor, "baseRef").forceActiveFocus();
            const asked = Shell.dispatchedActions.find(entry => entry.action === "scheduledTasks.branches");
            compare(asked.payload.projectId, "api");
            const branches = findChild(editor, "branches");
            tryVerify(() => branches.opened);
            const list = branches.contentItem;
            tryVerify(() => list.count === 2);
            list.currentIndex = 1;
            mouseClick(list.currentItem);
            compare(editor.draft.baseRef, "release");
        }
    }
}
