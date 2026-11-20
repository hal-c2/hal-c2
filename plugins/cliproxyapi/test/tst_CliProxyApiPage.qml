// Run from a hal-c2 checkout:
//   ljos test --import apps/desktop-qt/tests/imports --import apps/desktop-qt/qml \
//     plugins/cliproxyapi/test/tst_CliProxyApiPage.qml
// and with Qt 6, with QT_QPA_PLATFORM=offscreen:
//   "$(qmake6 -query QT_INSTALL_BINS)/qmltestrunner" -import apps/desktop-qt/tests/imports -import apps/desktop-qt/qml \
//     -input plugins/cliproxyapi/test/tst_CliProxyApiPage.qml
import QtQuick
import QtTest

// A TestCase is never visible, so what it clicks lives beside it.
Item {
    id: test

    width: 900
    height: 900

    function status(extra) {
        return Object.assign({
            mode: "managed",
            state: "running",
            message: "",
            pid: 4242,
            restarts: 0,
            output: [],
            version: "8.0.79",
            latest: null,
            binary: "/usr/bin/cli-proxy-api",
            source: "path",
            address: "http://127.0.0.1:8317",
            error: null,
            instances: [
                {
                    name: "claude",
                    instanceId: "plugin_cliproxyapi_claude",
                    label: "Claude via CLIProxyAPI",
                    state: "added"
                },
                {
                    name: "codex",
                    instanceId: "plugin_cliproxyapi_codex",
                    label: "Codex via CLIProxyAPI",
                    state: "dismissed"
                }
            ]
        }, extra ?? {});
    }

    readonly property var view: ({
            status: test.status(),
            accounts: [
                {
                    id: "claude-user@example.com.json",
                    name: "claude-user@example.com.json",
                    provider: "claude",
                    email: "user@example.com",
                    status: "active",
                    message: "",
                    disabled: false,
                    unavailable: false
                }
            ],
            signIn: null,
            usage: [
                {
                    day: "2026-11-19",
                    account: "user@example.com",
                    model: "claude-opus-5-5",
                    requests: 3,
                    failed: 1,
                    inputTokens: 1000,
                    outputTokens: 500,
                    cachedTokens: 0,
                    reasoningTokens: 0,
                    totalTokens: 1500
                }
            ],
            logs: ["POST /v1/messages 200"],
            keys: [
                {
                    provider: "claude",
                    id: "k1",
                    name: "",
                    baseUrl: "",
                    keys: ["sk-a…mnop"]
                }
            ]
        })

    // The plugin object a page gets, with the MC part faked: `status` answers
    // `view`, every other call `answer`, each call is recorded, `refusal` refuses it.
    QtObject {
        id: plugin

        property var environments: ["local"]
        property var watchers: ({})
        property var calls: []
        property string refusal: ""
        property var answer: null
        // Set, a call other than `status` waits here for the test to answer it.
        property bool hold: false
        property var held: null

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
            if (hold && method !== "status")
                held = callback;
            else if (refusal)
                callback(null, refusal);
            else
                callback(method === "status" ? test.view : answer, null);
        }

        function publish(topic, value) {
            watchers["local/" + topic](value);
        }
    }

    Loader {
        id: loader

        width: test.width
        height: test.height
    }

    TestCase {
        name: "CliProxyApiPage"
        when: windowShown

        function find(name) {
            return findChild(loader.item, name);
        }

        function asked() {
            return plugin.calls.filter(each => each.method !== "status");
        }

        function init() {
            plugin.watchers = {};
            plugin.calls = [];
            plugin.refusal = "";
            plugin.answer = null;
            plugin.hold = false;
            plugin.held = null;
            plugin.environments = ["local"];
            loader.source = "";
            loader.setSource(Qt.resolvedUrl("../ui/CliProxyApiPage.qml"), {
                plugin: plugin
            });
            tryVerify(() => loader.status === Loader.Ready && plugin.watchers["local/logs"] !== undefined);
            waitForRendering(loader.item);
        }

        function test_the_page_shows_what_status_answers() {
            compare(find("cliproxyapiState").text, "Running CLIProxyAPI 8.0.79 at http://127.0.0.1:8317");
            verify(find("cliproxyapiAccount:claude-user@example.com.json") !== null);
            verify(find("cliproxyapiUsage:user@example.com").text.indexOf("claude-opus-5-5") >= 0);
            verify(find("cliproxyapiUsage:user@example.com").text.indexOf("1 failed") >= 0);
            verify(find("cliproxyapiKey:claude:0") !== null);
            compare(find("cliproxyapiLog").text, "POST /v1/messages 200");
            verify(!find("cliproxyapiRetry").visible);
        }

        function test_topics_replace_what_the_page_shows() {
            plugin.publish("logs", {
                lines: ["GET /v1/models 200", "POST /v1/messages 429"]
            });
            plugin.publish("accounts", {
                accounts: [],
                signIn: null
            });
            compare(find("cliproxyapiLog").text, "GET /v1/models 200\nPOST /v1/messages 429");
            // A Repeater deletes a row it dropped later.
            tryVerify(() => find("cliproxyapiAccount:claude-user@example.com.json") === null);
        }

        function test_a_proxy_without_usage_says_why() {
            verify(!find("cliproxyapiUsageNote").visible);
            plugin.publish("usage", {
                rows: [],
                days: 7,
                note: "usage statistics are disabled"
            });
            compare(find("cliproxyapiUsageNote").text, "The proxy gives no usage: usage statistics are disabled");
            verify(find("cliproxyapiUsageNote").visible);
            verify(!find("cliproxyapiNoUsage").visible);
            plugin.publish("usage", {
                rows: [],
                days: 7,
                note: null
            });
            verify(!find("cliproxyapiUsageNote").visible);
            verify(find("cliproxyapiNoUsage").visible);
        }

        function test_a_deleted_instance_is_added_back() {
            verify(!find("cliproxyapiAddBack:claude").visible);
            verify(find("cliproxyapiAddBack:codex").visible);
            mouseClick(find("cliproxyapiAddBack:codex"));
            compare(asked(), [
                {
                    method: "addInstance",
                    input: {
                        name: "codex"
                    }
                }
            ]);
        }

        function test_an_instance_the_host_refused_says_why_and_offers_nothing() {
            const reason = "plugin_cliproxyapi_codex is a provider instance of the user's: a plugin reaches only the ones it added.";
            plugin.publish("status", test.status({
                instances: [
                    {
                        name: "codex",
                        instanceId: "plugin_cliproxyapi_codex",
                        label: "Codex via CLIProxyAPI",
                        state: "taken",
                        message: reason
                    }
                ]
            }));
            tryVerify(() => find("cliproxyapiInstanceText:codex") !== null);
            compare(find("cliproxyapiInstanceText:codex").text, "Codex via CLIProxyAPI · not added: " + reason);
            verify(!find("cliproxyapiAddBack:codex").visible);
        }

        function test_signing_in_shows_the_address_and_takes_the_one_pasted_back() {
            mouseClick(find("cliproxyapiSignIn:claude"));
            plugin.publish("accounts", {
                accounts: test.view.accounts,
                signIn: {
                    provider: "claude",
                    state: "st-1",
                    url: "https://claude.ai/oauth/authorize?state=st-1",
                    status: "wait",
                    error: null
                }
            });
            compare(find("cliproxyapiSignInUrl").text, "https://claude.ai/oauth/authorize?state=st-1");
            verify(find("cliproxyapiSignInHelp").text.indexOf("paste it below") >= 0);
            verify(!find("cliproxyapiSignIn:codex").enabled);
            find("cliproxyapiSignInAddress").text = "http://localhost:54545/callback?code=abc&state=st-1";
            mouseClick(find("cliproxyapiFinishSignIn"));
            compare(asked(), [
                {
                    method: "signIn",
                    input: {
                        provider: "claude"
                    }
                },
                {
                    method: "finishSignIn",
                    input: {
                        address: "http://localhost:54545/callback?code=abc&state=st-1"
                    }
                }
            ]);
            compare(find("cliproxyapiSignInAddress").text, "");
        }

        function test_a_failed_sign_in_says_why_and_is_dismissed() {
            plugin.publish("accounts", {
                accounts: [],
                signIn: {
                    provider: "codex",
                    state: "st-2",
                    url: "",
                    status: "error",
                    error: "state mismatch"
                }
            });
            compare(find("cliproxyapiSignInError").text, "The sign-in failed: state mismatch");
            compare(find("cliproxyapiCancelSignIn").text, "Dismiss");
            mouseClick(find("cliproxyapiCancelSignIn"));
            compare(asked(), [
                {
                    method: "cancelSignIn",
                    input: {}
                }
            ]);
        }

        function test_an_account_is_switched_off_and_removed() {
            mouseClick(find("cliproxyapiToggle:claude-user@example.com.json"));
            mouseClick(find("cliproxyapiRemove:claude-user@example.com.json"));
            compare(asked(), [
                {
                    method: "toggleAccount",
                    input: {
                        name: "claude-user@example.com.json",
                        disabled: true
                    }
                },
                {
                    method: "removeAccount",
                    input: {
                        name: "claude-user@example.com.json"
                    }
                }
            ]);
        }

        function test_a_key_is_added_and_removed() {
            verify(!find("cliproxyapiAddKey").enabled);
            find("cliproxyapiKeyValue").text = "sk-ant-new";
            mouseClick(find("cliproxyapiAddKey"));
            mouseClick(find("cliproxyapiRemoveKey:claude:k1"));
            compare(asked(), [
                {
                    method: "addKey",
                    input: {
                        provider: "claude",
                        apiKey: "sk-ant-new",
                        baseUrl: ""
                    }
                },
                {
                    method: "removeKey",
                    input: {
                        provider: "claude",
                        id: "k1"
                    }
                }
            ]);
            compare(find("cliproxyapiKeyValue").text, "");
        }

        function test_a_refused_key_is_retried() {
            plugin.publish("status", test.status({
                state: "blocked",
                message: "invalid management key"
            }));
            compare(find("cliproxyapiState").text, "CLIProxyAPI refused the management key");
            compare(find("cliproxyapiMessage").text, "invalid management key");
            verify(find("cliproxyapiRetry").visible);
            verify(!find("cliproxyapiSignIn:claude").enabled);
            plugin.answer = test.view;
            mouseClick(find("cliproxyapiRetry"));
            compare(asked(), [
                {
                    method: "retry",
                    input: {}
                }
            ]);
            compare(find("cliproxyapiState").text, "Running CLIProxyAPI 8.0.79 at http://127.0.0.1:8317");
        }

        function test_an_update_is_noted_not_installed() {
            plugin.publish("status", test.status({
                latest: "8.1.0"
            }));
            verify(find("cliproxyapiUpdate").text.indexOf("CLIProxyAPI 8.1.0 is out") >= 0);
        }

        function test_a_reply_from_an_environment_the_page_left_is_dropped() {
            plugin.hold = true;
            mouseClick(find("cliproxyapiRemove:claude-user@example.com.json"));
            plugin.environments = ["local", "work"];
            loader.item.environment = "work";
            plugin.held(null, "the proxy said: auth file not found");
            compare(find("cliproxyapiProblem").text, "");
        }

        function test_a_refusal_shows() {
            plugin.refusal = "the proxy said: auth file not found";
            mouseClick(find("cliproxyapiRemove:claude-user@example.com.json"));
            compare(find("cliproxyapiProblem").text, plugin.refusal);
        }
    }
}
