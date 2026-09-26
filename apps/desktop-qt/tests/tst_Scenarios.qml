import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// Behaviour scenarios for the native bricks, one Given/When/Then per test,
// driven through the Shell test double: the page state goes in as
// Shell.state and the outcome is what the brick dispatches back.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: sidebarComponent
        Sidebar {
            width: 272
            height: 450
            showFooter: false
        }
    }

    Component {
        id: composerComponent
        Composer {
            width: 800
            height: 650
        }
    }

    Component {
        id: notificationsComponent
        Notifications {
            width: 340
            height: implicitHeight
        }
    }

    Component {
        id: workspaceComponent
        Workspace {
            width: 900
            height: 52
        }
    }

    TestCase {
        name: "Scenarios"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function cleanup() {
            Shell.reset();
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

        function sidebarState(overrides) {
            return Object.assign({
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
                active: [thread("first", qsTr("First")), thread("second", qsTr("Second"))]
            }, overrides);
        }

        function lastDispatch() {
            return Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
        }

        function createSidebar(overrides) {
            Shell.state = {
                sidebar: sidebarState(overrides)
            };
            const sidebar = createTemporaryObject(sidebarComponent, root);
            verify(!!sidebar, "Component exists");
            const list = findChild(sidebar, "list");
            verify(!!list, "Object exists");
            tryVerify(() => list.count > 0);
            return sidebar;
        }

        // A row lays its actions out twice (slim and card); only one is shown.
        function findShown(item, name) {
            for (const child of item.children) {
                if (child.objectName === name && child.visible) {
                    return child;
                }
                const found = findShown(child, name);
                if (found !== null) {
                    return found;
                }
            }
            return null;
        }

        function waitForRow(sidebar, key) {
            tryVerify(() => findChild(sidebar, "threadRow:" + key) !== null);
            return findChild(sidebar, "threadRow:" + key);
        }

        function createComposer(overrides) {
            Shell.state = {
                composer: Object.assign(Shell.defaultComposer(), overrides),
                workspace: null
            };
            const composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            return composer;
        }

        function test_given_two_threads_when_arrow_down_and_enter_then_the_second_thread_opens() {
            const sidebar = createSidebar({
                activeThreadKey: "first"
            });
            const list = findChild(sidebar, "list");
            list.forceActiveFocus();
            tryVerify(() => list.cursorKey.length > 0);
            keyClick(Qt.Key_Down);
            keyClick(Qt.Key_Return);
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "thread.open");
            compare(lastDispatch().payload.key, "second");
        }

        function test_given_a_focused_thread_row_when_shift_f10_is_pressed_then_its_context_menu_is_requested() {
            const sidebar = createSidebar({
                activeThreadKey: "first"
            });
            const list = findChild(sidebar, "list");
            waitForRow(sidebar, "first");
            list.forceActiveFocus();
            tryCompare(list, "cursorKey", "first");
            // The menu is anchored on the row, so it needs the laid-out delegate.
            tryVerify(() => list.itemAtIndex(list.cursorIndex) !== null);
            keyClick(Qt.Key_F10, Qt.ShiftModifier);
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "thread.menu");
            compare(lastDispatch().payload.key, "first");
            verify(typeof lastDispatch().payload.x === "number");
        }

        function test_given_a_hovered_thread_when_settle_is_clicked_then_the_page_settles_it() {
            const sidebar = createSidebar({});
            const row = waitForRow(sidebar, "second");
            mouseMove(row, 100, 40);
            tryCompare(row, "showActions", true);
            tryVerify(() => findShown(row, "settleAction") !== null);
            mouseClick(findShown(row, "settleAction"));
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "thread.settle");
            compare(lastDispatch().payload.key, "second");
        }

        function test_given_a_snoozed_thread_when_wake_is_clicked_then_the_page_unsnoozes_it() {
            const sidebar = createSidebar({
                active: [thread("first", qsTr("First"))],
                snoozed: [thread("sleeper", qsTr("Sleeper"))]
            });
            const row = waitForRow(sidebar, "sleeper");
            tryCompare(row, "section", "snoozed");
            mouseMove(row, 100, row.height / 2);
            tryCompare(row, "showActions", true);
            tryVerify(() => findShown(row, "wakeAction") !== null);
            compare(findShown(row, "settleAction"), null);
            mouseClick(findShown(row, "wakeAction"));
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "thread.unsnooze");
            compare(lastDispatch().payload.key, "sleeper");
        }

        function test_given_a_project_scope_when_new_thread_is_clicked_then_the_thread_starts_in_that_project() {
            const sidebar = createSidebar({
                scopeProjectKey: "project"
            });
            const button = findChild(sidebar, "newThread");
            verify(!!button, "Object exists");
            mouseClick(button);
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "thread.new");
            compare(lastDispatch().payload.projectKey, "project");
        }

        // Unmodified keys are never registered as window shortcuts, so Enter
        // reaches the native editor in the real shell too.
        function test_given_a_draft_when_enter_is_pressed_then_it_submits_in_the_foreground() {
            const composer = createComposer({});
            const input = findChild(composer, "input");
            verify(!!input, "Object exists");
            input.forceActiveFocus();
            input.text = qsTr("Run the migration");
            keyClick(Qt.Key_Return);
            const submit = Shell.dispatchedActions.find(entry => entry.action === "composer.submit");
            verify(!!submit, "composer.submit dispatched");
            compare(submit.payload.intent, "foreground");
            compare(submit.payload.text, qsTr("Run the migration"));
        }

        function test_given_build_mode_when_the_mode_toggle_is_clicked_then_plan_mode_is_requested() {
            const composer = createComposer({
                showInteractionModeToggle: true,
                interactionMode: "default"
            });
            const toggle = findChild(composer, "planToggle");
            verify(!!toggle, "Object exists");
            tryCompare(toggle, "visible", true);
            compare(toggle.text, qsTr("Build"));
            mouseClick(toggle);
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "composer.interactionMode.set");
            compare(lastDispatch().payload.mode, "plan");
        }

        function test_given_a_running_turn_and_an_empty_draft_when_the_primary_button_is_clicked_then_the_turn_is_interrupted() {
            const composer = createComposer({
                isRunning: true,
                canSend: false
            });
            const button = findChild(composer, "primaryAction");
            verify(!!button, "Object exists");
            tryCompare(button, "stopMode", true);
            mouseClick(button);
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "composer.interrupt");
            verify(!Shell.dispatchedActions.some(entry => entry.action === "composer.submit"));
        }

        function test_given_the_page_owns_the_model_shortcut_when_it_requests_the_picker_then_the_native_picker_toggles() {
            const composer = createComposer({
                instances: [
                    {
                        instanceId: "codex",
                        displayName: qsTr("Codex"),
                        models: [
                            {
                                name: qsTr("GPT"),
                                slug: "gpt",
                                disabledReason: null
                            }
                        ]
                    }
                ],
                selectedInstanceId: "codex",
                selectedModel: "gpt"
            });
            const picker = findChild(composer, "modelPicker");
            verify(!!picker, "Object exists");
            tryCompare(picker, "enabled", true);
            Shell.actionRequested("composer.modelPicker.toggle", {});
            tryCompare(picker.popup, "visible", true);
            Shell.actionRequested("composer.modelPicker.toggle", {});
            tryCompare(picker.popup, "visible", false);
        }

        function test_given_a_toast_with_an_action_when_the_action_is_clicked_then_the_page_runs_that_action() {
            Shell.state = {
                notifications: {
                    items: [
                        {
                            id: "update",
                            type: "info",
                            title: qsTr("Update ready"),
                            description: null,
                            actions: [
                                {
                                    id: "restart",
                                    label: qsTr("Restart"),
                                    primary: true
                                }
                            ]
                        }
                    ]
                }
            };
            const host = createTemporaryObject(notificationsComponent, root);
            verify(!!host, "Component exists");
            tryVerify(() => findChild(host, "notificationAction-update-restart") !== null);
            const action = findChild(host, "notificationAction-update-restart");
            tryCompare(action, "visible", true);
            mouseClick(action);
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "notification.action");
            compare(lastDispatch().payload.id, "update");
            compare(lastDispatch().payload.actionId, "restart");
        }

        function test_given_a_toast_when_dismiss_is_clicked_then_the_page_dismisses_it() {
            Shell.state = {
                notifications: {
                    items: [
                        {
                            id: "copied",
                            type: "success",
                            title: qsTr("Copied"),
                            description: null,
                            actions: []
                        }
                    ]
                }
            };
            const host = createTemporaryObject(notificationsComponent, root);
            verify(!!host, "Component exists");
            tryVerify(() => findChild(host, "notificationDismiss-copied") !== null);
            mouseClick(findChild(host, "notificationDismiss-copied"));
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "notification.dismiss");
            compare(lastDispatch().payload.id, "copied");
            Shell.state = {
                notifications: {
                    items: []
                }
            };
            tryCompare(host, "visible", false);
        }

        function test_given_an_available_terminal_when_the_workspace_toggle_is_clicked_then_the_drawer_toggles() {
            Shell.state = {
                workspace: {
                    projectTitle: qsTr("Project"),
                    threadTitle: qsTr("Thread"),
                    isDraft: false,
                    renameRequestId: 0,
                    scripts: [],
                    editors: [],
                    terminalAvailable: true,
                    terminalOpen: false
                }
            };
            const workspace = createTemporaryObject(workspaceComponent, root);
            verify(!!workspace, "Component exists");
            const toggle = findChild(workspace, "terminalToggle");
            verify(!!toggle, "Object exists");
            tryCompare(toggle, "visible", true);
            mouseClick(toggle);
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "terminal.toggle");
        }
    }
}
