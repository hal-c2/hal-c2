import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// Settings → Keybindings as the user sees it (navigation/keybinding-settings.feature):
// what the page shows and how its fields take keys, over the Keybindings test
// double. What the rows hold and what saving does run in tst_Features.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: component
        KeybindingsSettings {
            width: 800
            height: 650
        }
    }

    function binding(command, key, when) {
        return {
            id: command + "\n" + key,
            command: command,
            label: command,
            key: key,
            keyLabel: key,
            when: when,
            source: "Default",
            defaultKey: key,
            defaultWhen: when,
            canReset: false,
            canRemove: false,
            search: [command, key, when, "default"].join("\n"),
            conflicts: []
        };
    }

    TestCase {
        name: "KeybindingsSettings"
        when: windowShown

        function init() {
            Keybindings.bindings = [binding("diff.toggle", "mod+d", "!terminalFocus"), binding("sidebar.toggle", "mod+b", "")];
            Keybindings.saved = [];
        }

        function page() {
            const created = createTemporaryObject(component, root);
            verify(created);
            waitForRendering(created);
            return created;
        }

        function row(settings, index) {
            const list = findChild(settings, "keybindingRows");
            list.forceLayout();
            return list.itemAtIndex(index);
        }

        // Scenario: The panel shows how many bindings there are
        function test_countIsShown() {
            const settings = page();
            compare(findChild(settings, "keybindingCount").text, "2 bindings");
            Keybindings.bindings = [binding("diff.toggle", "mod+d", "")];
            compare(findChild(settings, "keybindingCount").text, "1 binding");
        }

        // Scenario: Searching starts from its shortcut
        function test_findFocusesSearch() {
            const settings = page();
            const search = findChild(settings, "keybindingSearch");
            verify(!search.activeFocus);
            keySequence(StandardKey.Find);
            tryVerify(() => search.activeFocus);
        }

        // Scenario: Nothing matches the search
        function test_nothingMatches() {
            const settings = page();
            const search = findChild(settings, "keybindingSearch");
            const empty = findChild(settings, "keybindingEmpty");
            verify(!empty.visible);
            search.forceActiveFocus();
            keyClick(Qt.Key_Q);
            keyClick(Qt.Key_Q);
            keyClick(Qt.Key_Q);
            keyClick(Qt.Key_Q);
            tryVerify(() => empty.visible);
            compare(empty.text, "No keybindings match your search.");
            keyClick(Qt.Key_Escape);
            tryVerify(() => !empty.visible);
        }

        // Scenario: The recorder waits for a shortcut
        function test_recorderPrompts() {
            const settings = page();
            const recorder = findChild(row(settings, 0), "keyField");
            compare(recorder.children[0].text, "mod+d");
            mouseClick(recorder);
            verify(recorder.recording);
            compare(recorder.children[0].text, "Press shortcut");
        }

        // Scenario: Escape cancels recording
        function test_escapeCancelsRecording() {
            const settings = page();
            const first = row(settings, 0);
            const recorder = findChild(first, "keyField");
            mouseClick(recorder);
            verify(recorder.recording);
            keyClick(Qt.Key_Escape);
            verify(!recorder.recording);
            compare(first.keyDraft, "mod+d");
            verify(!first.dirty);
            compare(recorder.children[0].text, "mod+d");
            compare(Keybindings.saved.length, 0);
        }

        // Scenario: A binding with no condition applies always
        function test_noConditionReadsAlways() {
            const settings = page();
            const when = findChild(row(settings, 0), "whenField");
            compare(when.text, "!terminalFocus");
            when.text = "";
            compare(when.placeholderText, "Always");
            compare(findChild(row(settings, 1), "whenField").placeholderText, "Always");
        }

        // Scenario: Adding a binding can be cancelled
        function test_addCancelled() {
            const settings = page();
            const draft = findChild(settings, "keybindingDraft");
            verify(!draft.visible);
            mouseClick(findChild(settings, "keybindingAdd"));
            tryVerify(() => draft.visible);
            mouseClick(findChild(draft, "cancel"));
            tryVerify(() => !draft.visible);
            compare(Keybindings.saved.length, 0);
            compare(findChild(settings, "keybindingCount").text, "2 bindings");
        }
    }
}
