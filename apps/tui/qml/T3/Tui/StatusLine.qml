import OpenTUI

// One line at the bottom: the host's status message and its tone.
//
// Plugins contribute to the "statusbar" slot. In the default "replace" mode a
// contribution takes the place of the status message; "append" keeps it and
// adds contributions after it. The slot's data is `{ status, title }` (the
// open thread's title, or "").
Rectangle {
    id: line
    property alias slotMode: statusSlot.mode
    readonly property var status: Shell.state.status
    readonly property string glyph: status.kind === "success"
        ? "✓"
        : status.kind === "error" ? "✗" : status.kind === "busy" ? "⟳" : "·"

    height: 1
    color: Theme.colors.bg
    flexDirection: "row"
    paddingX: 1

    Slot {
        id: statusSlot
        objectName: "statusbarSlot"
        name: "statusbar"
        mode: "replace"
        flexGrow: 1
        flexDirection: "row"
        data: ({
            status: line.status,
            title: Shell.state.page.kind === "thread" ? Shell.state.page.title : ""
        })

        Text {
            objectName: "statusGlyph"
            text: line.glyph + " "
            color: line.status.kind === "success"
                ? Theme.colors.success
                : line.status.kind === "error"
                    ? Theme.colors.error
                    : line.status.kind === "busy" ? Theme.colors.accent : Theme.colors.faint
        }
        Text {
            objectName: "statusText"
            text: line.status.text
            color: Theme.colors.dim
        }
    }
}
