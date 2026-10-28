// Run from a hal-c2 checkout, with QT_QPA_PLATFORM=offscreen:
//   qmltestrunner -import apps/desktop-qt/tests/imports -import apps/desktop-qt/qml \
//     -input <this plugin>/test/tst_IssueTrackerSettings.qml
import QtQuick
import QtTest

// A TestCase is never visible, so what it clicks lives beside it.
Item {
    id: test

    width: 700
    height: 2400

    function agent(model, runtimeMode) {
        return {
            provider: "claudeAgent",
            model: model,
            modelOptions: {},
            runtimeMode: runtimeMode
        };
    }

    readonly property var saved: ({
            repositories: ["acme/api"],
            issueLabel: "",
            pollMinutes: 10,
            prioritising: agent("claude-sonnet-5-5", "approval-required"),
            prioritisePrompt: "Rank {{repository}}.",
            followingUp: agent("", "approval-required"),
            followUpPrompt: "Ask about #{{number}}.",
            summarising: agent("", "approval-required"),
            summarisePrompt: "Summarise #{{number}}.",
            implementing: agent("claude-opus-5-5", "auto-accept-edits"),
            implementPrompt: "Implement #{{number}}."
        })

    readonly property var providers: [
        {
            instanceId: "claudeAgent",
            name: "Claude",
            models: [
                {
                    slug: "claude-opus-5-5",
                    name: "Opus 5.5",
                    isDefault: true,
                    options: [
                        {
                            id: "effort",
                            label: "Effort",
                            type: "select",
                            options: [
                                {
                                    id: "medium"
                                },
                                {
                                    id: "high"
                                }
                            ]
                        }
                    ]
                },
                {
                    slug: "claude-sonnet-5-5",
                    name: "Sonnet 5.5",
                    isDefault: false,
                    options: []
                }
            ]
        },
        {
            instanceId: "codex",
            name: "Codex",
            models: [
                {
                    slug: "gpt-6",
                    name: "GPT-6",
                    isDefault: true,
                    options: []
                }
            ]
        }
    ]

    // The plugin object a settings page gets, with the MC part faked:
    // `settings` answers what is saved, and each save is recorded.
    QtObject {
        id: plugin

        property var environments: ["local"]
        property var saves: []

        function call(method, input, callback, environment) {
            callback({
                settings: test.saved,
                providers: test.providers,
                repositories: ["acme/api", "acme/web"]
            }, null);
        }

        function saveSettings(values, callback, environment) {
            saves = saves.concat([values]);
            callback({}, null);
        }
    }

    Loader {
        id: loader

        width: test.width
    }

    TestCase {
        name: "IssueTrackerSettings"
        when: windowShown

        function find(name) {
            return findChild(loader.item, name);
        }

        function init() {
            plugin.saves = [];
            loader.source = "";
            loader.setSource(Qt.resolvedUrl("../ui/IssueTrackerSettings.qml"), {
                plugin: plugin
            });
            tryVerify(() => loader.status === Loader.Ready && loader.item.loaded);
        }

        function test_each_agent_shows_its_own_pick() {
            compare(find("issueTrackerSetting:prioritising:model").displayText, "Sonnet 5.5");
            compare(find("issueTrackerSetting:followingUp:model").displayText, "Its default model");
            compare(find("issueTrackerSetting:implementing:model").displayText, "Opus 5.5");
            compare(find("issueTrackerSetting:implementing:modelOption:effort").visible, true);
        }

        function test_picking_a_repository_adds_it_and_saves() {
            tryVerify(() => find("issueTrackerSetting:repository:acme/api").mapToItem(null, 0, 0).x < find("issueTrackerSetting:repository:acme/web").mapToItem(null, 0, 0).x);
            mouseClick(find("issueTrackerSetting:repository:acme/web"));
            mouseClick(find("issueTrackerSave"));
            compare(plugin.saves.length, 1);
            compare(plugin.saves[0].repositories, ["acme/api", "acme/web"]);
        }

        function test_unpicking_every_repository_follows_them_all() {
            tryVerify(() => find("issueTrackerSetting:repository:acme/api").mapToItem(null, 0, 0).x < find("issueTrackerSetting:repository:acme/web").mapToItem(null, 0, 0).x);
            mouseClick(find("issueTrackerSetting:repository:acme/api"));
            mouseClick(find("issueTrackerSave"));
            compare(plugin.saves[0].repositories, []);
        }

        function test_another_agent_for_implementing_leaves_the_triage_agents_alone() {
            find("issueTrackerSetting:implementing:provider").activated(1);
            mouseClick(find("issueTrackerSave"));
            compare(plugin.saves.length, 1);
            compare(plugin.saves[0].implementing.provider, "codex");
            compare(plugin.saves[0].implementing.model, "");
            compare(plugin.saves[0].prioritising, test.saved.prioritising);
            compare(plugin.saves[0].followingUp, test.saved.followingUp);
        }
    }
}
