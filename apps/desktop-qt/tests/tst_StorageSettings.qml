import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/settings/storage.feature and scopes-and-inheritance.feature: the
// Storage section draws what StorageSettingsController and
// SettingsScopeController publish.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: storageComponent
        StorageSettings {
            width: 880
            height: 680
        }
    }

    function scope(overrides) {
        return Object.assign({ kind: "all", projectKey: "", environmentId: "", projectLabel: "All projects",
                               environmentLabel: "All environments", connective: "across", message: "",
                               projects: [{ key: "repo:hal-c2", title: "hal-c2" }],
                               environments: [{ id: "env-a", label: "This machine", online: true },
                                              { id: "box", label: "Build box", online: false }],
                               editable: true, disabledReason: "" }, overrides);
    }

    function rule(overrides) {
        return Object.assign({ key: "worktreeAfterDays", title: "Delete inactive worktrees", description: "",
                               days: true, value: 8, mixed: false }, overrides);
    }

    TestCase {
        name: "StorageSettingsTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_a_mixed_rule_says_so_and_a_choice_applies_everywhere() {
            Shell.state = { settingsScope: root.scope({}),
                            storageSettings: { status: "ready", projectScope: false, mode: { value: "inherit", mixed: false },
                                               worktrees: [root.rule({ mixed: true, value: null })], artifacts: [] } };
            const page = createTemporaryObject(storageComponent, root);
            const row = findChild(page, "storageRule:worktreeAfterDays");
            verify(findChild(row, "mixed").visible);
            verify(!findChild(row, "days").visible);
            const control = findChild(row, "control");
            verify(!control.checked);
            mouseClick(control);
            compare(Shell.dispatchedActions[0].action, "storageSettings.set");
            compare(Shell.dispatchedActions[0].payload.value, 8);
        }

        function test_an_unsupported_machine_asks_for_an_update_and_offers_the_others() {
            Shell.state = { settingsScope: root.scope({}),
                            storageSettings: { status: "unsupported", projectScope: false,
                                               notice: "Update the selected environments to use storage cleanup, or choose a machine that supports it.",
                                               eligible: [{ id: "box", label: "Build box" }], mode: { value: "inherit", mixed: false },
                                               worktrees: [], artifacts: [] } };
            const page = createTemporaryObject(storageComponent, root);
            verify(findChild(page, "storageNotice").visible);
            mouseClick(findChild(page, "eligible_box"));
            compare(Shell.dispatchedActions[0].action, "settingsScope.environment");
            compare(Shell.dispatchedActions[0].payload.id, "box");
        }

        function test_a_scope_that_cannot_change_says_why_and_locks_the_rules() {
            Shell.state = { settingsScope: root.scope({ editable: false, environmentId: "box", environmentLabel: "Build box", connective: "on",
                                                        disabledReason: "Reconnect the selected environment to change this setting." }),
                            storageSettings: { status: "ready", projectScope: false, mode: { value: "inherit", mixed: false },
                                               worktrees: [root.rule({})], artifacts: [] } };
            const page = createTemporaryObject(storageComponent, root);
            compare(findChild(page, "scopeNotice").text, "Reconnect the selected environment to change this setting.");
            verify(!findChild(findChild(page, "storageRule:worktreeAfterDays"), "control").enabled);
            // An offline environment is marked where it is chosen.
            verify(findChild(page, "scopeEnvironment").model.indexOf("Build box · Offline") > 0);
        }

        function test_a_project_chooses_how_its_worktrees_are_cleaned() {
            Shell.state = { settingsScope: root.scope({ kind: "project", projectKey: "repo:hal-c2", projectLabel: "hal-c2" }),
                            storageSettings: { status: "ready", projectScope: true, mode: { value: "inherit", mixed: false },
                                               worktrees: [], artifacts: [] } };
            const page = createTemporaryObject(storageComponent, root);
            const mode = findChild(page, "storageMode");
            verify(mode.visible);
            const combo = findChild(mode, "control");
            combo.activated(2);
            compare(Shell.dispatchedActions[0].action, "storageSettings.mode");
            compare(Shell.dispatchedActions[0].payload.mode, "custom");
        }
    }
}
