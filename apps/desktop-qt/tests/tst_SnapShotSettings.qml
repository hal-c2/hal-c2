import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/settings/snap-shot.feature: the SnapShots section draws what
// SnapShotController publishes and sends what the user does.
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: snapComponent
        SnapShotSettings {
            width: 880
            height: 680
        }
    }

    function toggle(overrides) {
        return Object.assign({ checked: false, enabled: true, status: "" }, overrides);
    }

    function snapShot(overrides) {
        return Object.assign({
            ready: true, available: true, mode: "portal", backend: "portal", desktop: "Hyprland", enabled: true, switchOn: true,
            status: "", description: "Capture a window with a shortcut and attach it to your draft.", setupLabel: "", rows: true,
            shortcut: { description: "Press this anywhere to capture.", keys: "Ctrl+Shift+2", label: "Ctrl+Shift+2", recording: false,
                        status: "", changed: false, canSave: false, registered: true, pending: false, permissions: false,
                        permissionsEnabled: false },
            accessibility: root.toggle({ enabled: false, status: "Not available on this desktop." }),
            flash: root.toggle({ checked: true, enabled: false }),
            animations: root.toggle({ checked: true, enabled: false }),
            sound: { value: "soft-pop", label: "Whoosh (Default)" },
            wizard: null
        }, overrides);
    }

    TestCase {
        name: "SnapShotSettingsTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function last() {
            return Shell.dispatchedActions[Shell.dispatchedActions.length - 1];
        }

        function test_turning_it_on_and_off_goes_to_the_controller() {
            Shell.state = { snapShot: root.snapShot({ enabled: false, switchOn: false, rows: false, setupLabel: "" }) };
            const page = createTemporaryObject(snapComponent, root);
            const control = findChild(findChild(page, "snapShot:enabled"), "control");
            verify(!control.checked);
            mouseClick(control);
            compare(last().action, "snapShot.enable");
            compare(last().payload.on, true);
        }

        function test_an_unavailable_desktop_says_why_and_locks_the_switch() {
            Shell.state = { snapShot: root.snapShot({ available: false, enabled: false, switchOn: false, rows: false,
                                                      status: "Snap Shot needs the desktop portal." }) };
            const page = createTemporaryObject(snapComponent, root);
            const row = findChild(page, "snapShot:enabled");
            compare(findChild(row, "status").text, "Snap Shot needs the desktop portal.");
            verify(!findChild(row, "control").enabled);
        }

        function test_the_walk_through_steps_and_closes() {
            Shell.state = { snapShot: root.snapShot({ wizard: { step: "access", title: "Set up Snap Shot", heading: "Allow capture",
                                                                body: "Your desktop asks each time.", details: "", attention: "",
                                                                closeLabel: "Finish later", continueLabel: "Continue", doneLabel: "Done",
                                                                doneEnabled: false, permissions: false, permissionsLabel: "" } }) };
            const page = createTemporaryObject(snapComponent, root);
            verify(findChild(page, "snapShotSetup").visible);
            compare(findChild(page, "heading").text, "Allow capture");
            verify(!findChild(page, "done").visible);
            mouseClick(findChild(page, "continue"));
            compare(last().action, "snapShot.setup.continue");
            mouseClick(findChild(page, "close"));
            compare(last().action, "snapShot.setup.close");
            compare(last().payload.completed, false);
        }

        function test_recording_sends_the_keys_and_escape() {
            Shell.state = { snapShot: root.snapShot({}) };
            const page = createTemporaryObject(snapComponent, root);
            const recorder = findChild(findChild(page, "snapShot:shortcut"), "recorder");
            compare(recorder.text, "Ctrl+Shift+2");
            mouseClick(recorder);
            compare(last().action, "snapShot.record.start");
            Shell.state = { snapShot: root.snapShot({ shortcut: Object.assign({}, Shell.state.snapShot.shortcut, { recording: true }) }) };
            verify(recorder.activeFocus);
            keyClick(Qt.Key_K, Qt.ControlModifier | Qt.AltModifier);
            const keys = Shell.dispatchedActions.filter(entry => entry.action === "snapShot.record.key");
            compare(keys[keys.length - 1].payload.key, Qt.Key_K);
            compare(keys[keys.length - 1].payload.modifiers & (Qt.ControlModifier | Qt.AltModifier), Qt.ControlModifier | Qt.AltModifier);
            keyPress(Qt.Key_Shift);
            const modifier = Shell.dispatchedActions.filter(entry => entry.action === "snapShot.record.modifier"
                                                                     && entry.payload.modifier === "shift");
            compare(modifier.length, 1);
            compare(modifier[0].payload.down, true);
            keyRelease(Qt.Key_Shift);
            keyClick(Qt.Key_Escape);
            compare(last().action, "snapShot.record.key");
            compare(last().payload.key, Qt.Key_Escape);
        }

        function test_a_changed_shortcut_saves_or_cancels() {
            Shell.state = { snapShot: root.snapShot({ shortcut: Object.assign({}, root.snapShot({}).shortcut,
                                                                              { keys: "Ctrl+Alt+K", changed: true, canSave: true }) }) };
            const page = createTemporaryObject(snapComponent, root);
            const row = findChild(page, "snapShot:shortcut");
            mouseClick(findChild(row, "save"));
            compare(last().action, "snapShot.shortcut.save");
            mouseClick(findChild(row, "discard"));
            compare(last().action, "snapShot.shortcut.discard");
        }

        function test_the_cues_follow_the_settings() {
            Shell.state = { snapShot: root.snapShot({}) };
            const page = createTemporaryObject(snapComponent, root);
            const sound = findChild(findChild(page, "snapShot:sound"), "control");
            compare(sound.currentIndex, 1);
            sound.activated(0);
            compare(last().action, "snapShot.sound");
            compare(last().payload.value, "off");
            mouseClick(findChild(findChild(page, "snapShot:sound"), "play"));
            compare(last().action, "snapShot.sound.play");
            compare(last().payload.sound, "soft-pop");
            const flash = findChild(findChild(page, "snapShot:flash"), "control");
            verify(flash.checked);
            verify(!flash.enabled, "the portal gives no flash");
            compare(findChild(findChild(page, "snapShot:accessibility"), "status").text, "Not available on this desktop.");
        }
    }
}
