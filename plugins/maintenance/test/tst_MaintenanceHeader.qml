// Run from a hal-c2 checkout, with QT_QPA_PLATFORM=offscreen:
//   qmltestrunner -import apps/desktop-qt/tests/imports -import apps/desktop-qt/qml \
//     -input <this plugin>/test/tst_MaintenanceHeader.qml
import QtQuick
import QtTest

// The header above a maintenance thread and the mark beside its row, against a
// faked `threads` topic.
Item {
    id: test

    width: 700
    height: 200

    function threads(status, extra) {
        return {
            "t-1": Object.assign({
                id: "run-1",
                repository: "acme/api",
                status: status,
                mode: "fix",
                branch: "maintenance/2026-11-02",
                base: "main",
                prUrl: null,
                error: null,
                publishError: null,
                date: "2026-11-02"
            }, extra ?? {})
        };
    }

    QtObject {
        id: plugin

        property var watchers: ({})
        property var calls: []
        property string refusal: ""

        function watch(topic, callback, environment) {
            watchers[topic] = callback;
            return 1;
        }

        function unwatch(handle) {
        }

        function call(method, input, callback, environment) {
            calls = calls.concat([
                {
                    method: method,
                    input: input,
                    environment: environment
                }
            ]);
            callback(null, refusal || null);
        }

        function publish(value) {
            watchers["threads"](value);
        }
    }

    Loader {
        id: loader

        width: test.width
    }

    TestCase {
        name: "MaintenanceHeader"
        when: windowShown

        function find(name) {
            return findChild(loader.item, name);
        }

        function load(file) {
            plugin.watchers = {};
            plugin.calls = [];
            plugin.refusal = "";
            loader.source = "";
            loader.setSource(Qt.resolvedUrl("../ui/" + file), {
                plugin: plugin,
                thread: {
                    id: "t-1",
                    environmentId: "laptop"
                }
            });
            tryVerify(() => loader.status === Loader.Ready && plugin.watchers["threads"] !== undefined);
        }

        function test_the_header_hides_for_a_thread_without_a_run() {
            load("MaintenanceHeader.qml");
            plugin.publish({});
            verify(!loader.item.visible);
        }

        function test_a_waiting_run_opens_its_pull_request_on_its_machine() {
            load("MaintenanceHeader.qml");
            plugin.publish(test.threads("waiting"));
            compare(find("maintenanceHeaderTitle").text, "Maintenance of acme/api");
            verify(find("maintenanceHeaderStatus").text.indexOf("maintenance/2026-11-02 from main") === 0);
            verify(!find("maintenanceHeaderCancel").visible);
            mouseClick(find("maintenanceHeaderPublish"));
            compare(plugin.calls, [
                {
                    method: "publish",
                    input: {
                        runId: "run-1"
                    },
                    environment: "laptop"
                }
            ]);
        }

        function test_a_running_run_can_be_cancelled() {
            load("MaintenanceHeader.qml");
            plugin.publish(test.threads("running"));
            verify(!find("maintenanceHeaderPublish").visible);
            mouseClick(find("maintenanceHeaderCancel"));
            compare(plugin.calls.map(each => each.method), ["cancel"]);
        }

        function test_a_refused_pull_request_says_why() {
            load("MaintenanceHeader.qml");
            plugin.publish(test.threads("waiting", {
                publishError: "gh pr create failed: not signed in"
            }));
            compare(find("maintenanceHeaderProblem").text, "gh pr create failed: not signed in");
            plugin.refusal = "pullRequests:write is not granted.";
            mouseClick(find("maintenanceHeaderPublish"));
            compare(find("maintenanceHeaderProblem").text, plugin.refusal);
        }

        function test_the_row_mark_follows_the_run() {
            load("MaintenanceRowMark.qml");
            plugin.publish(test.threads("running"));
            compare(loader.item.label, "Maintaining");
            plugin.publish(test.threads("waiting"));
            compare(loader.item.label, "Ready");
            plugin.publish(test.threads("published"));
            compare(loader.item.label, "PR open");
        }
    }
}
