pragma ComponentBehavior: Bound

import QtQuick
import Ghostty
import HalC2.Shell
import "js/terminalLinks.js" as TerminalLinks

// One place's terminals (the drawer's, or the right panel's), drawn by
// qml-ghostty's Terminal from the `Terminals` controller's sessions: the
// shown split group's terminals side by side or stacked. Every other terminal of the place stays made, hidden, so
// switching groups keeps each screen and its scrollback.
//
//   TerminalSplits { anchors.fill: parent; panel: false; group: Terminals.activeGroup }
FocusScope {
    id: splits

    // A cell moved down by what is spare under its rows hangs over the bottom.
    clip: true

    // The right panel's terminals rather than the drawer's.
    property bool panel: false
    // The group shown.
    property string group: ""
    property color background: Theme.palette.color("canvas", "#09090b")
    property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color border: Theme.palette.color("border", "#27272a")

    // Prompt symbols for a machine with no Nerd Font: TerminalController makes
    // it the font Qt falls back to first, glyph by glyph, so cells keep the
    // terminal font's size.
    FontLoader {
        id: symbols

        source: "fonts/SymbolsNerdFontMono-Regular.woff2"
    }

    // What a bottom-anchored terminal leaves above its first row.
    Rectangle {
        anchors.fill: parent
        color: splits.background
    }

    // A terminal's cell: a row of Terminals.tabs, loaded when it is this place's.
    component TerminalCell: Loader {
        required property string terminalId
        required property string label
        required property QtObject session
        required property string group
        required property bool panel
        required property int slot
        required property int span
        required property bool vertical
        required property bool current

        // Its split group is the one shown.
        property bool shown: false
    }

    // The Terminal item of a terminal of this place, or null.
    function terminalOf(terminalId) {
        for (let i = 0; i < cells.count; ++i) {
            const cell = cells.itemAt(i) as TerminalCell;
            if (cell !== null && cell.item !== null && cell.terminalId === terminalId)
                return cell.item;
        }
        return null;
    }

    // The shown group's active terminal, or "".
    function currentTerminal() {
        for (let i = 0; i < cells.count; ++i) {
            const cell = cells.itemAt(i) as TerminalCell;
            if (cell !== null && cell.active && cell.shown && cell.current)
                return cell.terminalId;
        }
        return "";
    }

    Repeater {
        id: cells

        model: Terminals.tabs

        delegate: TerminalCell {
            id: cell

            shown: cell.group === splits.group
            objectName: "terminalCell-" + terminalId
            active: cell.panel === splits.panel
            visible: active && shown
            focus: shown && current
            x: vertical ? 0 : Math.round(splits.width * slot / span)
            y: slotY + (hasHistory ? spare : 0)

            readonly property real slotY: vertical ? Math.round(splits.height * slot / span) : 0
            readonly property real slotHeight: vertical ? Math.round(splits.height * (slot + 1) / span) - slotY : splits.height
            // What is left of the slot under a whole number of rows, in whole
            // pixels. It only moves the cell, which stays the slot's height: a
            // height read from the grid it sizes would be a binding loop.
            readonly property int spare: {
                const screen = cell.item as Terminal;
                if (screen === null || screen.cellHeight <= 0)
                    return 0;
                return Math.max(0, Math.floor((slotHeight - 2 * screen.padding) % screen.cellHeight));
            }
            // With history the prompt lives on the bottom row, so what is spare
            // goes above the first one.
            readonly property bool hasHistory: {
                const screen = cell.item as Terminal;
                return screen !== null && screen.scrollTotal > screen.rows;
            }

            // A place with no size (a closed drawer) leaves its terminals the
            // size they had: the shell and its screen are not shrunk to nothing.
            Binding on width {
                when: splits.width > 0 && splits.height > 0
                value: cell.vertical ? splits.width : Math.round(splits.width * (cell.slot + 1) / cell.span) - cell.x
                restoreMode: Binding.RestoreNone
            }
            Binding on height {
                when: splits.width > 0 && splits.height > 0
                value: cell.slotHeight
                restoreMode: Binding.RestoreNone
            }

            sourceComponent: Terminal {
                id: terminal

                readonly property string terminalId: cell.terminalId
                // A TerminalSession, which QML knows no type for.
                readonly property var session: cell.session

                // The platform whose keys apply (TerminalMenu).
                property string platform: Qt.platform.os

                objectName: "HalC2Terminal"
                // What the TapHandlers below do with a click on a link.
                Accessible.role: Accessible.Terminal
                Accessible.name: macModifiers ? qsTr("Terminal: Cmd-click a link to open it") : qsTr("Terminal: Ctrl-click a link to open it")
                // Qt calls macOS's Cmd Control and its Ctrl Meta; programs get the real keys.
                macModifiers: platform === "osx" || platform === "macos"
                cursorBlink: !Terminals.reduceMotion
                // Out of the window while hidden: output still reaches it and
                // its replies still go out, but a Terminal with no window
                // schedules no polish, so it paints nothing and wakes no frames.
                // Coming back into the window draws it in full.
                parent: cell.visible ? cell : null
                focus: true
                padding: 6
                // A whole font: the Terminal's default carries a point size,
                // which a pixel size set over it warns about.
                font: Qt.font({
                    family: Theme.fontTerminal.length > 0 ? Theme.fontTerminal : "monospace",
                    pixelSize: Theme.fontSizeTerminal
                })
                backgroundColor: splits.background
                foregroundColor: splits.foreground
                cursorColor: splits.foreground
                selectionColor: Qt.alpha(Theme.palette.color("accent", "#2563eb"), 0.35)

                onActiveFocusChanged: if (activeFocus)
                    Terminals.focusTerminal(cell.terminalId)
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Control) {
                        terminal.linkHeld = true;
                        terminal.hoverLink();
                    }
                    menu.keyPressed(event);
                }
                Keys.onReleased: event => {
                    if (event.key === Qt.Key_Control) {
                        terminal.linkHeld = false;
                        terminal.hoverLink();
                    }
                }
                onScrollOffsetChanged: if (terminal.hoveredLink !== null)
                    terminal.hoverLink()
                onInput: data => terminal.session.write(data)
                // Only a laid-out Terminal knows its grid; the first pass is 1x1.
                onResized: (columns, rows) => {
                    if (terminal.width > 0 && terminal.height > 0)
                        terminal.session.resize(columns, rows);
                }
                Component.onCompleted: {
                    terminal.restore(terminal.session.transcript());
                    if (terminal.width > 0 && terminal.height > 0)
                        terminal.session.resize(terminal.columns, terminal.rows);
                }

                Connections {
                    target: terminal.session
                    function onOutput(data) {
                        terminal.write(data);
                        if (terminal.hoveredLink !== null)
                            terminal.hoverLink();
                    }
                    function onReplaced(history) {
                        terminal.reset();
                        terminal.restore(history);
                    }
                }

                // The selection as the composer's terminal context
                // (composer.terminalContext.add): its lines are counted in the
                // terminal's text, scrollback and screen, at the selection's
                // last occurrence, since the Terminal does not say where it is.
                function selectionContext() {
                    const selected = terminal.selectedText().replace(/\r\n/g, "\n");
                    const all = terminal.text().replace(/\r\n/g, "\n");
                    const at = all.lastIndexOf(selected);
                    const leading = selected.length - selected.replace(/^\n+/, "").length;
                    const lineStart = (at < 0 ? 1 : all.slice(0, at).split("\n").length) + leading;
                    const body = selected.replace(/^\n+|\n+$/g, "");
                    return {
                        terminalId: cell.terminalId,
                        terminalLabel: cell.label,
                        lineStart: lineStart,
                        lineEnd: lineStart + body.split("\n").length - 1,
                        text: selected
                    };
                }

                // The web address or file path under a point, or null. One
                // the screen cuts off is not offered: it could not be read
                // before following it.
                function linkUnder(position) {
                    const column = Math.floor((position.x - terminal.padding) / terminal.cellWidth);
                    const row = Math.floor((position.y - terminal.padding) / terminal.cellHeight);
                    if (column < 0 || column >= terminal.columns || row < 0 || row >= terminal.rows)
                        return null;
                    const top = Math.round(terminal.scrollOffset);
                    const link = TerminalLinks.linkAt(terminal.text(), terminal.columns, top + row, column);
                    if (link === null)
                        return null;
                    const pieces = TerminalLinks.spans(link, terminal.columns);
                    return pieces[0].row < top || pieces[pieces.length - 1].row >= top + terminal.rows ? null : link;
                }

                // Ctrl (Cmd on macOS) is down, and the link it would follow
                // from where the pointer is. The text is only read while it
                // is down.
                property bool linkHeld: false
                property var hoveredLink: null
                function hoverLink() {
                    terminal.hoveredLink = terminal.linkHeld && linkHover.hovered ? terminal.linkUnder(linkHover.point.position) : null;
                }

                HoverHandler {
                    id: linkHover

                    cursorShape: terminal.hoveredLink !== null ? Qt.PointingHandCursor : undefined
                    onPointChanged: {
                        terminal.linkHeld = (linkHover.point.modifiers & Qt.ControlModifier) !== 0;
                        terminal.hoverLink();
                    }
                    onHoveredChanged: terminal.hoverLink()
                }

                // The hovered link's underline, on every row it is drawn on.
                Repeater {
                    model: terminal.hoveredLink !== null ? TerminalLinks.spans(terminal.hoveredLink, terminal.columns) : []

                    delegate: Rectangle {
                        required property var modelData

                        objectName: "terminalLinkUnderline"
                        x: terminal.padding + modelData.column * terminal.cellWidth
                        y: terminal.padding + (modelData.row - Math.round(terminal.scrollOffset) + 1) * terminal.cellHeight - 1
                        width: modelData.length * terminal.cellWidth
                        height: 1
                        color: splits.foreground
                    }
                }

                // Follows a link (terminal.followLink): the address in the
                // browser, the path in the editor, from the folder the shell
                // says it is in.
                function followLink(link) {
                    Shell.dispatch("terminal.followLink", {
                        terminalId: cell.terminalId,
                        kind: link.kind,
                        text: link.text,
                        cwd: terminal.workingDirectory
                    });
                }

                // A link is followed on a click with Ctrl held (Cmd on
                // macOS), as in other terminals, or a finger's tap: a plain
                // click only places the pointer, so selecting an address to
                // copy it never opens it. A drag still selects, and a program
                // that tracks the mouse keeps the clicks no modifier overrides.
                // Only the link that was pressed is followed: output may have
                // put another there since. `point` is only the press's after
                // `pressed` changes.
                TapHandler {
                    id: linkTap

                    property bool pressRead: false
                    property var pressedLink: null

                    acceptedButtons: Qt.LeftButton
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    acceptedModifiers: Qt.ControlModifier
                    onPressedChanged: if (!linkTap.pressed)
                        linkTap.pressRead = false
                    onPointChanged: {
                        if (!linkTap.pressed || linkTap.pressRead)
                            return;
                        linkTap.pressRead = true;
                        linkTap.pressedLink = terminal.linkUnder(linkTap.point.pressPosition);
                    }
                    onTapped: eventPoint => {
                        const link = terminal.linkUnder(eventPoint.pressPosition);
                        if (link !== null && linkTap.pressedLink !== null && link.text === linkTap.pressedLink.text)
                            terminal.followLink(link);
                    }
                }
                TapHandler {
                    acceptedDevices: PointerDevice.TouchScreen
                    onTapped: eventPoint => {
                        const link = terminal.mouseTracking ? null : terminal.linkUnder(eventPoint.position);
                        if (link !== null)
                            terminal.followLink(link);
                    }
                }

                // An engine that could not start draws nothing: the reason goes
                // in its place. Reopening makes a new Terminal, which tries again.
                Text {
                    objectName: "terminalEngineError"
                    anchors.fill: parent
                    anchors.margins: terminal.padding
                    visible: terminal.error.length > 0
                    text: qsTr("%1: close and reopen the terminal to retry.").arg(terminal.error)
                    color: splits.foreground
                    font: terminal.font
                    wrapMode: Text.Wrap
                }

                // Right-click: the terminal's menu (TerminalMenu), with the
                // link under the pointer unless a program has the mouse. A
                // handler, not a MouseArea, so wheel and left-button selection
                // still reach the Terminal.
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: eventPoint => {
                        menu.link = terminal.mouseTracking ? null : terminal.linkUnder(eventPoint.position);
                        menu.popup(eventPoint.position.x, eventPoint.position.y);
                    }
                }

                TerminalMenu {
                    id: menu

                    terminal: terminal
                    platform: terminal.platform
                    follow: link => terminal.followLink(link)
                    addToChat: (Shell.state.composer?.target ?? null) === null ? null : () => {
                        Shell.dispatch("composer.terminalContext.add", terminal.selectionContext());
                        terminal.clearSelection();
                        terminal.forceActiveFocus();
                    }
                }

                TerminalScrollbar {
                    objectName: "terminalScrollbar"
                    terminal: terminal
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: cell.hasHistory ? cell.spare : 0
                    anchors.right: parent.right
                }

                // The hairline between split terminals.
                Rectangle {
                    visible: cell.slot > 0
                    x: 0
                    y: 0
                    width: cell.vertical ? parent.width : 1
                    height: cell.vertical ? 1 : parent.height
                    color: splits.border
                }
            }
        }
    }
}
