import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/mc/platform/openshell.feature: Settings → Review sandboxes draws what
// SandboxSettingsController publishes, and asks again only when no read is out.
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
                                               problems: [{ code: "not-installed", message: "Run `hal-c2-service openshell install` to install it." },
                                                          { code: "cgroup-v1", message: "Use cgroup v2." }] } };
            const page = createTemporaryObject(pageComponent, root);
            waitForRendering(page);
            compare(findChild(page, "sandboxProblem:not-installed").text, "Run `hal-c2-service openshell install` to install it.");
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
    }
}
