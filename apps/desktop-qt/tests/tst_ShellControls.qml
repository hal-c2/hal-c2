import QtQuick
import QtTest
import HalC2.Shell
import "../../../packages/qml/HalC2/Bricks"

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

    // As the plugins' settings use it: what is typed is set, and shown from there.
    Component {
        id: boundSpinComponent
        ShellSpinBox {
            id: bound

            property int saved: 0

            from: 0
            to: 999999999
            value: saved
            editable: true
            onValueTyped: typed => bound.saved = typed
        }
    }

    Component {
        id: spyComponent
        SignalSpy {}
    }

    Component {
        id: fieldComponent
        ShellTextField {}
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
        Theme.colors = Object.assign({}, dark, {
            inputSurface: "#112233"
        });
        compare(control.indicator.color, Qt.color("#112233"));
        compare(control.indicator.border.color, Qt.color(dark.input));
        control.checked = true;
        compare(control.indicator.color, Qt.color(dark.accent));
        compare(control.contentItem.color, Qt.color(dark.text));
    }

    function test_spinBoxIsThemedAndSteps() {
        const control = createTemporaryObject(spinComponent, testCase);
        Theme.colors = Object.assign({}, dark, {
            inputSurface: "#112233"
        });
        compare(control.background.color, Qt.color("#112233"));
        compare(control.contentItem.color, Qt.color(dark.text));
        control.increase();
        compare(control.value, 6);
    }

    function test_spinBoxFadesAStepperAtItsLimit() {
        const control = createTemporaryObject(spinComponent, testCase, {
            value: 10
        });
        compare(control.up.indicator.opacity, 0.4);
        compare(control.down.indicator.opacity, 1);
    }

    // A number typed in range is reported at once, before Return makes it the
    // value; what reads no number in range is not.
    function test_spinBoxReportsATypedNumberInRange() {
        const control = createTemporaryObject(spinComponent, testCase);
        const typed = createTemporaryObject(spyComponent, testCase, {
            target: control,
            signalName: "valueTyped"
        });
        control.contentItem.forceActiveFocus();
        control.contentItem.selectAll();
        keyClick(Qt.Key_Backspace);
        compare(typed.count, 0);
        keyClick(Qt.Key_7);
        compare(typed.count, 1);
        compare(typed.signalArguments[0][0], 7);
        compare(control.value, 5);
        keyClick(Qt.Key_Return);
        compare(control.value, 7);
    }

    // A long number typed into a box that shows what it set keeps every digit.
    function test_spinBoxTakesALongTypedNumber() {
        const control = createTemporaryObject(boundSpinComponent, testCase);
        control.contentItem.forceActiveFocus();
        control.contentItem.selectAll();
        for (const key of [Qt.Key_2, Qt.Key_0, Qt.Key_0, Qt.Key_0, Qt.Key_0])
            keyClick(key);
        compare(control.contentItem.text, "20000");
        compare(control.saved, 20000);
    }

    // An emptied box keeps the number it held when the keyboard leaves it or
    // Return is pressed, where the stock box falls to `from`: nothing is saved.
    function test_spinBoxKeepsItsValueWhenEmptied() {
        const control = createTemporaryObject(spinComponent, testCase, {
            from: 1,
            value: 7
        });
        const elsewhere = createTemporaryObject(fieldComponent, testCase, {
            y: 80
        });
        const modified = createTemporaryObject(spyComponent, testCase, {
            target: control,
            signalName: "valueModified"
        });
        control.contentItem.forceActiveFocus();
        control.contentItem.selectAll();
        keyClick(Qt.Key_Backspace);
        compare(control.contentItem.text, "");
        elsewhere.forceActiveFocus();
        compare(control.value, 7);
        compare(control.contentItem.text, "7");
        control.contentItem.forceActiveFocus();
        control.contentItem.selectAll();
        keyClick(Qt.Key_Minus);
        keyClick(Qt.Key_Return);
        compare(control.value, 7);
        compare(control.contentItem.text, "7");
        compare(modified.count, 0);
    }
}
