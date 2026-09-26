import OpenTUI

// The main column's bottom row (`Shell.state.statusRow`): the key hints for
// what has the keys, dim, on the left; the status glyph and message, in the
// status colour, on the right. The host cuts both to fit.
//
// Plugins contribute to the "statusbar" slot. In the default "replace" mode a
// contribution takes the place of the status message; "append" keeps it and
// adds contributions after it. The slot's data is `{ status, title }` (the
// open thread's title, or "").
Rectangle {
    id: line
    property alias slotMode: statusSlot.mode
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
        mode: "replace"
        flexShrink: 0
        flexDirection: "row"
        data: ({
            status: line.status,
            title: Shell.state.page.kind === "thread" ? Shell.state.page.title : ""
        })

        Text {
            objectName: "statusText"
            text: line.row.label
            color: line.row.kind === "success"
                ? Theme.colors.success
                : line.row.kind === "error"
                    ? Theme.colors.error
                    : line.row.kind === "busy" ? Theme.colors.accent : Theme.colors.faint
        }
    }
}
