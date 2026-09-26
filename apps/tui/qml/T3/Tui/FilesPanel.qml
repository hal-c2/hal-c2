import OpenTUI

// The workspace file browser: the tree from `Shell.state.files`, folders
// first and collapsed until opened. The host keeps the listing, the
// selection and the window of rows that fits; this paints them.
Rectangle {
    id: panel
    objectName: "filesPanel"
    readonly property var files: Shell.state.files

    border.width: 1
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Row {
        height: 1
        Text {
            objectName: "filesHeader"
            flexShrink: 0
            text: "files · " + panel.files.cwd
            color: Theme.colors.accent
        }
        Text {
            flexShrink: 1
            truncate: true
            wrapMode: "none"
            text: "  ·  ↑/↓ select · Enter open/expand · ← up · Esc close"
            color: Theme.colors.dim
        }
    }

    Text {
        objectName: "filesMessage"
        visible: panel.files.message !== ""
        text: panel.files.message
        color: panel.files.status === "error" ? Theme.colors.error : Theme.colors.dim
    }

    Repeater {
        model: panel.files.rows
        delegate: Text {
            text: modelData.text
            truncate: true
            wrapMode: "none"
            color: modelData.selected
                ? Theme.colors.text
                : modelData.kind === "dir" ? Theme.colors.accent : Theme.colors.dim
            font.bold: modelData.selected
            onMouseDown: Shell.dispatch("files.select", { path: modelData.path })
        }
    }
}
