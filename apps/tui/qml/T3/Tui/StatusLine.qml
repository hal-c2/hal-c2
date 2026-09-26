import OpenTUI

// One line at the bottom: the host's status message and its tone.
Rectangle {
    id: line
    readonly property var status: Shell.state.status
    readonly property string glyph: status.kind === "success"
        ? "✓"
        : status.kind === "error" ? "✗" : status.kind === "busy" ? "⟳" : "·"

    height: 1
    color: Theme.colors.bg
    flexDirection: "row"
    paddingX: 1

    Text {
        text: line.glyph + " "
        color: line.status.kind === "success"
            ? Theme.colors.success
            : line.status.kind === "error"
                ? Theme.colors.error
                : line.status.kind === "busy" ? Theme.colors.accent : Theme.colors.faint
    }
    Text {
        objectName: "statusText"
        flexGrow: 1
        text: line.status.text
        color: Theme.colors.dim
    }
}
