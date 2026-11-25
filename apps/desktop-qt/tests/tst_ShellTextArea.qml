import QtQuick
import QtTest
import HalC2.Shell
import "../../../packages/qml/HalC2/Bricks"

TestCase {
    id: testCase
    name: "ShellTextAreaTests"
    width: 300
    height: 160
    when: windowShown

    Component {
        id: areaComponent
        ShellTextArea {
            width: 200
            height: 96
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

    // An area is drawn as a text field: the input surface bordered by `input`,
    // ringed while it holds the caret.
    function test_areaIsDrawnAsAField() {
        const area = createTemporaryObject(areaComponent, testCase);
        compare(area.background.color, Qt.color("#ffffff"));
        compare(area.background.border.color, Qt.color("#d4d4d8"));
        area.forceActiveFocus(Qt.MouseFocusReason);
        compare(area.background.border.color, Qt.color("#ff8800"));
    }

    function test_areaWraps() {
        const area = createTemporaryObject(areaComponent, testCase);
        compare(area.wrapMode, TextEdit.Wrap);
    }
}
