import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/settings/projects.feature and project-defaults.feature: the Project
// section draws what ProjectSettingsController publishes and sends its
// choices back.
Item {
    id: root
    width: 900
    height: 900

    Component {
        id: pageComponent
        ProjectSettings {
            width: 880
            height: 880
        }
    }

    function choice(value, options) {
        return { value: value, label: value, mixed: false, resettable: false,
                 options: options.map(option => ({ value: option, label: option, description: "" })) };
    }

    function state(overrides) {
        return Object.assign({ open: true, status: "ready", message: "", name: "shop", available: true,
                               note: "Can't find a setting? Keep this project picked above and hop to any other settings page.",
                               icon: { label: "Automatic", emoji: "", custom: false },
                               checkouts: [{ key: "laptop:shop", environment: "laptop", path: "/home/laptop/shop" },
                                           { key: "server:shop", environment: "server", path: "/home/server/shop" }],
                               removal: { title: "Remove this project everywhere", description: "", button: "Remove all entries" },
                               model: { value: "", label: "Automatic", mixed: false, automatic: true, none: false, resettable: false,
                                        models: [{ key: "claude:opus", label: "Claude · Opus" }] },
                               permissions: root.choice("full-access", ["approval-required", "full-access"]),
                               workspace: root.choice("local", ["local", "worktree"]),
                               submodules: root.choice("recursive", ["recursive", "none"]) }, overrides);
    }

    Component {
        id: shortPage
        ProjectSettings {
            width: 880
            height: 240
        }
    }

    TestCase {
        name: "ProjectSettingsTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_a_picked_project_shows_its_checkouts_and_removes_one() {
            Shell.state = { settingsScope: { editable: true, kind: "project" }, projectSettings: root.state({}) };
            const page = createTemporaryObject(pageComponent, root);
            verify(findChild(page, "identity").visible);
            verify(findChild(page, "checkouts").visible);
            verify(findChild(page, "note").visible);
            mouseClick(findChild(findChild(page, "checkout:server:shop"), "remove"));
            compare(Shell.dispatchedActions[0].action, "projectSettings.remove");
            compare(Shell.dispatchedActions[0].payload.key, "server:shop");
        }

        function test_without_a_project_only_the_defaults_show() {
            Shell.state = { settingsScope: { editable: true, kind: "all" }, projectSettings: root.state({
                status: "pick", message: "Choose a project to manage its name, icon, checkouts and actions.", note: undefined }) };
            const page = createTemporaryObject(pageComponent, root);
            verify(!findChild(page, "identity").visible);
            compare(findChild(page, "message").text, "Choose a project to manage its name, icon, checkouts and actions.");
            verify(findChild(page, "model").visible);
        }

        function test_a_default_is_chosen_and_reset() {
            const workspace = root.choice("worktree", ["local", "worktree"]);
            workspace.resettable = true;
            Shell.state = { settingsScope: { editable: true, kind: "project" }, projectSettings: root.state({ workspace: workspace }) };
            const page = createTemporaryObject(pageComponent, root);
            const row = findChild(page, "workspace");
            findChild(row, "control").activated(0);
            compare(Shell.dispatchedActions[0].action, "projectSettings.workspace");
            compare(Shell.dispatchedActions[0].payload.value, "local");
            mouseClick(findChild(row, "reset"));
            compare(Shell.dispatchedActions[1].action, "projectSettings.reset");
            compare(Shell.dispatchedActions[1].payload.key, "workspace");
        }

        function test_the_model_offers_automatic_first() {
            Shell.state = { settingsScope: { editable: true, kind: "all" }, projectSettings: root.state({}) };
            const page = createTemporaryObject(pageComponent, root);
            const control = findChild(findChild(page, "model"), "control");
            compare(control.currentIndex, 0);
            control.activated(1);
            compare(Shell.dispatchedActions[0].payload.key, "claude:opus");
            control.activated(0);
            compare(Shell.dispatchedActions[1].payload.key, "");
        }

        // settings/search-and-navigation.feature: the Default model result
        // brings the setting into view again after the user scrolled away.
        function test_the_default_model_result_is_brought_into_view_again() {
            const route = seq => ({ kind: "settings", section: "/settings/projects", target: "model", targetSeq: seq });
            Shell.state = { settingsScope: { editable: true, kind: "project" }, projectSettings: root.state({}), route: route(1) };
            const page = createTemporaryObject(shortPage, root);
            const scroll = findChild(page, "scroll");
            tryVerify(() => scroll.contentY > 0, 1000, "the model row is scrolled to");
            const revealed = scroll.contentY;
            scroll.contentY = 0;
            Shell.state = Object.assign({}, Shell.state, { route: route(2) });
            tryCompare(scroll, "contentY", revealed);
        }
    }
}
