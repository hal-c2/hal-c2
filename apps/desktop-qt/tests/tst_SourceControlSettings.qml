import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
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

        // The summary is the second line of the name's column, so the switch's height spans it.
        function test_the_summary_sits_beside_the_switch_not_under_it() {
            Shell.state = { settingsScope: { editable: true }, sourceControlSettings: root.state({}) };
            const page = createTemporaryObject(pageComponent, root);
            const tool = findChild(page, "sourceControlTool:github");
            const summary = findChild(tool, "summary");
            const availability = findChild(tool, "availability");
            const top = summary.mapToItem(tool, 0, 0).y;
            const switchTop = availability.mapToItem(tool, 0, 0).y;
            verify(top < switchTop + availability.height && top + summary.height > switchTop,
                   "the summary overlaps the switch vertically, not below it");
        }

        // Rescan is a named icon, not a bare word that reads as a column label.
        function test_rescan_is_an_icon_button() {
            Shell.state = { settingsScope: { editable: true }, sourceControlSettings: root.state({
                discovery: { status: "ready", scanning: false, title: "", detail: "", suffix: "", versionControl: [root.github({})],
                             providers: [] } }) };
            const page = createTemporaryObject(hostedComponent, root).page;
            const scan = findChild(page, "scan");
            verify(scan.iconOnly, "Rescan has no text beside its icon");
            compare(scan.iconName, "refresh-cw");
        }

        // The tool an install hint names is set in the monospace face, its backticks gone.
        function test_an_install_hint_formats_the_command_it_names() {
            const hint = "GitHub is not authenticated on this server. Sign in using the `gh` tool on the server host.";
            Shell.state = { settingsScope: { editable: true }, sourceControlSettings: root.state({
                discovery: { status: "ready", scanning: false, title: "", detail: "", suffix: "", versionControl: [],
                             providers: [root.github({ summary: hint, hasAccount: false })] } }) };
            const page = createTemporaryObject(pageComponent, root);
            const summary = findChild(findChild(page, "sourceControlTool:github"), "summary");
            compare(summary.textFormat, Text.RichText);
            verify(summary.text.includes("font-family:"), summary.text);
            verify(!summary.text.includes("`"), summary.text);
            verify(summary.text.includes(">gh</span>"), summary.text);
            compare(summary.Accessible.name, hint.replace(/`/g, ""));
        }

        // A stray backtick in a hint pairs only within its line: it cannot mono-format the prose after it.
        function test_a_stray_backtick_does_not_span_lines() {
            const hint = "Sign in with `gh.\nThen run `gh auth login` on the server host.";
            Shell.state = { settingsScope: { editable: true }, sourceControlSettings: root.state({
                discovery: { status: "ready", scanning: false, title: "", detail: "", suffix: "", versionControl: [],
                             providers: [root.github({ summary: hint, hasAccount: false })] } }) };
            const page = createTemporaryObject(pageComponent, root);
            const summary = findChild(findChild(page, "sourceControlTool:github"), "summary");
            compare((summary.text.match(/<span /g) ?? []).length, 1);
            verify(summary.text.includes(">gh auth login</span>"), summary.text);
            verify(summary.text.includes("`gh."), "the unpaired backtick stays as it was written");
        }

        // A summary the server leaves out renders empty, as the plain label it replaced did.
        function test_a_tool_without_a_summary_renders_empty() {
            const tool = root.github({ hasAccount: false });
            delete tool.summary;
            Shell.state = { settingsScope: { editable: true }, sourceControlSettings: root.state({
                discovery: { status: "ready", scanning: false, title: "", detail: "", suffix: "", versionControl: [],
                             providers: [tool] } }) };
            const page = createTemporaryObject(pageComponent, root);
            const summary = findChild(findChild(page, "sourceControlTool:github"), "summary");
            compare(summary.text, "");
            compare(summary.Accessible.name, "");
        }

        // The hints come from the server and name commands with placeholders, several
        // to a sentence: only the generated spans may be markup.
        function test_an_install_hint_escapes_everything_but_its_command_spans() {
            const hint = "Sign in with `fj --host <server-url> auth add-token` or `fj login` & retry <b>now</b>, 5 > 3.";
            Shell.state = { settingsScope: { editable: true }, sourceControlSettings: root.state({
                discovery: { status: "ready", scanning: false, title: "", detail: "", suffix: "", versionControl: [],
                             providers: [root.github({ summary: hint, hasAccount: false })] } }) };
            const page = createTemporaryObject(pageComponent, root);
            const summary = findChild(findChild(page, "sourceControlTool:github"), "summary");
            verify(summary.text.includes(">fj --host &lt;server-url&gt; auth add-token</span>"), summary.text);
            verify(summary.text.includes(">fj login</span>"), summary.text);
            verify(summary.text.includes("&amp; retry &lt;b&gt;now&lt;/b&gt;, 5 &gt; 3."), summary.text);
            // Without the two spans' own tags there is no markup left.
            compare(summary.text.replace(/<span style="[^"]*">/g, "").replace(/<\/span>/g, "").search(/[<>]/), -1);
            compare((summary.text.match(/<span /g) ?? []).length, 2);
        }

        // While it scans the button is disabled (dimmed, out of the tab order and
        // announced as such); the wrapper around it carries the hover tooltip.
        function test_rescan_while_scanning_shows_its_tooltip_and_ignores_clicks() {
            Shell.state = { settingsScope: { editable: true }, sourceControlSettings: root.state({
                discovery: { status: "ready", scanning: true, title: "", detail: "", suffix: "", versionControl: [root.github({})],
                             providers: [] } }) };
            const page = createTemporaryObject(hostedComponent, root).page;
            const scan = findChild(page, "scan");
            const area = findChild(page, "scanArea");
            verify(!scan.enabled, "disabled while it scans");
            compare(scan.Accessible.name, "Scanning server environment");
            verify(scan.opacity < 1, "dimmed while disabled");
            mouseMove(area, area.width / 2, area.height / 2);
            const hover = findChild(page, "scanHover");
            tryCompare(hover.ToolTip, "visible", true);
            compare(hover.ToolTip.text, "Scanning…");
            mouseClick(area);
            compare(Shell.dispatchedActions.length, 0);
        }

        // Git's fetch interval is behind a details toggle, collapsed until it is used.
        function test_the_git_fetch_interval_is_behind_a_details_toggle() {
            Shell.state = { settingsScope: { editable: true }, sourceControlSettings: root.state({
                discovery: { status: "ready", scanning: false, title: "", detail: "", suffix: "",
                             versionControl: [root.github({ kind: "git", label: "Git", git: true })], providers: [] } }) };
            const page = createTemporaryObject(pageComponent, root);
            const tool = findChild(page, "sourceControlTool:git");
            const fetchInterval = findChild(tool, "fetchInterval");
            verify(!fetchInterval.visible, "collapsed to start with");
            mouseClick(findChild(tool, "details"));
            verify(fetchInterval.visible, "opened by the toggle");
            mouseClick(findChild(tool, "details"));
            verify(!fetchInterval.visible, "closed again by the same toggle");
        }

        // A search result that targets the fetch interval opens it without a click.
        function test_a_search_for_the_fetch_interval_opens_the_details() {
            Shell.state = { settingsScope: { editable: true }, route: { target: "fetchInterval", targetSeq: 1 },
                            sourceControlSettings: root.state({
                discovery: { status: "ready", scanning: false, title: "", detail: "", suffix: "",
                             versionControl: [root.github({ kind: "git", label: "Git", git: true })], providers: [] } }) };
            const page = createTemporaryObject(pageComponent, root);
            verify(findChild(findChild(page, "sourceControlTool:git"), "fetchInterval").visible);
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
            // lineCount is not kept for rich text: the wrapped height says so.
            verify(summary.contentHeight > summary.font.pixelSize * 2, "the summary wraps: " + summary.contentHeight);
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
