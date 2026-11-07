// Run from a hal-c2 checkout, with QT_QPA_PLATFORM=offscreen:
//   qmltestrunner -import apps/desktop-qt/tests/imports -import apps/desktop-qt/qml \
//     -input <this plugin>/test/tst_MaintenancePage.qml
import QtQuick
import QtTest

// A TestCase is never visible, so what it clicks lives beside it.
Item {
    id: test

    width: 900
    height: 700

    function run(id, status, extra) {
        return Object.assign({
            id: id,
            repository: "acme/api",
            trigger: "manual",
            mode: "fix",
            categories: ["deps", "docs-drift"],
            date: "2026-11-02",
            threadId: "t-" + id,
            status: status,
            branch: "maintenance/2026-11-02",
            base: "main",
            createdAt: 1,
            report: null,
            prUrl: null,
            error: null,
            publishError: null
        }, extra ?? {});
    }

    readonly property var maintenance: ({
            repositories: [
                {
                    repository: "acme/api",
                    project: "api",
                    nextRunAt: Date.UTC(2026, 10, 9, 6, 0),
                    lastRunAt: null
                },
                {
                    repository: "acme/web",
                    project: null,
                    nextRunAt: null,
                    lastRunAt: null
                }
            ],
            runs: [run("old", "done", {
                    createdAt: 1,
                    report: {
                        summary: "Nothing needed doing.",
                        categories: [
                            {
                                category: "deps"
                            },
                            {
                                category: "docs-drift"
                            }
                        ]
                    }
                }), run("new", "waiting", {
                    createdAt: 2,
                    report: {
                        summary: "Bumped lodash; react 19 needs a human.",
                        categories: [
                            {
                                category: "deps",
                                applied: [
                                    {
                                        title: "chore(deps): bump lodash"
                                    }
                                ],
                                deferred: [
                                    {
                                        item: "react 18 → 19",
                                        reason: "major bump",
                                        command: "npm install react@19"
                                    }
                                ]
                            },
                            {
                                category: "docs-drift"
                            }
                        ]
                    }
                })],
            schedule: "weekly",
            publishing: "draft"
        })

    // The plugin object a page gets, with the MC part faked: `maintenance` is
    // what it publishes, each call is recorded and answered with `refusal`, and
    // each thread opened is recorded.
    QtObject {
        id: plugin

        property var environments: ["local"]
        property var watchers: ({})
        property var calls: []
        property string refusal: ""
        property var opened: []

        function watch(topic, callback, environment) {
            watchers[environment + "/" + topic] = callback;
            return environment + "/" + topic;
        }

        function unwatch(handle) {
        }

        function call(method, input, callback, environment) {
            calls = calls.concat([
                {
                    method: method,
                    input: input
                }
            ]);
            callback(null, refusal || null);
        }

        function openThread(threadId, environment) {
            opened = opened.concat([environment + "/" + threadId]);
        }

        function publish(value) {
            watchers["local/maintenance"](value);
        }
    }

    Loader {
        id: loader

        width: test.width
        height: test.height
    }

    TestCase {
        name: "MaintenancePage"
        when: windowShown

        function find(name) {
            return findChild(loader.item, name);
        }

        function init() {
            plugin.watchers = {};
            plugin.calls = [];
            plugin.opened = [];
            plugin.refusal = "";
            loader.source = "";
            loader.setSource(Qt.resolvedUrl("../ui/MaintenancePage.qml"), {
                plugin: plugin
            });
            tryVerify(() => loader.status === Loader.Ready && plugin.watchers["local/maintenance"] !== undefined);
            plugin.publish(test.maintenance);
            // The rows are laid out before anything is clicked.
            waitForRendering(loader.item);
        }

        function test_runs_are_listed_newest_first() {
            compare(loader.item.runs.map(each => each.id), ["new", "old"]);
        }

        function test_a_repository_without_a_project_says_so() {
            verify(find("maintenanceNext:acme/web").text.indexOf("no project has it as its remote") >= 0);
            verify(find("maintenanceNext:acme/api").text.indexOf("next run") >= 0);
        }

        function test_a_waiting_run_holds_its_repository() {
            verify(!find("maintenanceRunNow:acme/api").enabled);
            verify(find("maintenanceRunNow:acme/web").enabled);
            mouseClick(find("maintenanceRunNow:acme/web"));
            compare(plugin.calls, [
                {
                    method: "run",
                    input: {
                        repository: "acme/web"
                    }
                }
            ]);
        }

        function test_a_waiting_run_shows_its_report_and_opens_its_pull_request() {
            compare(find("maintenanceSummary:new").text, "Bumped lodash; react 19 needs a human.");
            compare(find("maintenanceCategories:new").text, "Dependencies: 1 applied, 1 deferred\nDocs drift: nothing to do");
            mouseClick(find("maintenancePublish:new"));
            compare(plugin.calls, [
                {
                    method: "publish",
                    input: {
                        runId: "new"
                    }
                }
            ]);
        }

        function test_a_run_opens_its_thread() {
            mouseClick(find("maintenanceThread:new"));
            compare(plugin.opened, ["local/t-new"]);
        }

        function test_a_running_run_can_be_cancelled_but_not_dismissed() {
            plugin.publish(Object.assign({}, test.maintenance, {
                runs: [test.run("going", "running")]
            }));
            verify(find("maintenanceCancel:going").visible);
            verify(!find("maintenanceDismiss:going").visible);
            verify(!find("maintenanceRerun:going").visible);
            mouseClick(find("maintenanceCancel:going"));
            compare(plugin.calls, [
                {
                    method: "cancel",
                    input: {
                        runId: "going"
                    }
                }
            ]);
        }

        function test_an_ended_run_is_dismissed_or_run_again() {
            plugin.publish(Object.assign({}, test.maintenance, {
                runs: [test.run("old", "done")]
            }));
            mouseClick(find("maintenanceRerun:old"));
            mouseClick(find("maintenanceDismiss:old"));
            compare(plugin.calls, [
                {
                    method: "run",
                    input: {
                        repository: "acme/api"
                    }
                },
                {
                    method: "dismiss",
                    input: {
                        runId: "old"
                    }
                }
            ]);
        }

        function test_a_skipped_run_names_the_open_pull_request() {
            plugin.publish(Object.assign({}, test.maintenance, {
                runs: [test.run("skip", "skipped", {
                        prUrl: "https://github.com/acme/api/pull/12",
                        error: "https://github.com/acme/api/pull/12 (maintenance/2026-10-26) is still open. Merge or close it first."
                    })]
            }));
            verify(find("maintenanceOpenPullRequest:skip").visible);
            verify(!find("maintenanceThread:skip").visible);
            verify(find("maintenanceRunProblem:skip").text.indexOf("is still open") >= 0);
        }

        function test_a_refusal_shows() {
            plugin.refusal = "acme/web has a maintenance run going already.";
            mouseClick(find("maintenanceRunNow:acme/web"));
            compare(find("maintenanceProblem").text, plugin.refusal);
        }
    }
}
