import OpenTUI

// The main column's bottom row (`Shell.state.statusRow`): the key hints for
// what has the keys, dim, on the left; the status glyph and message, in the
// status colour, on the right. The host cuts both to fit.
//
// Plugins contribute to the "statusbar" slot. In the default "replace" mode a
// contribution takes the place of the status message; "append" keeps it and
// adds contributions after it. The slot's data is `{ status, title }` (the
// open thread's title, or "").
//
// An error stays on the line until the user dismisses it (click it, or "Dismiss
// the status error" in the palette), so a "replace" contribution gives way to
// it and the status shows after it. A message that came after the error shows
// beside it (`row.pinned`, then `row.label`).
Rectangle {
    id: line
    // The mode the shell asks of the slot; an unacknowledged error turns "replace" into "append".
    property string slotMode: "replace"
    readonly property var row: Shell.state.statusRow
    readonly property var status: Shell.state.status

    height: 1
    flexShrink: 0
    color: Theme.colors.bg
    flexDirection: "row"
    justifyContent: "space-between"
    overflow: "hidden"
    paddingX: 1

    Text {
        objectName: "statusHint"
        flexShrink: 1
        text: line.row.hint
        color: Theme.colors.dim
    }
    Slot {
        id: statusSlot
        objectName: "statusbarSlot"
        name: "statusbar"
        mode: line.row.errorPinned && line.slotMode === "replace" ? "append" : line.slotMode
        flexShrink: 0
        flexDirection: "row"
        data: ({
            status: line.status,
            title: Shell.state.page.kind === "thread" ? Shell.state.page.title : ""
        })

        Text {
            objectName: "statusPinned"
            visible: line.row.pinned !== ""
            text: line.row.pinned
            color: Theme.colors.error
            onMouseDown: Shell.dispatch("status.dismiss")
        }
        Text {
            objectName: "statusText"
            // Only the error itself dismisses; a message beside a pinned one is just a message.
            onMouseDown: {
                if (line.row.kind === "error")
                    Shell.dispatch("status.dismiss")
            }
            text: line.row.label
            color: line.row.kind === "success"
                ? Theme.colors.success
                : line.row.kind === "error"
                    ? Theme.colors.error
                    : line.row.kind === "warning"
                        ? Theme.colors.warning
                        : line.row.kind === "busy" ? Theme.colors.accent : Theme.colors.faint
        }
    }
}
