import QtQuick

// Stands in for mobile-qt's C++ TerminalEvents (MobileTerminal.h), so
// TerminalScreen loads (#1624). The C++ sends a Terminal item the key,
// wheel and mouse events its own encoders read, so a key the screen
// draws goes out as the program in the shell asked keys to, and a
// finger scrolls and selects as a mouse would. Ljós has no way for an
// app to synthesize an event into an item yet (hal-c2/ljos-ui#622; the
// port is H1, #1659), so this stub only covers what its one caller
// (TerminalScreen's key row and finger area) needs to be usable:
// the key row's keys are written to the terminal's session in their
// usual encodings — which misses application cursor mode, why the C++
// sends real events — and a finger's scroll moves by whole lines.
// A finger's selection (`mouse`) does nothing until the real type lands.
QtObject {
    // The key row's keys, as a terminal in its ordinary mode sends them.
    function key(item, which, modifiers) {
        if (!item || !item.session)
            return;
        const plain = ({
            [Qt.Key_Escape]: "\x1b",
            [Qt.Key_Tab]: "\t",
            [Qt.Key_Up]: "\x1b[A",
            [Qt.Key_Down]: "\x1b[B",
            [Qt.Key_Left]: "\x1b[D",
            [Qt.Key_Right]: "\x1b[C"
        })[which];
        if (plain !== undefined)
            item.session.write(plain);
    }

    // The part of a line a slow drag has moved `restOf` by so far, kept
    // until it makes a whole one. Another terminal starts from none.
    property real rest: 0
    property var restOf: null

    // `pixels` as a wheel has them: positive scrolls towards older
    // output. Whole lines only, where a wheel reaches the Terminal's
    // own counting of them; what is left over carries to the next.
    function wheel(item, pixels) {
        if (!item || !item.scrollLines)
            return;
        if (item !== restOf) {
            restOf = item;
            rest = 0;
        }
        rest += pixels;
        const lines = Math.trunc(rest / 15);
        rest -= lines * 15;
        if (lines !== 0)
            item.scrollLines(-lines);
    }

    // The left button, in the item's coordinates: "press", "move" or
    // "release". Nothing until the real type can send the Terminal a
    // mouse event of its own (see above).
    function mouse(item, what, x, y, modifiers) {}
}
