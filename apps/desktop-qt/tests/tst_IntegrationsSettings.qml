import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/settings/integrations.feature: the Integrations section draws what
// DeviceSettingsController publishes and sends its choices back.
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
    }
}
