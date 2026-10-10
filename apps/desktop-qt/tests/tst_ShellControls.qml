import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

TestCase {
    id: testCase
    name: "ShellControlsTests"
    width: 400
    height: 200
    when: windowShown

    // A dark theme: the stock Basic controls would stay light on it.
    readonly property var dark: ({
            canvas: "#0a0a0a",
            text: "#e4e4e7",
            accent: "#3b82f6",
            accentForeground: "#ffffff",
            accentSurface: "#27272a",
            input: "#2a2a2a",
            focus: "#60a5fa"
        })

    Component {
        id: switchComponent
        ShellSwitch {}
    }

    Component {
        id: checkComponent
        ShellCheckBox {
            text: qsTr("Option")
        }
    }

    Component {
        id: spinComponent
        ShellSpinBox {
            from: 0
            to: 10
            value: 5
            editable: true
        }
    }

    function init() {
        Theme.appearance = "dark";
        Theme.colors = dark;
    }

    function cleanup() {
        Theme.colors = {};
    }

    function test_switchTrackIsAccentOnAndInputOff() {
        const control = createTemporaryObject(switchComponent, testCase);
        compare(control.indicator.color, Qt.color(dark.input));
        control.checked = true;
        compare(control.indicator.color, Qt.color(dark.accent));
    }

    function test_switchThumbMovesToTheEndAndIsCanvas() {
        const control = createTemporaryObject(switchComponent, testCase);
        const thumb = control.indicator.children[0];
        compare(thumb.color, Qt.color(dark.canvas));
        verify(thumb.x + thumb.width / 2 < control.indicator.width / 2);
        control.checked = true;
        tryVerify(() => thumb.x + thumb.width / 2 > control.indicator.width / 2);
    }

    function test_switchFollowsTheTheme() {
        const control = createTemporaryObject(switchComponent, testCase);
        Theme.colors = Object.assign({}, dark, {
            input: "#112233"
        });
        compare(control.indicator.color, Qt.color("#112233"));
    }

    function test_checkBoxMarksFollowTheTheme() {
        const control = createTemporaryObject(checkComponent, testCase);
        compare(control.indicator.color, Qt.color(dark.canvas));
        compare(control.indicator.border.color, Qt.color(dark.input));
        control.checked = true;
        compare(control.indicator.color, Qt.color(dark.accent));
        compare(control.contentItem.color, Qt.color(dark.text));
    }

    function test_spinBoxIsThemedAndSteps() {
        const control = createTemporaryObject(spinComponent, testCase);
        const fill = control.background.color;
        compare(fill.a.toFixed(2), "0.32");
        compare(control.contentItem.color, Qt.color(dark.text));
        control.increase();
        compare(control.value, 6);
        Theme.appearance = "light";
        compare(control.background.color, Qt.color(dark.canvas));
    }

    function test_spinBoxFadesAStepperAtItsLimit() {
        const control = createTemporaryObject(spinComponent, testCase, {
            value: 10
        });
        compare(control.up.indicator.opacity, 0.4);
        compare(control.down.indicator.opacity, 1);
    }
}
