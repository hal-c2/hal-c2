import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/settings/providers-panel.feature and providers/provider-setup.feature:
// the Providers section draws what ProviderSettingsController publishes.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: settingsComponent
        ProvidersSettings {
            width: 880
            height: 680
        }
    }

    function provider(overrides) {
        return Object.assign({
            instanceId: "claudeAgent_work", driver: "claudeAgent", name: "Claude Work", version: "v2.1.0",
            enabled: true, installed: true, status: "ready", headline: "Authenticated", detail: "",
            email: "ada@example.com", models: [{ slug: "claude-opus", name: "Claude Opus" }],
            advisory: null, canUpdate: false, updating: false,
            account: { description: "Signed in.", canSignIn: true, signInLabel: "Change account", canCancel: false,
                       canSignOut: true, url: "", userCode: "", error: "" },
            editable: true, custom: true, resettable: false, pending: false, label: "Claude Work", placeholder: "Claude",
            accentColor: "", fields: [], secrets: [],
            variables: [{ name: "API_TOKEN", value: "", sensitive: true, redacted: true, invalid: false,
                          placeholder: "Stored secret, enter a new value to replace" }]
        }, overrides);
    }

    function settings(overrides) {
        return Object.assign({
            open: true, environmentId: "env-a",
            environments: [{ id: "env-a", label: "This machine", local: true, online: true }],
            status: "ready", title: "", description: "", refreshing: false, wizard: null,
            providers: [root.provider({})]
        }, overrides);
    }

    TestCase {
        name: "ProvidersSettingsTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        // The signed-in account email stays hidden until asked; the signed-in
        // email is hidden until the user reveals it.
        function test_the_account_email_is_scrambled_until_revealed() {
            Shell.state = { providerSettings: root.settings({}) };
            const page = createTemporaryObject(settingsComponent, root);
            const email = findChild(findChild(page, "provider_claudeAgent_work"), "email");
            verify(email.text !== "ada@example.com");
            compare(email.text.length, "ada@example.com".length);
            compare(email.text.indexOf("@"), 3);
            compare(email.text, page.redacted("ada@example.com"), "the same account scrambles the same way");
            mouseClick(email);
            compare(email.text, "ada@example.com");
            mouseClick(email);
            verify(email.text !== "ada@example.com");
        }

        function test_turning_a_provider_off_asks_the_shell() {
            Shell.state = { providerSettings: root.settings({}) };
            const page = createTemporaryObject(settingsComponent, root);
            mouseClick(findChild(findChild(page, "provider_claudeAgent_work"), "enabled"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.enable");
            compare(Shell.dispatchedActions[0].payload.instanceId, "claudeAgent_work");
            compare(Shell.dispatchedActions[0].payload.enabled, false);
        }

        function test_without_providers_the_section_says_why() {
            Shell.state = { providerSettings: root.settings({ status: "offline", providers: [], title: "Could not connect to this device",
                                                              description: "Reconnect this device to set up its provider, or select another device." }) };
            const page = createTemporaryObject(settingsComponent, root);
            verify(findChild(page, "placeholder").visible);
            verify(!findChild(page, "refresh").enabled, "an offline environment cannot be refreshed");
        }

        // One environment needs no choice; several do.
        function test_the_environment_choice_shows_with_several_environments() {
            Shell.state = { providerSettings: root.settings({}) };
            const page = createTemporaryObject(settingsComponent, root);
            verify(!findChild(page, "environments").visible);
            Shell.state = { providerSettings: root.settings({ environments: [
                { id: "env-a", label: "This machine", local: true, online: true },
                { id: "build", label: "Build box", local: false, online: false }] }) };
            verify(findChild(page, "environments").visible);
        }

        function test_an_update_running_cannot_be_started_again() {
            const advisory = { title: "Update available", detail: "Update available: install v0.51.0.", updateCommand: "npm i -g codex",
                               targetVersion: null, strong: false };
            Shell.state = { providerSettings: root.settings({ providers: [root.provider({ advisory: advisory, updating: true })] }) };
            const page = createTemporaryObject(settingsComponent, root);
            const update = findChild(findChild(page, "provider_claudeAgent_work"), "update");
            verify(update.visible);
            verify(!update.enabled);
        }
    
        function wizard(overrides) {
            return Object.assign({
                step: 1, steps: ["Provider", "Identity", "Config"],
                drivers: [{ id: "codex", label: "Codex", badge: "" }, { id: "claudeAgent", label: "Claude", badge: "" }],
                driver: "claudeAgent", driverLabel: "Claude", label: "Claude", accentColor: "", instanceId: "claudeAgent_2",
                instanceIdError: "", fields: [], saving: false
            }, overrides);
        }

        // Adding an instance: the wizard's own actions, and a taken id said.
        function test_the_wizard_adds_an_instance_and_says_why_an_id_is_refused() {
            Shell.state = { providerSettings: root.settings({}) };
            const page = createTemporaryObject(settingsComponent, root);
            mouseClick(findChild(page, "addInstance"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.wizardOpen");
            Shell.state = { providerSettings: root.settings({ wizard: wizard({ instanceIdError: "An instance with this id already exists." }) }) };
            const card = findChild(page, "wizard");
            tryVerify(() => !!card && card.visible);
            verify(findChild(card, "instanceIdError").visible);
            verify(!findChild(page, "addInstance").enabled, "one wizard at a time");
            mouseClick(findChild(card, "submit"));
            compare(Shell.dispatchedActions[1].action, "providerSettings.wizardSubmit");
        }

        // A stored secret is never shown; its row offers a replacement.
        function test_a_stored_secret_row_offers_a_replacement() {
            Shell.state = { providerSettings: root.settings({}) };
            const page = createTemporaryObject(settingsComponent, root);
            const card = findChild(page, "provider_claudeAgent_work");
            mouseClick(findChild(card, "configure"));
            verify(findChild(card, "editor").visible);
            const value = findChild(findChild(card, "variable_0"), "variableValue");
            compare(value.text, "");
            compare(value.placeholderText, "Stored secret, enter a new value to replace");
            compare(value.echoMode, TextInput.Password);
            mouseClick(findChild(card, "addVariable"));
            compare(Shell.dispatchedActions[0].action, "providerSettings.addVariable");
            compare(Shell.dispatchedActions[0].payload.instanceId, "claudeAgent_work");
            mouseClick(findChild(card, "delete"));
            compare(Shell.dispatchedActions[1].action, "providerSettings.delete");
        }
    }
}
