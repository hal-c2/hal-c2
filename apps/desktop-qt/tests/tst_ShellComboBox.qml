import QtQuick
import QtQuick.Controls.Basic
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

TestCase {
    id: testCase
    name: "ShellComboBoxTests"
    width: 400
    height: 400
    when: windowShown

    Component {
        id: comboComponent
        ShellComboBox {
            width: 160
            model: ["Low", "Medium", "High"]
            currentIndex: 1
        }
    }

    function cleanup() {
        Theme.colors = {};
    }

    function rows(combo) {
        const list = combo.popup.contentItem;
        const out = [];
        for (let i = 0; i < list.count; ++i)
            out.push(list.itemAtIndex(i));
        return out;
    }

    function openCombo(combo) {
        combo.popup.open();
        tryVerify(() => combo.popup.visible && combo.popup.opacity === 1);
    }

    function test_currentRowIsMarked() {
        Theme.colors = {
            text: "#ff0000",
            accentSurface: "#0000ff"
        };
        const combo = createTemporaryObject(comboComponent, testCase, {
            y: 20
        });
        openCombo(combo);
        // The keyboard starts on the current value; moving off it leaves the
        // chosen row with its own quiet fill.
        compare(combo.highlightedIndex, 1);
        combo.forceActiveFocus();
        keyClick(Qt.Key_Down);
        const items = rows(combo);
        compare(items.length, 3);
        compare(items.map(row => row.Accessible.checked), [false, true, false]);
        compare(items.map(row => row.contentItem.children[1].visible), [false, true, false]);
        const fill = items[1].background.color;
        compare(fill.a.toFixed(2), "0.08");
        compare(items[0].background.color.a, 0);
    }

    function test_markCurrentCanBeSwitchedOff() {
        const combo = createTemporaryObject(comboComponent, testCase, {
            y: 20,
            markCurrent: false
        });
        openCombo(combo);
        compare(rows(combo).map(row => row.Accessible.checked), [false, false, false]);
    }

    function test_keyboardRowIsHighlightedAndDrawnAsHovered() {
        Theme.colors = {
            text: "#ff0000",
            accentSurface: "#0000ff"
        };
        const combo = createTemporaryObject(comboComponent, testCase, {
            y: 20
        });
        openCombo(combo);
        combo.forceActiveFocus();
        keyClick(Qt.Key_Down);
        compare(combo.highlightedIndex, 2);
        const items = rows(combo);
        compare(items.map(row => row.highlighted), [false, false, true]);
        compare(items[2].background.color, Qt.color("#0000ff"));
        verify(items[1].background.color !== Qt.color("#0000ff"));
    }

    function test_opensDownWhenThereIsRoom() {
        const combo = createTemporaryObject(comboComponent, testCase, {
            y: 20
        });
        openCombo(combo);
        verify(combo.popup.y > 0);
    }

    function test_opensUpWhenTheWindowEndsBelowTheCombo() {
        const combo = createTemporaryObject(comboComponent, testCase, {
            y: testCase.height - 30
        });
        openCombo(combo);
        verify(combo.popup.y < 0, "popup.y " + combo.popup.y);
        const bottom = combo.mapToItem(null, 0, combo.popup.y + combo.popup.height).y;
        verify(bottom <= combo.mapToItem(null, 0, 0).y);
    }
}
