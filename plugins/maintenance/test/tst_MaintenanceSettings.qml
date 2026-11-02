// Run from a hal-c2 checkout, with QT_QPA_PLATFORM=offscreen:
//   qmltestrunner -import apps/desktop-qt/tests/imports -import apps/desktop-qt/qml \
//     -input <this plugin>/test/tst_MaintenanceSettings.qml
import QtQuick
import QtTest

// A TestCase is never visible, so what it clicks lives beside it.
Item {
    id: test

    width: 700
    height: 3000

    readonly property var saved: ({
            repositories: ["acme/api", "acme/gone"],
            schedule: "weekly",
            weekday: "monday",
            time: "06:00",
            mode: "fix",
            categories: ["deps", "security-alerts", "docs-drift", "coverage-gaps"],
            securityOnly: false,
            concurrency: 1,
            provider: "claudeAgent",
            model: "claude-sonnet-5-5",
            modelOptions: {},
            runtimeMode: "auto-accept-edits",
            prompt: "Maintain {{repository}}.",
            instructions: {
                "acme/api": "Run make check."
            },
            publishing: "draft"
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
        name: "MaintenanceSettings"
        when: windowShown

        function find(name) {
            return findChild(loader.item, name);
        }

        function init() {
            plugin.saves = [];
            loader.source = "";
            loader.setSource(Qt.resolvedUrl("../ui/MaintenanceSettings.qml"), {
                plugin: plugin
            });
            tryVerify(() => loader.status === Loader.Ready && loader.item.loaded);
            tryVerify(() => find("maintenanceSetting:repository:acme/api").mapToItem(null, 0, 0).x < find("maintenanceSetting:repository:acme/web").mapToItem(null, 0, 0).x);
        }

        function test_the_projects_repositories_are_offered_with_the_picked_ones() {
            verify(find("maintenanceSetting:repository:acme/api").chosen);
            verify(!find("maintenanceSetting:repository:acme/web").chosen);
            // Picked but no longer a project here: still listed, to untick.
            verify(find("maintenanceSetting:repository:acme/gone").chosen);
        }

        function test_picking_a_repository_adds_it_and_saves() {
            mouseClick(find("maintenanceSetting:repository:acme/web"));
            mouseClick(find("maintenanceSave"));
            compare(plugin.saves.length, 1);
            compare(plugin.saves[0].repositories, ["acme/api", "acme/gone", "acme/web"]);
        }

        function test_unticking_a_repository_that_is_no_project_drops_it() {
            mouseClick(find("maintenanceSetting:repository:acme/gone"));
            mouseClick(find("maintenanceSave"));
            compare(plugin.saves[0].repositories, ["acme/api"]);
        }

        function test_the_agent_shows_its_pick_and_another_agent_resets_the_model() {
            compare(find("maintenanceSetting:model").displayText, "Sonnet 5.5");
            find("maintenanceSetting:provider").activated(1);
            compare(find("maintenanceSetting:model").displayText, "Its default model");
            mouseClick(find("maintenanceSave"));
            compare(plugin.saves[0].provider, "codex");
            compare(plugin.saves[0].model, "");
            compare(plugin.saves[0].modelOptions, {});
        }

        function test_the_default_model_offers_its_options() {
            verify(find("maintenanceSetting:modelOption:effort") === null || !find("maintenanceSetting:modelOption:effort").visible);
            find("maintenanceSetting:model").activated(0);
            tryVerify(() => find("maintenanceSetting:modelOption:effort") !== null && find("maintenanceSetting:modelOption:effort").visible);
        }

        function test_categories_mode_schedule_and_publishing_are_picked() {
            mouseClick(find("maintenanceSetting:category:coverage-gaps"));
            mouseClick(findChild(find("maintenanceSetting:mode"), "choice:report"));
            mouseClick(findChild(find("maintenanceSetting:schedule"), "choice:daily"));
            mouseClick(findChild(find("maintenanceSetting:publishing"), "choice:automatic"));
            mouseClick(find("maintenanceSave"));
            compare(plugin.saves[0].categories, ["deps", "security-alerts", "docs-drift"]);
            compare(plugin.saves[0].mode, "report");
            compare(plugin.saves[0].schedule, "daily");
            compare(plugin.saves[0].publishing, "automatic");
        }

        function test_a_weekday_is_offered_only_for_a_weekly_schedule() {
            verify(find("maintenanceSetting:weekday").visible);
            mouseClick(findChild(find("maintenanceSetting:schedule"), "choice:manual"));
            verify(!find("maintenanceSetting:weekday").visible);
            verify(!find("maintenanceSetting:time").visible);
        }

        function test_each_picked_repository_takes_its_own_instructions() {
            const api = find("maintenanceSetting:instructions:acme/api");
            compare(api.text, "Run make check.");
            verify(find("maintenanceSetting:instructions:acme/gone") !== null);
            verify(find("maintenanceSetting:instructions:acme/web") === null);
            api.forceActiveFocus();
            api.selectAll();
            api.remove(0, api.length);
            mouseClick(find("maintenanceSave"));
            compare(plugin.saves[0].instructions, {});
        }
    }
}
