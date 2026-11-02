import QtQuick
import Ghostty
import HalC2.Shell

// Where a terminal's view sits in its history, drawn over its right padding and
// hidden while everything fits. Drag the thumb or click the track to move; Tab
// reaches it for Page Up, Page Down, Home, End and the arrows. A click leaves
// the keyboard with the terminal, so typing carries on.
//
//   TerminalScrollbar { terminal: screen; anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.right: parent.right }
Item {
    id: bar

    required property Terminal terminal

    readonly property real maxOffset: Math.max(0, terminal.scrollTotal - terminal.rows)
    readonly property real thumbHeight: Math.min(height, Math.max(18, height * terminal.rows / Math.max(1, terminal.scrollTotal)))
    readonly property real travel: Math.max(0, height - thumbHeight)
    // Where in the thumb the pointer holds it.
    property real grip: 0

    visible: maxOffset > 0
    width: 8
    activeFocusOnTab: true

    function scrollToPointer(y) {
        if (bar.travel > 0)
            bar.terminal.scrollTo(Math.max(0, Math.min(y - bar.grip, bar.travel)) / bar.travel * bar.maxOffset);
    }

    Keys.onPressed: event => {
        const screenful = Math.max(1, bar.terminal.rows);
        const deltas = new Map([[Qt.Key_Up, -1], [Qt.Key_Down, 1], [Qt.Key_PageUp, -screenful], [Qt.Key_PageDown, screenful], [Qt.Key_Home, -bar.terminal.scrollOffset], [Qt.Key_End, bar.maxOffset - bar.terminal.scrollOffset]]);
        if (deltas.has(event.key)) {
            bar.terminal.scrollLines(deltas.get(event.key));
            event.accepted = true;
        }
    }

    MouseArea {
        id: pointer

        anchors.fill: parent
        hoverEnabled: true
        onPressed: mouse => {
            const onThumb = mouse.y >= thumb.y && mouse.y < thumb.y + thumb.height;
            bar.grip = onThumb ? mouse.y - thumb.y : thumb.height / 2;
            bar.scrollToPointer(mouse.y);
        }
        onPositionChanged: mouse => {
            if (pressed)
                bar.scrollToPointer(mouse.y);
        }
    }

    Rectangle {
        id: thumb

        objectName: "terminalScrollbarThumb"
        anchors.right: parent.right
        anchors.rightMargin: 1
        y: bar.maxOffset > 0 ? bar.travel * Math.min(bar.terminal.scrollOffset, bar.maxOffset) / bar.maxOffset : 0
        width: 6
        height: bar.thumbHeight
        radius: 3
        color: Qt.alpha(Theme.palette.color("text", "#e4e4e7"), pointer.containsMouse || pointer.pressed || bar.activeFocus ? 0.5 : 0.25)
    }
}
