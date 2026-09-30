import QtQuick
import QtQuick.Layouts
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/settings/source-control.feature and source-control-writing.feature:
// the Source Control section draws what SourceControlSettingsController
// publishes and sends its choices back.
Item {
    id: root
    width: 900
    height: 900

    Component {
        id: pageComponent
        SourceControlSettings {
            width: 880
            height: 880
        }
    }

    // The page as the shell hosts it (SettingsHost in the window's layout):
    // loaded first, given its width after.
    Component {
        id: hostedComponent
        RowLayout {
            property alias page: loader.item

            anchors.fill: parent

            Loader {
                id: loader

                Layout.fillWidth: true
                Layout.fillHeight: true
                source: "../qml/HalC2/Bricks/SourceControlSettings.qml"
            }
        }
    }

    function github(overrides) {
        return Object.assign({ kind: "github", label: "GitHub", version: "2.45.0", comingSoon: false, available: true, enabled: true,
                               authLabel: "Authenticated", authWarning: false, summary: "Authenticated", hasAccount: true,
                               revealed: false, account: "", git: false }, overrides);
    }

    function state(overrides) {
        return Object.assign({ open: true, projectScope: false,
                               discovery: { status: "ready", scanning: false, title: "", detail: "", suffix: "", versionControl: [],
                                            providers: [root.github({})] },
                               fetchInterval: { seconds: 30, preset: 30, custom: false, mixed: false, environmentWide: false },
                               autoPull: { value: false, mixed: false, overridden: false },
                               mergeMethod: { value: "last", mixed: false, overridden: false },
                               writingStyle: { mode: "repo_conventions", mixed: false, description: "", instructions: "",
                                               instructionsMixed: false, dirty: false, overridden: false },
                               templates: { value: true, mixed: false, overridden: false },
                               writerModel: { available: true, on: false, mixed: false, key: "", canEnable: true, overridden: false, models: [] } },
                             overrides);
    }

    TestCase {
        name: "SourceControlSettingsTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_a_hidden_account_is_revealed_on_request() {
            Shell.state = { settingsScope: { editable: true }, sourceControlSettings: root.state({}) };
            const page = createTemporaryObject(pageComponent, root);
            const tool = findChild(page, "sourceControlTool:github");
            const account = findChild(tool, "account");
            verify(account.visible);
            verify(account.text !== "octocat", "the account stays hidden");
            mouseClick(account);
            compare(Shell.dispatchedActions[0].action, "sourceControlSettings.reveal");
            compare(Shell.dispatchedActions[0].payload.kind, "github");
            compare(Shell.dispatchedActions[0].payload.revealed, true);
        }

        // A tool that is missing says how to get it, at any length.
        function test_a_long_summary_wraps_inside_the_page() {
            const hint = "Not available on this server: Install the GitLab command-line tool (`glab`) from "
                       + "https://gitlab.com/gitlab-org/cli or your package manager (for example `brew install glab`), "
                       + "then sign in with `glab auth login` for each GitLab host this environment should reach.";
            const gitlab = root.github({ kind: "gitlab", label: "GitLab", version: "", available: false, enabled: false,
                                         authLabel: "", summary: hint, hasAccount: false });
            Shell.state = { settingsScope: { editable: true }, sourceControlSettings: root.state({
                discovery: { status: "ready", scanning: false, title: "", detail: "", suffix: "", versionControl: [],
                             providers: [root.github({}), gitlab] } }) };
            const page = createTemporaryObject(hostedComponent, root).page;
            waitForRendering(page);
            const summary = findChild(findChild(page, "sourceControlTool:gitlab"), "summary");
            verify(summary.lineCount > 1);
            verify(summary.mapToItem(page, summary.width, 0).x <= page.width, "the summary stays on the page");
            const control = findChild(findChild(page, "autoPull"), "control");
            verify(control.mapToItem(page, control.width, 0).x <= page.width, "the page's controls stay on it");
        }

        function test_what_shows_instead_of_the_tools() {
            Shell.state = { settingsScope: { editable: true }, sourceControlSettings: root.state({
                discovery: { status: "error", scanning: false, title: "Could not scan the server environment", detail: "No gh",
                             suffix: "", versionControl: [], providers: [] } }) };
            const page = createTemporaryObject(pageComponent, root);
            compare(findChild(page, "noticeTitle").text, "Could not scan the server environment");
            verify(!findChild(page, "sourceControlTool:github"));
            mouseClick(findChild(page, "scan"));
            compare(Shell.dispatchedActions[0].action, "sourceControlSettings.scan");
        }

        function test_mixed_styles_take_one_set_of_instructions_for_all() {
            Shell.state = { settingsScope: { editable: true }, sourceControlSettings: root.state({
                writingStyle: { mode: "", mixed: true, description: "", instructions: "", instructionsMixed: true, dirty: true, overridden: false } }) };
            const page = createTemporaryObject(pageComponent, root);
            compare(findChild(findChild(page, "writingStyle"), "control").displayText, "Mixed");
            const instructions = findChild(page, "instructions");
            verify(!instructions.visible);
            mouseClick(findChild(page, "writeForAll"));
            verify(instructions.visible);
            instructions.text = "Keep titles short.";
            mouseClick(findChild(page, "applyForAll"));
            const sent = Shell.dispatchedActions.find(entry => entry.action === "sourceControlSettings.instructions");
            compare(sent.payload.text, "Keep titles short.");
        }
    }
}
