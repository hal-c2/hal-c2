import QtQuick
import Ghostty
import HalC2.Shell

// One place's terminals (the drawer's, or the right panel's), drawn by
// qml-ghostty's Terminal from the `Terminals` controller's sessions: the
// shown split group's terminals side by side or stacked, as the web's
// terminal grid. Every other terminal of the place stays made, hidden, so
// switching groups keeps each screen and its scrollback.
//
//   TerminalSplits { anchors.fill: parent; panel: false; group: Terminals.activeGroup }
FocusScope {
    id: splits

    // The right panel's terminals rather than the drawer's.
    property bool panel: false
    // The group shown.
    property string group: ""
    property color background: Theme.palette.color("canvas", "#09090b")
    property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color border: Theme.palette.color("border", "#27272a")

    // The Terminal item of a terminal of this place, or null.
    function terminalOf(terminalId) {
        for (let i = 0; i < cells.count; ++i) {
            const cell = cells.itemAt(i);
            if (cell !== null && cell.item !== null && cell.terminalId === terminalId)
                return cell.item;
        }
        return null;
    }

    // The shown group's active terminal, or "".
    function currentTerminal() {
        for (let i = 0; i < cells.count; ++i) {
            const cell = cells.itemAt(i);
            if (cell !== null && cell.active && cell.shown && cell.current)
                return cell.terminalId;
        }
        return "";
    }

    Repeater {
        id: cells

        model: Terminals.tabs

        delegate: Loader {
            id: cell

            required property string terminalId
            required property string label
            required property QtObject session
            required property string group
            required property bool panel
            required property int slot
            required property int span
            required property bool vertical
            required property bool current

            readonly property bool shown: cell.group === splits.group

            objectName: "terminalCell-" + terminalId
            active: cell.panel === splits.panel
            visible: active && shown
            focus: shown && current
            x: vertical ? 0 : Math.round(splits.width * slot / span)
            y: vertical ? Math.round(splits.height * slot / span) : 0
            width: vertical ? splits.width : Math.round(splits.width * (slot + 1) / span) - x
            height: vertical ? Math.round(splits.height * (slot + 1) / span) - y : splits.height

            sourceComponent: Terminal {
                id: terminal

                readonly property string terminalId: cell.terminalId
                readonly property QtObject session: cell.session

                objectName: "HalC2Terminal"
                focus: true
                padding: 6
                font.family: Theme.fontTerminal.length > 0 ? Theme.fontTerminal : "monospace"
                font.pixelSize: Theme.fontSizeTerminal
                backgroundColor: splits.background
                foregroundColor: splits.foreground
                cursorColor: splits.foreground
                selectionColor: Qt.alpha(Theme.palette.color("accent", "#2563eb"), 0.35)

                onActiveFocusChanged: if (activeFocus)
                    Terminals.focusTerminal(cell.terminalId)
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

                // Right-click: the terminal's menu (TerminalMenu).
                // A handler, not a MouseArea, so wheel and left-button
                // selection still reach the Terminal.
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: eventPoint => menu.popup(eventPoint.position.x, eventPoint.position.y)
                }

                TerminalMenu {
                    id: menu

                    terminal: terminal
                    addToChat: (Shell.state.composer?.target ?? null) === null ? null : () => {
                        Shell.dispatch("composer.terminalContext.add", terminal.selectionContext());
                        terminal.clearSelection();
                        terminal.forceActiveFocus();
                    }
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
