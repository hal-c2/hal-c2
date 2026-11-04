import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

TestCase {
    id: testCase
    name: "ShellTextFieldTests"
    width: 300
    height: 100
    when: windowShown

    Component {
        id: fieldComponent
        ShellTextField {
            width: 200
        }
    }

    function init() {
        Theme.colors = {
            inputSurface: "#ffffff",
            input: "#d4d4d8",
            focus: "#ff8800"
        };
    }

    function cleanup() {
        Theme.colors = {};
    }

    // The field fills with the input surface and borders with `input`, in
    // either appearance.
    function test_fieldIsTheInputSurfaceBorderedByInput() {
        const field = createTemporaryObject(fieldComponent, testCase);
        compare(field.background.color, Qt.color("#ffffff"));
        compare(field.background.border.color, Qt.color("#d4d4d8"));
    }

    // A field rings whenever it holds the caret, a click included: it shows
    // where typing goes.
    function test_fieldRingsWhenItTakesTheCaret() {
        const field = createTemporaryObject(fieldComponent, testCase);
        field.forceActiveFocus(Qt.MouseFocusReason);
        compare(field.background.border.color, Qt.color("#ff8800"));
    }

    function test_disabledFieldIsDimmed() {
        const field = createTemporaryObject(fieldComponent, testCase);
        compare(field.opacity, 1);
        field.enabled = false;
        compare(field.opacity, 0.64);
    }
}
