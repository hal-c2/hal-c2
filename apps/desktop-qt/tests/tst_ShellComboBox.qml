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

    // The ghost picker has no border until the keyboard reaches it; a click
    // does not draw the ring.
    function test_ghostPickerShowsAFocusRingWhenTabbedTo() {
        Theme.colors = {
            focus: "#ff8800"
        };
        const combo = createTemporaryObject(comboComponent, testCase);
        compare(combo.background.border.width, 0);
        combo.forceActiveFocus(Qt.MouseFocusReason);
        compare(combo.background.border.width, 0);
        combo.focus = false;
        combo.forceActiveFocus(Qt.TabFocusReason);
        compare(combo.background.border.width, 1);
        compare(combo.background.border.color, "#ff8800");
    }

    // A bordered picker (Settings) keeps its border; only the keyboard rings it.
    function test_outlinePickerRingsOnlyForTheKeyboard() {
        Theme.colors = {
            focus: "#ff8800",
            input: "#333333"
        };
        const combo = createTemporaryObject(comboComponent, testCase, {
            outline: true
        });
        compare(combo.background.border.width, 1);
        compare(combo.background.border.color, "#333333");
        combo.forceActiveFocus(Qt.MouseFocusReason);
        compare(combo.background.border.color, "#333333");
        combo.focus = false;
        combo.forceActiveFocus(Qt.TabFocusReason);
        compare(combo.background.border.color, "#ff8800");
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
        // chosen row with only its check.
        compare(combo.highlightedIndex, 1);
        combo.forceActiveFocus();
        keyClick(Qt.Key_Down);
        const items = rows(combo);
        compare(items.length, 3);
        compare(items.map(row => row.Accessible.checked), [false, true, false]);
        compare(items.map(row => row.contentItem.children[1].visible), [false, true, false]);
        compare(items[1].background.color.a, 0);
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

    // Room for an empty popup below but not for its rows: it opens upward by
    // itself, not by Qt flipping it back inside the window (Ljós does not).
    function test_opensUpWhenItsRowsWouldPassTheWindow() {
        const combo = createTemporaryObject(comboComponent, testCase, {
            y: testCase.height - 80
        });
        openCombo(combo);
        verify(combo.popup.upward);
        verify(combo.popup.y < 0, "popup.y " + combo.popup.y);
    }

    // Each row's label is centred on the fill drawn behind it, and the row is
    // named by its label.
    function test_rowLabelsAreCentredAndNamed() {
        const combo = createTemporaryObject(comboComponent, testCase, {
            y: 20
        });
        openCombo(combo);
        const items = rows(combo);
        compare(items.map(row => row.Accessible.name), ["Low", "Medium", "High"]);
        for (const row of items) {
            const label = row.contentItem.children[0];
            const centre = label.mapToItem(row, 0, label.height / 2).y;
            fuzzyCompare(centre, row.background.height / 2, 1, "label centre " + centre);
        }
    }

    // A list longer than the popup's 320 ends on a whole row, not a sliced
    // one, with a fade at the bottom edge saying there is more (the diff's
    // turn picker stopped mid-"Turn 11").
    function test_aLongListEndsOnAWholeRowAndHintsAtMore() {
        const turns = [];
        for (let turn = 1; turn <= 30; ++turn)
            turns.push("Turn " + turn);
        const combo = createTemporaryObject(comboComponent, testCase, {
            y: 20,
            model: turns,
            currentIndex: 0
        });
        openCombo(combo);
        const popup = combo.popup;
        const list = popup.contentItem;
        verify(popup.height <= 320);
        compare((list.height) % Theme.control.md, 0);
        compare(popup.height, list.height + popup.topPadding + popup.bottomPadding);
        verify(findChild(list, "scrollEdgeBottom").visible);
        verify(!findChild(list, "scrollEdgeTop").visible);
        list.positionViewAtEnd();
        tryVerify(() => !findChild(list, "scrollEdgeBottom").visible);
        verify(findChild(list, "scrollEdgeTop").visible);
    }

    // A short list shows every row and no edge.
    function test_aShortListShowsNoEdge() {
        const combo = createTemporaryObject(comboComponent, testCase, {
            y: 20
        });
        openCombo(combo);
        const list = combo.popup.contentItem;
        compare(list.height, 3 * Theme.control.md);
        verify(!findChild(list, "scrollEdgeBottom").visible);
        verify(!findChild(list, "scrollEdgeTop").visible);
    }
}
