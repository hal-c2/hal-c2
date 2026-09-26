import OpenTUI

// A workspace file opened from the browser, syntax coloured by its filetype.
// The host keeps the scroll position and hands over the lines that fit.
Rectangle {
    id: viewer
    objectName: "fileViewer"
    readonly property var file: Shell.state.files.viewer

    border.width: 1
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Row {
        height: 1
        Text {
            objectName: "fileViewerHeader"
            flexShrink: 0
            text: "file · " + viewer.file.path
            color: Theme.colors.accent
        }
        Text {
            flexShrink: 1
            truncate: true
            wrapMode: "none"
            text: "  ·  ↑/↓ PgUp/PgDn scroll · Esc back"
            color: Theme.colors.dim
        }
    }

    Text {
        objectName: "fileViewerMessage"
        visible: viewer.file.message !== ""
        text: viewer.file.message
        color: viewer.file.status === "error" ? Theme.colors.error : Theme.colors.dim
    }

    Code {
        objectName: "fileViewerCode"
        visible: viewer.file.message === ""
        flexGrow: 1
        text: viewer.file.text
        filetype: viewer.file.filetype
        wrapMode: "none"
    }
}
