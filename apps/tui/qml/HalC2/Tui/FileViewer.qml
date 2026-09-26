import OpenTUI

// A workspace file opened from the browser (FilesView), syntax coloured by its
// filetype, in the conversation pane's place. The host keeps the scroll
// position and hands over the lines that fit.
Rectangle {
    id: viewer
    objectName: "fileViewer"
    readonly property var files: Shell.state.files
    readonly property var file: files.viewer

    visible: files.open && file !== null
    flexDirection: "column"
    flexGrow: 1
    flexShrink: 1
    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    paddingX: 1

    Text {
        objectName: "fileViewerHeader"
        flexShrink: 0
        wrapMode: "none"
        truncate: true
        text: viewer.files.title
        color: Theme.colors.accent
        Span { text: viewer.files.hint; color: Theme.colors.dim }
    }

    Text {
        objectName: "fileViewerMessage"
        visible: viewer.file !== null && viewer.file.message !== ""
        text: viewer.file ? viewer.file.message : ""
        color: viewer.file && viewer.file.status === "error" ? Theme.colors.error : Theme.colors.dim
    }

    Code {
        objectName: "fileViewerCode"
        visible: viewer.file !== null && viewer.file.message === ""
        flexGrow: 1
        flexShrink: 1
        flexBasis: 0
        text: viewer.file ? viewer.file.text : ""
        filetype: viewer.file ? viewer.file.filetype : ""
        wrapMode: "none"
    }
}
