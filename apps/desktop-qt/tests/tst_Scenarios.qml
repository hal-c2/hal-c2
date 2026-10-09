import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// Behaviour scenarios for the native bricks, one Given/When/Then per test,
// driven through the Shell test double: the shell's state goes in as
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
            // The list brings the active thread into view a turn later, which
            // moves the cursor: let it, before any key is pressed.
            wait(0);
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

        function test_given_a_hovered_thread_when_settle_is_clicked_then_the_shell_settles_it() {
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

        function test_given_a_snoozed_thread_when_wake_is_clicked_then_the_shell_unsnoozes_it() {
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

        function test_given_build_mode_when_shift_tab_is_pressed_then_plan_mode_is_requested() {
            const composer = createComposer({
                showInteractionModeToggle: true,
                interactionMode: "default"
            });
            const input = findChild(composer, "input");
            input.forceActiveFocus();
            keyClick(Qt.Key_Backtab, Qt.ShiftModifier);
            compare(lastDispatch().action, "composer.interactionMode.set");
            compare(lastDispatch().payload.mode, "plan");
            verify(input.activeFocus, "the editor keeps the keyboard");
        }

        function test_given_an_empty_composer_when_up_is_pressed_then_the_previous_prompt_is_recalled() {
            const composer = createComposer({});
            const input = findChild(composer, "input");
            input.forceActiveFocus();
            keyClick(Qt.Key_Up);
            compare(lastDispatch().action, "composer.history.step");
            compare(lastDispatch().payload.direction, "backward");
            Shell.publishComposerText("Run the tests", 13);
            compare(input.text, "Run the tests");
        }

        function test_given_a_second_line_when_up_is_pressed_then_the_caret_moves_instead() {
            const composer = createComposer({});
            const input = findChild(composer, "input");
            input.forceActiveFocus();
            input.text = "first\nsecond";
            input.cursorPosition = input.length;
            keyClick(Qt.Key_Up);
            verify(!Shell.dispatchedActions.some(entry => entry.action === "composer.history.step"));
        }

        function test_given_the_shell_owns_a_toolbar_shortcut_when_it_opens_a_control_then_the_native_control_opens_data() {
            return [
                { tag: "effort", command: "composer.effort", picker: "effortPicker" },
                { tag: "access mode", command: "composer.mode", picker: "runtimeModePicker" },
                { tag: "host", command: "composer.host", picker: "hostPicker" },
                { tag: "workspace", command: "composer.workspace", picker: "envModePicker" },
                { tag: "branch", command: "composer.branch", picker: "branchPicker" }
            ];
        }

        function test_given_the_shell_owns_a_toolbar_shortcut_when_it_opens_a_control_then_the_native_control_opens(data) {
            const composer = createComposer({
                options: [{
                    type: "select",
                    id: "effort",
                    label: "Effort",
                    value: "high",
                    choices: [{ id: "high", label: "High" }, { id: "low", label: "Low" }]
                }],
                runtimeModes: [{ value: "approval-required", label: "Ask" }, { value: "auto", label: "Auto" }]
            });
            Shell.state = Object.assign({}, Shell.state, {
                workspace: {
                    environments: [
                        { environmentId: "here", key: "here", label: "This machine" },
                        { environmentId: "there", key: "there", label: "Build box" }
                    ],
                    activeEnvironmentId: "here",
                    environmentChangeable: true,
                    envMode: "local",
                    envModeLabel: "Current checkout",
                    envModeChangeable: true,
                    git: null,
                    canOpenPullRequest: false,
                    branch: "main",
                    branchChangeable: true,
                    branchSwitchPending: false,
                    branches: [],
                    branchesTotal: 0,
                    branchesLoading: false
                }
            });
            const picker = findChild(composer, data.picker);
            verify(!!picker, data.picker);
            Shell.actionRequested("composer.control.open", { command: data.command });
            tryCompare(picker.popup ?? picker, "visible", true);
        }

        function test_given_a_thread_on_a_branch_when_the_branch_picker_opens_then_the_refs_are_loaded_unfiltered() {
            const composer = createComposer({});
            Shell.state = Object.assign({}, Shell.state, {
                workspace: {
                    environments: [],
                    activeEnvironmentId: "here",
                    environmentChangeable: false,
                    envMode: "local",
                    envModeLabel: "Local checkout",
                    envModeChangeable: false,
                    git: null,
                    canOpenPullRequest: false,
                    branch: "feature/tax",
                    branchChangeable: true,
                    branchSwitchPending: false,
                    branchQuery: "old",
                    branches: [],
                    branchesTotal: 0,
                    branchesLoading: false
                }
            });
            const picker = findChild(composer, "branchPicker");
            verify(!!picker, "branchPicker");
            const searches = () => Shell.dispatchedActions.filter(entry => entry.action === "workspace.branch.search");
            picker.open();
            tryCompare(picker, "opened", true);
            compare(searches().length, 1);
            compare(searches()[0].payload.query, "");
            picker.close();
            tryCompare(picker, "visible", false);
            compare(searches().length, 1);
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

        function pickerModel(slug, name, overrides) {
            return Object.assign({
                slug: slug,
                name: name,
                shortName: null,
                subProvider: null,
                isFavorite: false,
                isCustom: false,
                isNew: false,
                isLegacy: false,
                isUnavailable: false,
                disabledReason: null
            }, overrides ?? {});
        }

        function pickerInstance(instanceId, driverKind, displayName, models, overrides) {
            return Object.assign({
                instanceId: instanceId,
                driverKind: driverKind,
                displayName: displayName,
                accentColor: null,
                iconUrl: null,
                initials: displayName.slice(0, 2).toUpperCase(),
                showBadge: false,
                status: "ready",
                isAvailable: true,
                unavailableReason: null,
                models: models
            }, overrides ?? {});
        }

        // The Control key, which Qt calls Meta on macOS.
        readonly property int ctrl: Qt.platform.os === "osx" ? Qt.MetaModifier : Qt.ControlModifier

        function chord(key, shift) {
            return {
                key: key,
                ctrlKey: true,
                metaKey: false,
                shiftKey: shift,
                altKey: false,
                label: (shift ? "Ctrl+Shift+" : "Ctrl+") + key
            };
        }

        // "the catalogue lists models from Codex and Claude": the catalogue
        // Shell.state.modelPicker carries, with the default chords.
        function codexAndClaude(overrides) {
            return {
                instances: [pickerInstance("codex", "codex", "Codex", [pickerModel("gpt-5.5", "GPT-5.5", overrides?.gpt55), pickerModel("gpt-5.4", "GPT-5.4")]), pickerInstance("claudeAgent", "claudeAgent", "Claude", [pickerModel("opus", "Claude Opus", overrides?.opus), pickerModel("sonnet", "Claude Sonnet"), pickerModel("haiku", "Claude Haiku")])].concat(overrides?.extra ?? []),
                locked: false,
                shortcut: "Ctrl+Shift+M",
                previousProvider: chord("arrowup", true),
                nextProvider: chord("arrowdown", true),
                jump: [1, 2, 3, 4, 5, 6, 7, 8, 9].map(index => chord(String(index), false))
            };
        }

        function createPicker(catalogue, selectedInstanceId = "codex", selectedModel = "gpt-5.5") {
            Shell.state = {
                composer: Object.assign(Shell.defaultComposer(), {
                    selectedInstanceId: selectedInstanceId,
                    selectedModel: selectedModel
                }),
                modelPicker: catalogue,
                workspace: null
            };
            const composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            const picker = findChild(composer, "modelPicker");
            verify(!!picker, "Object exists");
            tryCompare(picker, "enabled", true);
            return picker;
        }

        function togglePicker(picker, open) {
            Shell.actionRequested("composer.modelPicker.toggle", {});
            tryCompare(picker.popup, "visible", open);
            if (open) {
                tryCompare(picker.popup, "opened", true);
            }
        }

        function inPicker(picker, name) {
            tryVerify(() => findChild(picker.popup.contentItem, name) !== null, 2000, name);
            return findChild(picker.popup.contentItem, name);
        }

        function listed(picker) {
            return picker.rows.filter(row => row.kind === "model").map(row => row.instance.instanceId + ":" + row.model.slug);
        }

        function modelSelections() {
            return Shell.dispatchedActions.filter(entry => entry.action === "composer.model.select");
        }

        function test_given_the_shell_owns_the_model_shortcut_when_it_requests_the_picker_then_the_native_picker_toggles() {
            const picker = createPicker(codexAndClaude());
            togglePicker(picker, true);
            togglePicker(picker, false);
        }

        function test_given_codex_and_claude_when_the_picker_opens_then_it_has_a_section_for_each_provider() {
            const picker = createPicker(codexAndClaude());
            togglePicker(picker, true);
            verify(inPicker(picker, "modelPickerRail").visible);
            const codex = inPicker(picker, "modelPickerProvider:codex");
            verify(inPicker(picker, "modelPickerProvider:claudeAgent").visible);
            mouseClick(codex);
            tryCompare(picker, "view", "codex");
            compare(listed(picker), ["codex:gpt-5.5", "codex:gpt-5.4"]);
        }

        function test_given_claude_opus_is_chosen_then_the_picker_names_it_and_its_provider() {
            const picker = createPicker(codexAndClaude(), "claudeAgent", "opus");
            compare(picker.triggerTitle, "Claude Opus");
            compare(picker.activeInstance.displayName, "Claude");
            const icon = findChild(picker, "modelPickerIcon");
            verify(!!icon, "Object exists");
            verify(icon.visible);
            compare(icon.driverKind, "claudeAgent");
        }

        function test_given_codex_and_claude_when_claude_opus_is_chosen_then_the_shell_switches_and_the_picker_closes() {
            const picker = createPicker(codexAndClaude());
            togglePicker(picker, true);
            mouseClick(inPicker(picker, "modelPickerProvider:claudeAgent"));
            tryCompare(picker, "view", "claudeAgent");
            mouseClick(inPicker(picker, "modelPickerRow:claudeAgent:opus"));
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "composer.model.select");
            compare(lastDispatch().payload.instanceId, "claudeAgent");
            compare(lastDispatch().payload.model, "opus");
            tryCompare(picker.popup, "visible", false);
        }

        function test_given_codex_and_claude_when_searching_claude_then_only_claudes_models_are_listed() {
            const picker = createPicker(codexAndClaude());
            togglePicker(picker, true);
            const search = inPicker(picker, "modelPickerSearch");
            tryCompare(search, "activeFocus", true);
            for (const key of "claude") {
                keyClick(key);
            }
            tryCompare(picker, "query", "claude");
            compare(inPicker(picker, "modelPickerRail").visible, false);
            compare(listed(picker).sort(), ["claudeAgent:haiku", "claudeAgent:opus", "claudeAgent:sonnet"]);
        }

        function test_given_a_favourite_when_the_picker_opens_then_it_is_listed_first_and_can_be_unfavourited() {
            const picker = createPicker(codexAndClaude({
                opus: {
                    isFavorite: true
                }
            }));
            togglePicker(picker, true);
            compare(picker.view, "favorites");
            compare(listed(picker)[0], "claudeAgent:opus");
            const star = inPicker(picker, "modelPickerFavorite:claudeAgent:opus");
            compare(star.favorite, true);
            mouseClick(star);
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "composer.model.favorite.toggle");
            compare(lastDispatch().payload.instanceId, "claudeAgent");
            compare(lastDispatch().payload.model, "opus");
        }

        function test_given_a_disabled_model_then_it_shows_its_reason_and_cannot_be_chosen() {
            const reason = "Start a new thread to use this model.";
            const picker = createPicker(codexAndClaude({
                gpt55: {
                    disabledReason: reason
                }
            }), "codex", "gpt-5.4");
            togglePicker(picker, true);
            const row = inPicker(picker, "modelPickerRow:codex:gpt-5.5");
            compare(row.disabledReason, reason);
            verify(row.opacity < 1);
            mouseClick(row);
            wait(50);
            compare(modelSelections().length, 0);
            verify(picker.popup.visible);
        }

        function test_given_cursor_is_unavailable_then_it_is_listed_with_the_reason_and_cannot_be_chosen() {
            const reason = "Cursor — Unavailable. Not installed.";
            const picker = createPicker(codexAndClaude({
                extra: [pickerInstance("cursor", "cursor", "Cursor", [], {
                        status: "error",
                        isAvailable: false,
                        unavailableReason: reason
                    })]
            }));
            togglePicker(picker, true);
            const cursor = inPicker(picker, "modelPickerProvider:cursor");
            verify(cursor.visible);
            compare(cursor.tooltip, reason);
            compare(cursor.available, false);
            mouseClick(cursor);
            wait(50);
            compare(picker.view, "codex");
        }

        function test_given_codex_and_claude_when_down_and_enter_are_pressed_then_the_second_model_is_chosen() {
            const picker = createPicker(codexAndClaude());
            togglePicker(picker, true);
            tryCompare(inPicker(picker, "modelPickerSearch"), "activeFocus", true);
            const second = listed(picker)[1];
            keyClick(Qt.Key_Down);
            keyClick(Qt.Key_Return);
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "composer.model.select");
            compare(lastDispatch().payload.instanceId + ":" + lastDispatch().payload.model, second);
        }

        function test_given_codex_and_claude_when_the_next_provider_shortcut_is_pressed_then_only_claudes_models_are_listed() {
            const picker = createPicker(codexAndClaude());
            togglePicker(picker, true);
            compare(picker.view, "codex");
            tryCompare(inPicker(picker, "modelPickerSearch"), "activeFocus", true);
            keyClick(Qt.Key_Down, ctrl | Qt.ShiftModifier);
            tryCompare(picker, "view", "claudeAgent");
            compare(listed(picker), ["claudeAgent:opus", "claudeAgent:sonnet", "claudeAgent:haiku"]);
        }

        function test_given_codex_and_claude_when_the_second_jump_shortcut_is_pressed_then_the_second_model_is_chosen() {
            const picker = createPicker(codexAndClaude());
            togglePicker(picker, true);
            tryCompare(inPicker(picker, "modelPickerSearch"), "activeFocus", true);
            const second = listed(picker)[1];
            keyClick(Qt.Key_2, ctrl);
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "composer.model.select");
            compare(lastDispatch().payload.instanceId + ":" + lastDispatch().payload.model, second);
            tryCompare(picker.popup, "visible", false);
        }

        // Scenario: A notification's action runs it (features/timeline/notifications.feature)
        function test_given_a_toast_with_an_action_when_the_action_is_clicked_then_its_action_runs() {
            Shell.state = {
                toasts: {
                    items: [
                        {
                            id: "native:1",
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
            tryVerify(() => findChild(host, "notificationAction-native:1-restart") !== null);
            const action = findChild(host, "notificationAction-native:1-restart");
            tryCompare(action, "visible", true);
            mouseClick(action);
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "notification.action");
            compare(lastDispatch().payload.id, "native:1");
            compare(lastDispatch().payload.actionId, "restart");
        }

        // Scenario: Dismissing the last notification hides the notifications (features/timeline/notifications.feature)
        function test_given_a_toast_when_dismiss_is_clicked_then_it_is_dismissed() {
            Shell.state = {
                toasts: {
                    items: [
                        {
                            id: "native:2",
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
            tryVerify(() => findChild(host, "notificationDismiss-native:2") !== null);
            // The card slides in, and the stack takes its height once the card is measured.
            const card = findChild(host, "notification-native:2");
            tryVerify(() => card.opacity === 1 && host.height > 0, 5000, "the toast is shown");
            mouseClick(findChild(host, "notificationDismiss-native:2"));
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "notification.dismiss");
            compare(lastDispatch().payload.id, "native:2");
            Shell.state = {
                toasts: {
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
                    editors: []
                }
            };
            Terminals.available = true;
            Terminals.open = false;
            const workspace = createTemporaryObject(workspaceComponent, root);
            verify(!!workspace, "Component exists");
            const toggle = findChild(workspace, "terminalToggle");
            verify(!!toggle, "Object exists");
            tryCompare(toggle, "visible", true);
            mouseClick(toggle);
            tryCompare(Shell, "dispatchCount", 1);
            compare(lastDispatch().action, "terminal.toggle");
            Terminals.available = false;
        }
    }
}
