import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// The desktop's model-and-mode scenarios (features/composer/model-and-mode.feature)
// for the native picker, one test per scenario by name. The catalogue goes
// in as Shell.state.modelPicker; what the user chose comes out as the action
// the picker dispatches, which the shell turns into the next turn's model.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: composerComponent
        Composer {
            width: 800
            height: 650
        }
    }

    // The shell's side of the model picker keybinding: the window shortcut
    // asks the native picker to toggle.
    Shortcut {
        sequence: "Ctrl+Shift+M"
        context: Qt.WindowShortcut
        onActivated: Shell.actionRequested("composer.modelPicker.toggle", {})
    }

    TestCase {
        name: "ModelPicker"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function cleanup() {
            Shell.reset();
        }

        function model(slug, name, overrides) {
            return Object.assign({
                slug: slug,
                name: name,
                shortName: null,
                subProvider: null,
                isFavorite: false,
                isCustom: false,
                isNew: false,
                isLegacy: false,
                isUnavailable: false,
                disabledReason: null
            }, overrides ?? {});
        }

        function instance(instanceId, driverKind, displayName, models, overrides) {
            return Object.assign({
                instanceId: instanceId,
                driverKind: driverKind,
                displayName: displayName,
                accentColor: null,
                iconUrl: null,
                initials: displayName.slice(0, 2).toUpperCase(),
                showBadge: false,
                status: "ready",
                isAvailable: true,
                unavailableReason: null,
                models: models
            }, overrides ?? {});
        }

        // The Control key, which Qt calls Meta on macOS.
        readonly property int ctrl: Qt.platform.os === "osx" ? Qt.MetaModifier : Qt.ControlModifier

        function chord(key, shift) {
            return {
                key: key,
                ctrlKey: true,
                metaKey: false,
                shiftKey: shift,
                altKey: false,
                label: (shift ? "Ctrl+Shift+" : "Ctrl+") + key
            };
        }

        function codex(models) {
            return instance("codex", "codex", "Codex", models ?? [model("gpt-5-codex", "gpt-5-codex"), model("gpt-5.5", "GPT-5.5")]);
        }

        function claude() {
            return instance("claudeAgent", "claudeAgent", "Claude", [model("opus", "Claude Opus"), model("sonnet", "Claude Sonnet"), model("haiku", "Claude Haiku")]);
        }

        // Background: a project with an open thread on Codex.
        function createPicker(instances) {
            Shell.state = {
                composer: Object.assign(Shell.defaultComposer(), {
                    selectedInstanceId: "codex",
                    selectedModel: "gpt-5-codex"
                }),
                modelPicker: {
                    instances: instances,
                    locked: false,
                    shortcut: "Ctrl+Shift+M",
                    previousProvider: chord("arrowup", true),
                    nextProvider: chord("arrowdown", true),
                    jump: [1, 2, 3, 4, 5, 6, 7, 8, 9].map(index => chord(String(index), false))
                },
                workspace: null
            };
            const composer = createTemporaryObject(composerComponent, root);
            verify(!!composer, "Component exists");
            const picker = findChild(composer, "modelPicker");
            verify(!!picker, "Object exists");
            tryCompare(picker, "enabled", true);
            return picker;
        }

        function openPicker(picker) {
            Shell.actionRequested("composer.modelPicker.toggle", {});
            tryCompare(picker.popup, "opened", true);
            tryCompare(inPicker(picker, "modelPickerSearch"), "activeFocus", true);
        }

        function inPicker(picker, name) {
            tryVerify(() => findChild(picker.popup.contentItem, name) !== null, 2000, name);
            return findChild(picker.popup.contentItem, name);
        }

        function listed(picker) {
            return picker.rows.filter(row => row.kind === "model").map(row => row.model.slug);
        }

        function selections() {
            return Shell.dispatchedActions.filter(entry => entry.action === "composer.model.select").map(entry => entry.payload.instanceId + ":" + entry.payload.model);
        }

        function search(picker, query) {
            for (const key of query) {
                keyClick(key);
            }
            tryCompare(picker, "query", query);
        }

        // "a provider that is turned off in settings is not listed" is the
        // shell's filter, before the catalogue reaches the picker.
        function test_models_are_grouped_by_provider() {
            const work = instance("codexWork", "codex", "Codex Work", [model("gpt-5.5", "GPT-5.5")], {
                showBadge: true
            });
            const picker = createPicker([codex(), work, claude()]);
            openPicker(picker);
            const expected = {
                codex: ["gpt-5-codex", "gpt-5.5"],
                codexWork: ["gpt-5.5"],
                claudeAgent: ["opus", "sonnet", "haiku"]
            };
            for (const instanceId of Object.keys(expected)) {
                mouseClick(inPicker(picker, "modelPickerProvider:" + instanceId));
                tryCompare(picker, "view", instanceId);
                compare(picker.rows.every(row => row.instance.instanceId === instanceId), true, instanceId);
                compare(listed(picker), expected[instanceId], instanceId);
            }
        }

        function test_the_chosen_model_is_shown_with_its_provider() {
            const picker = createPicker([codex(), claude()]);
            compare(picker.triggerTitle, "gpt-5-codex");
            const icon = findChild(picker, "modelPickerIcon");
            verify(!!icon, "Object exists");
            verify(icon.visible);
            compare(icon.driverKind, "codex");
            compare(picker.activeInstance.displayName, "Codex");
        }

        function test_searching_the_models_matches_provider_and_model_names_data() {
            return [
                {
                    tag: "opus",
                    query: "opus",
                    found: "opus",
                    missing: "gpt-5-codex"
                },
                {
                    tag: "claude",
                    query: "claude",
                    found: "sonnet",
                    missing: "gpt-5-codex"
                },
                {
                    tag: "codex",
                    query: "codex",
                    found: "gpt-5-codex",
                    missing: "opus"
                }
            ];
        }

        function test_searching_the_models_matches_provider_and_model_names(data) {
            const picker = createPicker([codex(), claude()]);
            openPicker(picker);
            search(picker, data.query);
            verify(listed(picker).includes(data.found), data.found + " is listed");
            verify(!listed(picker).includes(data.missing), data.missing + " is not listed");
        }

        function test_a_model_that_cannot_be_used_says_why_and_cannot_be_chosen() {
            const reason = "Start a new thread to use this model.";
            const picker = createPicker([codex([model("gpt-5-codex", "gpt-5-codex"), model("gpt-5.5", "GPT-5.5", {
                        disabledReason: reason
                    })]), claude()]);
            openPicker(picker);
            const row = inPicker(picker, "modelPickerRow:codex:gpt-5.5");
            compare(row.disabledReason, reason);
            mouseClick(row);
            // The keyboard skips it too: Down from the chosen model wraps
            // nowhere past it, and its star cannot be pressed.
            keyClick(Qt.Key_Down);
            keyClick(Qt.Key_Return);
            compare(inPicker(picker, "modelPickerFavorite:codex:gpt-5.5").enabled, false);
            compare(selections().includes("codex:gpt-5.5"), false);
        }

        function test_unavailable_providers_stay_listed_with_the_reason() {
            const reason = "Cursor — Unavailable. Not installed.";
            const cursor = instance("cursor", "cursor", "Cursor", [], {
                status: "error",
                isAvailable: false,
                unavailableReason: reason
            });
            const picker = createPicker([codex(), claude(), cursor]);
            openPicker(picker);
            const button = inPicker(picker, "modelPickerProvider:cursor");
            verify(button.visible);
            compare(button.tooltip, reason);
            mouseClick(button);
            compare(picker.view, "codex");
            // The provider shortcuts skip it as well.
            keyClick(Qt.Key_Down, ctrl | Qt.ShiftModifier);
            tryCompare(picker, "view", "claudeAgent");
            keyClick(Qt.Key_Down, ctrl | Qt.ShiftModifier);
            tryCompare(picker, "view", "favorites");
            compare(selections().filter(entry => entry.startsWith("cursor:")).length, 0);
        }

        function test_the_user_chooses_a_model_with_the_keyboard() {
            const picker = createPicker([codex(), claude()]);
            openPicker(picker);
            keyClick(Qt.Key_Down);
            keyClick(Qt.Key_Return);
            tryCompare(picker.popup, "visible", false);
            compare(selections(), ["codex:gpt-5.5"]);
        }

        function test_the_user_moves_between_providers_with_the_keyboard() {
            const picker = createPicker([codex(), claude()]);
            openPicker(picker);
            keyClick(Qt.Key_Down, ctrl | Qt.ShiftModifier);
            tryCompare(picker, "view", "claudeAgent");
            compare(listed(picker), ["opus", "sonnet", "haiku"]);
            keyClick(Qt.Key_Up, ctrl | Qt.ShiftModifier);
            tryCompare(picker, "view", "codex");
            // Shift+Tab reaches the rail, and the arrows move along it.
            keyClick(Qt.Key_Backtab, Qt.ShiftModifier);
            tryCompare(inPicker(picker, "modelPickerProvider:codex"), "activeFocus", true);
            keyClick(Qt.Key_Down);
            tryCompare(inPicker(picker, "modelPickerProvider:claudeAgent"), "activeFocus", true);
            keyClick(Qt.Key_Return);
            tryCompare(picker, "view", "claudeAgent");
        }

        function test_the_user_jumps_to_a_model_by_its_number() {
            const picker = createPicker([codex(), claude()]);
            openPicker(picker);
            compare(picker.rows[1].jumpIndex, 1);
            keyClick(Qt.Key_2, ctrl);
            tryCompare(picker.popup, "visible", false);
            compare(selections(), ["codex:gpt-5.5"]);
        }

        function test_the_model_picker_shortcut_opens_and_closes_the_model_picker() {
            const picker = createPicker([codex(), claude()]);
            picker.forceActiveFocus();
            keyClick(Qt.Key_M, Qt.ControlModifier | Qt.ShiftModifier);
            tryCompare(picker.popup, "opened", true);
            tryCompare(inPicker(picker, "modelPickerSearch"), "activeFocus", true);
            keyClick(Qt.Key_M, Qt.ControlModifier | Qt.ShiftModifier);
            tryCompare(picker.popup, "visible", false);
        }

        function test_the_trigger_and_escape_close_the_picker() {
            const picker = createPicker([codex(), claude()]);
            mouseClick(picker);
            tryCompare(picker.popup, "opened", true);
            mouseClick(picker);
            tryCompare(picker.popup, "visible", false);
            openPicker(picker);
            keyClick(Qt.Key_Escape);
            tryCompare(picker.popup, "visible", false);
            compare(selections(), []);
        }

        // The web row's parts: the short name, the provider line with its
        // sub-provider, the legacy fold and the empty search.
        function test_rows_follow_the_web_list() {
            const opencode = instance("opencode", "opencode", "OpenCode", [model("anthropic/claude-sonnet-4", "Anthropic: Claude Sonnet 4", {
                    shortName: "Claude Sonnet 4",
                    subProvider: "Anthropic"
                }), model("old", "Old model", {
                    isLegacy: true
                })]);
            const picker = createPicker([codex(), opencode]);
            openPicker(picker);
            mouseClick(inPicker(picker, "modelPickerProvider:opencode"));
            tryCompare(picker, "view", "opencode");
            compare(listed(picker), ["anthropic/claude-sonnet-4"]);
            const legacy = inPicker(picker, "modelPickerLegacy:opencode");
            mouseClick(legacy);
            tryVerify(() => listed(picker).includes("old"));
            search(picker, "zzzz");
            compare(picker.rows.length, 0);
        }
    }
}
