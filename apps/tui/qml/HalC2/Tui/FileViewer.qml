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

    // A Markdown, table or HTML file reads as rendered lines (the host draws them); `s` shows its text.
    Item {
        objectName: "fileViewerRendered"
        visible: viewer.file !== null && viewer.file.message === "" && viewer.file.rendered !== null && !viewer.file.editing
        flexDirection: "column"
        flexGrow: 1
        flexShrink: 1
        flexBasis: 0
        overflow: "hidden"
        Repeater {
            model: viewer.file !== null && viewer.file.rendered !== null ? viewer.file.rendered : []
            delegate: Text { height: 1; flexShrink: 0; wrapMode: "none"; text: modelData }
        }
    }

    // The editor (`i`): what is typed is saved once the typing pauses, and on Esc.
    TextArea {
        id: editor
        objectName: "fileEditor"
        readonly property bool editing: viewer.file !== null && viewer.file.editing
        // Typing breaks a `text` binding, so the editor is filled each time it opens.
        readonly property int editSeq: viewer.file ? viewer.file.editSeq : 0
        onEditSeqChanged: if (viewer.file && viewer.file.editing) text = viewer.file.editText
        visible: editing
        onVisibleChanged: if (visible) forceActiveFocus()
        focus: editing
        flexGrow: 1
        flexShrink: 1
        flexBasis: 0
        wrapMode: "none"
        color: Theme.colors.text
        focusedColor: Theme.colors.text
        backgroundColor: Theme.colors.bg
        focusedBackgroundColor: Theme.colors.bg
        cursorColor: Theme.colors.accent
        onTextEdited: {
            Shell.dispatch("files.editor.set", { text: text })
            saveTimer.restart()
        }
    }

    Timer {
        id: saveTimer
        interval: 500
        onTriggered: Shell.dispatch("files.editor.save")
    }

    Code {
        objectName: "fileViewerCode"
        visible: viewer.file !== null && viewer.file.message === "" && viewer.file.rendered === null && !viewer.file.editing
        flexGrow: 1
        flexShrink: 1
        flexBasis: 0
        text: viewer.file ? viewer.file.text : ""
        filetype: viewer.file ? viewer.file.filetype : ""
        wrapMode: "none"
    }
}
