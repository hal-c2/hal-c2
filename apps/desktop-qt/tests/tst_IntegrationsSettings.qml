import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/settings/integrations.feature: the Integrations section draws what
// DeviceSettingsController and SlackSettingsController publish and send the
// user's choices back.
Item {
    id: root
    width: 900
    height: 800

    Component {
        id: pageComponent
        IntegrationsSettings {
            width: 880
            height: 780
        }
    }

    function toggle(overrides) {
        return Object.assign({ on: false, mixed: false, enabled: true, status: "", update: "", version: "v1.4.0" }, overrides);
    }

    function state(overrides) {
        return Object.assign({ open: true, projectScope: false, loaded: true, pending: "", busy: false, statusNote: "",
                               hub: root.toggle({}), agent: root.toggle({ enabled: false }), canCheck: true,
                               updateError: null, platforms: [], hosts: [] }, overrides);
    }

    function slack(overrides) {
        return Object.assign({ open: true, loaded: true, editable: true, statusNote: "", state: "off", team: "", bot: "",
                               error: "", tokensSet: false, pending: "" }, overrides);
    }

    TestCase {
        name: "IntegrationsSettingsTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_the_hub_switch_sends_its_choice() {
            Shell.state = { settingsScope: { editable: true }, deviceSettings: root.state({}) };
            const page = createTemporaryObject(pageComponent, root);
            const hub = findChild(page, "hub");
            verify(!findChild(findChild(page, "agent"), "control").enabled, "agent access waits for a hub");
            mouseClick(findChild(hub, "control"));
            compare(Shell.dispatchedActions[0].action, "deviceSettings.hub");
            compare(Shell.dispatchedActions[0].payload.enabled, true);
        }

        function test_an_outdated_tool_offers_an_update_and_explains_a_failure() {
            Shell.state = { settingsScope: { editable: true }, deviceSettings: root.state({
                hub: root.toggle({ update: "Update to v1.4.0", version: "v1.3.0" }),
                updateError: { tool: "hub", message: "Update failed. Check this host's network connection and try again." } }) };
            const page = createTemporaryObject(pageComponent, root);
            const hub = findChild(page, "hub");
            verify(findChild(hub, "updateError").visible);
            verify(!findChild(findChild(page, "agent"), "updateError").visible);
            mouseClick(findChild(hub, "update"));
            compare(Shell.dispatchedActions[0].action, "deviceSettings.update");
            compare(Shell.dispatchedActions[0].payload.tool, "hub");
        }

        function test_simulator_support_names_the_environment_shown() {
            Shell.state = { settingsScope: { editable: true }, deviceSettings: root.state({
                hub: root.toggle({ on: true }),
                statusNote: "Status for Laptop. Select an environment to inspect its simulator support.",
                platforms: [{ platform: "iOS", ready: true, message: "Xcode and iOS Simulator are available." },
                            { platform: "Android", ready: false, message: "The Android SDK was not found." }] }) };
            const page = createTemporaryObject(pageComponent, root);
            verify(findChild(page, "platforms").visible);
            compare(findChild(findChild(page, "platform:iOS"), "message").text, "Ready");
            compare(findChild(findChild(page, "platform:Android"), "message").text, "The Android SDK was not found.");
            verify(findChild(page, "statusNote").visible);
        }

        function test_connecting_slack_sends_the_tokens_once_and_keeps_none() {
            Shell.state = { settingsScope: { editable: true }, deviceSettings: root.state({}), slackSettings: root.slack({}) };
            const page = createTemporaryObject(pageComponent, root);
            const connect = findChild(page, "slackConnect");
            const bot = findChild(page, "slackBotToken");
            const app = findChild(page, "slackAppToken");
            compare(bot.echoMode, TextInput.Password);
            compare(app.echoMode, TextInput.Password);
            bot.text = "xoxb-1";
            verify(!connect.enabled, "both tokens are needed");
            app.text = "xapp-1";
            verify(connect.enabled);
            mouseClick(connect);
            compare(Shell.dispatchedActions[0].action, "slackSettings.connect");
            compare(Shell.dispatchedActions[0].payload.botToken, "xoxb-1");
            compare(Shell.dispatchedActions[0].payload.appToken, "xapp-1");
            compare(bot.text, "");
            compare(app.text, "");
        }

        function test_a_connected_slack_names_its_workspace_and_can_be_disconnected() {
            Shell.state = { settingsScope: { editable: true }, deviceSettings: root.state({}),
                            slackSettings: root.slack({ state: "connected", team: "acme", bot: "HAL", tokensSet: true }) };
            const page = createTemporaryObject(pageComponent, root);
            compare(findChild(page, "slackStatus").text, "Connected to acme as HAL");
            verify(!findChild(page, "slackError").visible);
            mouseClick(findChild(page, "slackDisconnect"));
            compare(Shell.dispatchedActions[0].action, "slackSettings.disconnect");
            mouseClick(findChild(page, "slackCopyManifest"));
            compare(Shell.dispatchedActions[1].action, "slackSettings.copyManifest");
        }

        function test_slacks_refusal_is_shown() {
            Shell.state = { settingsScope: { editable: true }, deviceSettings: root.state({}),
                            slackSettings: root.slack({ state: "failed", error: "Slack refused the bot token: invalid_auth" }) };
            const page = createTemporaryObject(pageComponent, root);
            compare(findChild(page, "slackStatus").text, "Not connected");
            verify(findChild(page, "slackError").visible);
            compare(findChild(page, "slackError").text, "Slack refused the bot token: invalid_auth");
            verify(!findChild(page, "slackDisconnect").visible);
            verify(!findChild(page, "slackRetry").visible);
        }

        function test_a_slack_that_could_not_load_says_why_and_tries_again() {
            Shell.state = { settingsScope: { editable: true }, deviceSettings: root.state({}),
                            slackSettings: root.slack({ loaded: false, editable: false, failed: true, error: "MC unavailable: noconnection" }) };
            const page = createTemporaryObject(pageComponent, root);
            compare(findChild(page, "slackStatus").text, "Could not load Slack");
            compare(findChild(page, "slackError").text, "MC unavailable: noconnection");
            verify(!findChild(page, "slackConnect").enabled);
            mouseClick(findChild(page, "slackRetry"));
            compare(Shell.dispatchedActions[0].action, "slackSettings.retry");
        }
    }
}
