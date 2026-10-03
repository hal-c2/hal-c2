import OpenTUI

// A thread's changes (Shell.state.diff): all changes or one turn, one section
// per file with its language. Open in the host's "diff" mode: ↑/↓ change the
// scope, s switches split and stacked, PgUp/PgDn scroll, Esc closes.
Rectangle {
    id: viewer
    objectName: "diffViewer"
    readonly property var diff: Shell.state.diff
    // PgUp / PgDn (keymap `diff.scrollUp` / `diff.scrollDown`) scroll the body.
    readonly property var paneScroll: Shell.state.paneScroll
    onPaneScrollChanged: if (paneScroll.pane === "diff") body.scrollBy(paneScroll.by)

    visible: diff.open
    flexDirection: "column"
    flexGrow: 1
    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.accent
    paddingX: 1

    Item {
        flexDirection: "row"
        flexShrink: 0
        Text { objectName: "diffTitle"; flexShrink: 0; text: viewer.diff.title; color: Theme.colors.accent }
        Text { flexShrink: 1; text: viewer.diff.header; color: Theme.colors.dim; wrapMode: "none"; truncate: true }
    }
    Text {
        objectName: "diffMessage"
        visible: viewer.diff.message !== ""
        text: viewer.diff.message
        color: viewer.diff.status === "error" ? Theme.colors.error : Theme.colors.dim
    }
    ScrollView {
        id: body
        objectName: "diffScroll"
        visible: viewer.diff.message === ""
        flexGrow: 1
        flexShrink: 1
        flexBasis: 0

        Item {
            flexDirection: "column"
            flexShrink: 0
            Repeater {
                model: viewer.diff.files
                delegate: Item {
                    objectName: "diffFile-" + modelData.path
                    flexDirection: "column"
                    flexShrink: 0
                    marginBottom: 1
                    Item {
                        flexDirection: "row"
                        Text { text: modelData.path; font.bold: true }
                        Text { text: modelData.label; color: Theme.colors.dim }
                    }
                    Diff {
                        objectName: "diffBody-" + modelData.path
                        text: modelData.body
                        filetype: modelData.filetype
                        view: viewer.diff.view
                        showLineNumbers: true
                    }
                }
            }
        }
    }
}
