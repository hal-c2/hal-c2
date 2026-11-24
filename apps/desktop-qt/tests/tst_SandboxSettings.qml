import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/mc/platform/openshell.feature: Settings → Review sandboxes draws what
// SandboxSettingsController publishes, asks again only when no read is out, and
// runs the operations the MC offers only when this device may and none runs.
Item {
    id: root
    width: 700
    height: 500

    Component {
        id: pageComponent
        SandboxSettings {
            width: 680
            height: 480
        }
    }

    TestCase {
        name: "SandboxSettingsTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_a_read_that_is_out_cannot_be_asked_again() {
            Shell.state = { sandboxSettings: { loading: true, state: "loading", summary: "Asking", detail: "", error: null, problems: [] } };
            const page = createTemporaryObject(pageComponent, root);
            waitForRendering(page);
            const refresh = findChild(page, "sandboxRefresh");
            verify(!refresh.enabled);
            compare(refresh.text, "Checking…");
            verify(!findChild(page, "sandboxDetail").visible);
        }

        function test_each_problem_is_listed_and_refresh_asks_again() {
            Shell.state = { sandboxSettings: { loading: false, state: "attention", summary: "Review sandboxes can't run here yet.",
                                               detail: "OpenShell 0.1.7 is the version this MC pins.", error: null,
                                               problems: [{ code: "not-installed", message: "Press Install to install it." },
                                                          { code: "cgroup-v1", message: "Use cgroup v2." }] } };
            const page = createTemporaryObject(pageComponent, root);
            waitForRendering(page);
            compare(findChild(page, "sandboxProblem:not-installed").text, "Press Install to install it.");
            compare(findChild(page, "sandboxProblem:cgroup-v1").text, "Use cgroup v2.");
            mouseClick(findChild(page, "sandboxRefresh"));
            compare(Shell.dispatchedActions.length, 1);
            compare(Shell.dispatchedActions[0].action, "sandboxSettings.refresh");
        }

        function test_an_error_shows_what_the_mc_said() {
            Shell.state = { sandboxSettings: { loading: false, state: "error", summary: "Could not read whether review sandboxes can run here.",
                                               detail: "", error: "It timed out.", problems: [] } };
            const page = createTemporaryObject(pageComponent, root);
            waitForRendering(page);
            compare(findChild(page, "sandboxDetail").text, "It timed out.");
            verify(findChild(page, "sandboxRefresh").enabled);
        }

        function test_the_actions_run_what_the_mc_offers() {
            Shell.state = { sandboxSettings: { loading: false, state: "attention", summary: "", detail: "", error: null, problems: [],
                                               actions: [{ operation: "install", label: "Install" }], canManage: true,
                                               manageReason: null, busy: false, operation: null, refusal: null, confirm: null } };
            const page = createTemporaryObject(pageComponent, root);
            waitForRendering(page);
            const install = findChild(page, "sandboxAction:install");
            compare(install.text, "Install");
            verify(install.enabled);
            verify(!findChild(page, "sandboxManageReason").visible);
            mouseClick(install);
            compare(Shell.dispatchedActions.length, 1);
            compare(Shell.dispatchedActions[0].action, "sandboxSettings.run");
            compare(Shell.dispatchedActions[0].payload.operation, "install");
        }

        function test_the_actions_are_off_with_the_reason_on_a_device_that_may_not() {
            Shell.state = { sandboxSettings: { loading: false, state: "attention", summary: "", detail: "", error: null, problems: [],
                                               actions: [{ operation: "install", label: "Install" }], canManage: false,
                                               manageReason: "Pair this device with a link that grants them.", busy: false,
                                               operation: null, refusal: null, confirm: null } };
            const page = createTemporaryObject(pageComponent, root);
            waitForRendering(page);
            verify(!findChild(page, "sandboxAction:install").enabled);
            compare(findChild(page, "sandboxManageReason").text, "Pair this device with a link that grants them.");
        }

        function test_a_running_operation_shows_its_steps_and_holds_the_actions() {
            Shell.state = { sandboxSettings: { loading: false, state: "ready", summary: "", detail: "", error: null, problems: [],
                                               actions: [{ operation: "check", label: "Check" }, { operation: "uninstall", label: "Uninstall" }],
                                               canManage: true, manageReason: null, busy: true, refusal: null, confirm: null,
                                               operation: { operation: "uninstall", running: true, label: "Removing OpenShell…",
                                                            steps: ["Removing the gateway"], result: null } } };
            const page = createTemporaryObject(pageComponent, root);
            waitForRendering(page);
            compare(findChild(page, "sandboxProgress").text, "Removing OpenShell…");
            compare(findChild(page, "sandboxStep:0").text, "Removing the gateway");
            verify(!findChild(page, "sandboxResult").visible);
            verify(!findChild(page, "sandboxAction:check").enabled);
            verify(!findChild(page, "sandboxAction:uninstall").enabled);
        }

        function test_a_stop_is_asked_about_and_the_answer_dispatched() {
            Shell.state = { sandboxSettings: { loading: false, state: "ready", summary: "", detail: "", error: null, problems: [],
                                               actions: [{ operation: "uninstall", label: "Uninstall" }], canManage: true,
                                               manageReason: null, busy: false, refusal: null,
                                               operation: { operation: "uninstall", running: false, label: "", steps: [],
                                                            result: { ok: false, message: "1 of this MC's review sandboxes is on the gateway." } },
                                               confirm: { text: "Stop 1 review and go ahead?" } } };
            const page = createTemporaryObject(pageComponent, root);
            waitForRendering(page);
            compare(findChild(page, "sandboxConfirmText").text, "Stop 1 review and go ahead?");
            // The question carries the outcome; it is not said twice.
            verify(!findChild(page, "sandboxResult").visible);
            mouseClick(findChild(page, "sandboxConfirmYes"));
            mouseClick(findChild(page, "sandboxConfirmCancel"));
            compare(Shell.dispatchedActions.map((entry) => entry.action), ["sandboxSettings.confirm", "sandboxSettings.cancel"]);
        }
    }
}
