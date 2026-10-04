import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/navigation/welcome-wizard.feature: the wizard draws what
// OnboardingController publishes and sends the user's choices back.
Item {
    id: root
    width: 900
    height: 800

    Component {
        id: wizardComponent
        WelcomeWizard {
            anchors.fill: parent
        }
    }

    function onboarding(overrides) {
        return Object.assign({ gate: "wizard", recovery: null, step: "connection", stage: 0, importing: false,
                               computers: [{ environmentId: "env-a", label: "studio", connected: true, selected: true }],
                               canContinue: true, pairing: false, pairingError: "", pairingDetail: "",
                               agents: [], terminal: null, import: {} }, overrides);
    }

    function candidate(key, checked) {
        return { key: key, path: "/home/ada/" + key, checked: checked, threadCount: 2, age: "1d", claude: 1, codex: 1 };
    }

    TestCase {
        name: "WelcomeWizardTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_nothing_is_drawn_once_the_app_opens() {
            const wizard = createTemporaryObject(wizardComponent, root);
            verify(!wizard.visible);
            Shell.state = { onboarding: root.onboarding({ gate: "app" }) };
            verify(!wizard.visible);
            Shell.state = { onboarding: root.onboarding({ gate: "pending" }) };
            verify(wizard.visible);
            verify(!findChild(wizard, "onboardingWizard").visible);
            verify(!findChild(wizard, "onboardingRecovery").visible);
        }

        function test_recovery_offers_reload_or_retry() {
            Shell.state = { onboarding: root.onboarding({ gate: "pending", recovery: "connection" }) };
            const wizard = createTemporaryObject(wizardComponent, root);
            compare(findChild(wizard, "onboardingRecoveryTitle").text, "Still connecting");
            mouseClick(findChild(wizard, "onboardingRecoveryAction"));
            compare(Shell.dispatchedActions[0].action, "onboarding.reload");

            Shell.state = { onboarding: root.onboarding({ gate: "pending", recovery: "settings" }) };
            compare(findChild(wizard, "onboardingRecoveryTitle").text, "Could not read settings");
            mouseClick(findChild(wizard, "onboardingRecoveryAction"));
            compare(Shell.dispatchedActions[1].action, "onboarding.retry");
        }

        function test_connect_selects_pairs_and_continues() {
            Shell.state = { onboarding: root.onboarding({}) };
            const wizard = createTemporaryObject(wizardComponent, root);
            const computer = findChild(wizard, "onboardingComputer_studio");
            const check = findChild(computer, "onboardingComputerCheck");
            verify(check.checked);
            mouseClick(check);
            compare(Shell.dispatchedActions[0].action, "onboarding.select");
            compare(Shell.dispatchedActions[0].payload.environmentId, "env-a");
            compare(Shell.dispatchedActions[0].payload.selected, false);

            mouseClick(findChild(wizard, "onboardingAddComputer"));
            const field = findChild(wizard, "onboardingPairingUrl");
            field.text = " http://desk:3773/pair#token=abc ";
            mouseClick(findChild(wizard, "onboardingPair"));
            compare(Shell.dispatchedActions[1].action, "onboarding.pair");
            compare(Shell.dispatchedActions[1].payload.pairingUrl, "http://desk:3773/pair#token=abc");

            Shell.state = { onboarding: root.onboarding({ pairingError: "Pairing failed.", pairingDetail: "the link expired" }) };
            compare(findChild(wizard, "onboardingPairingError").text, "the link expired");

            mouseClick(findChild(wizard, "onboardingContinue"));
            compare(Shell.dispatchedActions[2].action, "onboarding.continue");
            Shell.state = { onboarding: root.onboarding({ canContinue: false }) };
            verify(!findChild(wizard, "onboardingContinue").enabled);
        }

        function test_an_agent_offers_install_or_sign_in() {
            const cards = [{ driver: "codex", name: "Codex", state: "install", headline: "Not found", detail: "",
                             terminalOpen: false, terminalAvailable: true },
                           { driver: "claudeAgent", name: "Claude Code", state: "ready", headline: "Authenticated", detail: "",
                             terminalOpen: false, terminalAvailable: true }];
            Shell.state = { onboarding: root.onboarding({ step: "agents", stage: 1,
                                                          agents: [{ environmentId: "env-a", label: "studio", cards: cards }] }) };
            const wizard = createTemporaryObject(wizardComponent, root);
            const codex = findChild(wizard, "onboardingAgent_studio_Codex");
            const install = findChild(codex, "onboardingAgentAction");
            verify(install.visible);
            compare(install.text, "Install");
            mouseClick(install);
            compare(Shell.dispatchedActions[0].action, "onboarding.agent");
            compare(Shell.dispatchedActions[0].payload.environmentId, "env-a");
            compare(Shell.dispatchedActions[0].payload.driver, "codex");

            const claude = findChild(wizard, "onboardingAgent_studio_Claude Code");
            verify(!findChild(claude, "onboardingAgentAction").visible);
            compare(findChild(claude, "onboardingAgentStatus").text, "Ready");
        }

        function test_import_selects_all_or_none_and_imports() {
            const scan = { environmentId: "env-a", label: "studio", pending: false, error: "", truncated: false, empty: false,
                           repositories: [{ key: "acme/api", label: "acme/api", secondary: "", single: true, checked: true,
                                            partial: false, threadCount: 2, age: "1d", claude: 1, codex: 1,
                                            candidates: [root.candidate("api", true)] }],
                           other: { count: 1, checked: false, partial: false, candidates: [root.candidate("notes", false)] } };
            Shell.state = { onboarding: root.onboarding({ step: "import", stage: 2,
                                                          import: { loading: false, multiple: false, total: 2, selectedCount: 1,
                                                                    error: "", scans: [scan] } }) };
            const wizard = createTemporaryObject(wizardComponent, root);
            compare(findChild(wizard, "onboardingSelectedCount").text, "1 of 2 selected");
            compare(findChild(wizard, "onboardingImport").text, "Import 1 project");
            mouseClick(findChild(wizard, "onboardingSelectAll"));
            compare(Shell.dispatchedActions[0].action, "onboarding.selectAll");
            mouseClick(findChild(wizard, "onboardingSelectNone"));
            compare(Shell.dispatchedActions[1].action, "onboarding.selectNone");
            mouseClick(findChild(wizard, "onboardingImport"));
            compare(Shell.dispatchedActions[2].action, "onboarding.import");
            mouseClick(findChild(wizard, "onboardingSkip"));
            compare(Shell.dispatchedActions[3].action, "onboarding.skip");

            Shell.state = { onboarding: root.onboarding({ step: "import", stage: 2, importing: true,
                                                          import: { total: 2, selectedCount: 2, error: "", scans: [scan] } }) };
            compare(findChild(wizard, "onboardingImport").text, "Importing…");
            verify(!findChild(wizard, "onboardingImport").enabled);
            verify(!findChild(wizard, "onboardingSkip").enabled);

            Shell.state = { onboarding: root.onboarding({ step: "import", stage: 2,
                                                          import: { total: 2, selectedCount: 2, error: "Could not import thread history.",
                                                                    scans: [scan] } }) };
            compare(findChild(wizard, "onboardingImportError").text, "Could not import thread history.");
            compare(findChild(wizard, "onboardingSkip").text, "Continue without the rest");
        }
    }
}
