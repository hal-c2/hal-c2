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
            canvas: "#ffffff",
            input: "#d4d4d8"
        };
    }

    function cleanup() {
        Theme.colors = {};
        Theme.appearance = "dark";
    }

    function test_lightFieldIsCanvasNotTheInputColour() {
        Theme.appearance = "light";
        const field = createTemporaryObject(fieldComponent, testCase);
        compare(field.background.color, Qt.color("#ffffff"));
        compare(field.background.border.color, Qt.color("#d4d4d8"));
    }

    function test_darkFieldIsAFaintInputTint() {
        Theme.appearance = "dark";
        const field = createTemporaryObject(fieldComponent, testCase);
        const fill = field.background.color;
        compare(fill.a.toFixed(2), "0.32");
        compare(Qt.rgba(fill.r, fill.g, fill.b, 1), Qt.color("#d4d4d8"));
    }

    function test_disabledFieldIsDimmed() {
        const field = createTemporaryObject(fieldComponent, testCase);
        compare(field.opacity, 1);
        field.enabled = false;
        compare(field.opacity, 0.64);
    }
}
