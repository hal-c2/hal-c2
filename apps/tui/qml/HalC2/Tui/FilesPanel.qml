import OpenTUI

// The workspace file browser (FilesView): in the conversation pane's place,
// the tree from `Shell.state.files`, folders first and collapsed until
// opened. The host keeps the listing, the selection, the window of rows that
// fits and each row's styled line; this paints them.
Rectangle {
    id: panel
    objectName: "filesPanel"
    readonly property var files: Shell.state.files

    visible: files.open && files.viewer === null
    flexDirection: "column"
    flexGrow: 1
    flexShrink: 1
    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    paddingX: 1

    Text {
        objectName: "filesHeader"
        flexShrink: 0
        wrapMode: "none"
        truncate: true
        text: panel.files.title
        color: Theme.colors.accent
        Span { text: panel.files.hint; color: Theme.colors.dim }
    }

    Text {
        objectName: "filesMessage"
        visible: panel.files.message !== ""
        text: panel.files.message
        color: panel.files.status === "error" ? Theme.colors.error : Theme.colors.dim
    }

    Repeater {
        model: panel.files.rows
        // The highlighted row's background spans the pane, as FilesView's does.
        delegate: Rectangle {
            flexShrink: 0
            height: 1
            color: modelData.selected ? Theme.colors.selectedBg : Theme.colors.bg
            onMouseDown: Shell.dispatch("files.select", { path: modelData.path })
            Text {
                wrapMode: "none"
                truncate: true
                text: modelData.line
            }
        }
    }
}
