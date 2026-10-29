// Run from a hal-c2 checkout, with QT_QPA_PLATFORM=offscreen:
//   qmltestrunner -import apps/desktop-qt/tests/imports -import apps/desktop-qt/qml \
//     -input <this plugin>/test/tst_IssuesPage.qml
import QtQuick
import QtTest

// A TestCase is never visible, so what it clicks lives beside it.
Item {
    id: test

    width: 900
    height: 600

    function issue(number, title) {
        return {
            key: "acme/api#" + number,
            repository: "acme/api",
            number: number,
            title: title,
            state: "open",
            url: "https://github.com/acme/api/issues/" + number,
            author: "dana",
            assignees: [],
            labels: ["backend"],
            milestone: null,
            createdAt: "2026-10-01T00:00:00Z",
            updatedAt: "2026-10-20T00:00:00Z",
            blockedBy: [],
            pullRequests: [],
            subIssues: {
                total: 0,
                completed: 0
            }
        };
    }

    readonly property var tracker: ({
            repositories: [
                {
                    repository: "acme/api",
                    project: "api",
                    truncated: false
                }
            ],
            issues: [issue(7, "Add limits"), issue(9, "Flaky test")],
            runs: [
                {
                    id: "run-1",
                    action: "followUp",
                    repository: "acme/api",
                    number: 7,
                    threadId: "t-follow",
                    status: "proposed",
                    createdAt: 2,
                    title: "Follow up on acme/api#7",
                    summary: "The body never says which limits.",
                    error: null,
                    report: {
                        summary: "The body never says which limits.",
                        items: [
                            {
                                repository: "acme/api",
                                number: 7,
                                comment: "Which limits, and per what?"
                            }
                        ]
                    }
                }
            ],
            threads: {
                "implement:acme/api#7": {
                    threadId: "t-impl",
                    startedAt: 1,
                    status: "running"
                }
            },
            checkedAt: 3,
            looking: false,
            problem: null
        })

    // The plugin object a page gets, with the MC part faked: `tracker` is what
    // it publishes, `issue` answers the picked issue with its body, each other
    // call is recorded and answered with `refusal`, and each thread opened is
    // recorded.
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
            if (method === "issue")
                callback(Object.assign({}, test.issue(input.number, "Add limits"), {
                    body: "We need limits."
                }), null);
            else
                callback(null, refusal || null);
        }

        function openThread(threadId, environment) {
            opened = opened.concat([environment + "/" + threadId]);
        }

        function publish(value) {
            watchers["local/tracker"](value);
        }
    }

    Loader {
        id: loader

        width: test.width
        height: test.height
    }

    TestCase {
        name: "IssuesPage"
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
            loader.setSource(Qt.resolvedUrl("../ui/IssuesPage.qml"), {
                plugin: plugin
            });
            tryVerify(() => loader.status === Loader.Ready && plugin.watchers["local/tracker"] !== undefined);
            plugin.publish(test.tracker);
            // The first issue opens: its body is read.
            plugin.calls = [];
        }

        function test_the_queue_lists_and_opens_the_first_issue() {
            compare(loader.item.issues.map(each => each.key), ["acme/api#7", "acme/api#9"]);
            compare(loader.item.selected, "acme/api#7");
            tryVerify(() => find("issueTrackerBody").text === "We need limits.");
        }

        function test_each_action_starts_from_the_issue() {
            mouseClick(find("issueTrackerFollowUp"));
            mouseClick(find("issueTrackerSummarise"));
            mouseClick(find("issueTrackerImplement"));
            compare(plugin.calls, [
                {
                    method: "followUp",
                    input: {
                        repository: "acme/api",
                        number: 7
                    }
                },
                {
                    method: "summarise",
                    input: {
                        repository: "acme/api",
                        number: 7
                    }
                },
                {
                    method: "implement",
                    input: {
                        repository: "acme/api",
                        number: 7
                    }
                }
            ]);
        }

        function test_the_implementing_thread_shows_how_it_goes_and_opens() {
            const button = find("issueTrackerImplementThread");
            compare(button.text, "Last implement: running");
            mouseClick(button);
            compare(plugin.opened, ["local/t-impl"]);
        }

        function test_a_proposal_waits_to_be_applied() {
            mouseClick(find("issueTrackerProposals"));
            tryVerify(() => find("issueTrackerRuns").height > 0);
            const run = find("issueTrackerRun:run-1");
            verify(run !== null);
            mouseClick(find("issueTrackerApply:run-1"));
            compare(plugin.calls, [
                {
                    method: "apply",
                    input: {
                        runId: "run-1"
                    }
                }
            ]);
        }

        function test_a_proposal_can_be_dismissed_instead() {
            mouseClick(find("issueTrackerProposals"));
            tryVerify(() => find("issueTrackerRuns").height > 0);
            mouseClick(find("issueTrackerDiscard:run-1"));
            compare(plugin.calls, [
                {
                    method: "discard",
                    input: {
                        runId: "run-1"
                    }
                }
            ]);
        }

        function test_prioritising_needs_a_repository_picked() {
            verify(!find("issueTrackerPrioritise").enabled);
            loader.item.repository = "acme/api";
            verify(find("issueTrackerPrioritise").enabled);
            mouseClick(find("issueTrackerPrioritise"));
            compare(plugin.calls, [
                {
                    method: "prioritise",
                    input: {
                        repository: "acme/api"
                    }
                }
            ]);
        }

        function test_a_problem_and_a_refusal_show() {
            plugin.publish(Object.assign({}, test.tracker, {
                problem: "acme/api could not be read: gh is not signed in."
            }));
            compare(find("issueTrackerProblem").text, "acme/api could not be read: gh is not signed in.");
            plugin.refusal = "There is no agent cursor on this MC; pick one in the settings.";
            mouseClick(find("issueTrackerRefresh"));
            compare(find("issueTrackerProblem").text, plugin.refusal);
        }
    }
}
