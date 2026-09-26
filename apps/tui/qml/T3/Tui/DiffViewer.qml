import OpenTUI

// The checkpoint diff viewer (`Shell.state.diff`) in place of the
// conversation: one Diff per file so each gets its language's highlighting.
// ↑/↓ step through all changes and each turn, `s` switches stacked ⇄ split,
// PgUp/PgDn scroll (`scroll`), Esc closes.
Rectangle {
    id: viewer
    objectName: "diffViewer"
    readonly property var diff: Shell.state.diff

    function scroll(rows) { body.scrollBy({ x: 0, y: rows }) }

    border.width: 1
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Item {
        flexDirection: "row"
        height: 1
        Text { objectName: "diffScope"; text: "diff · " + viewer.diff.scopeLabel; color: Theme.colors.accent }
        Text {
            text: "  " + viewer.diff.files.length + (viewer.diff.files.length === 1 ? " file" : " files")
                + " · " + viewer.diff.view + " · ↑/↓ view · s "
                + (viewer.diff.view === "unified" ? "split" : "stacked") + " · PgUp/PgDn scroll · Esc close"
            color: Theme.colors.dim
        }
    }
    Text {
        objectName: "diffMessage"
        visible: viewer.diff.status !== "ready"
        text: viewer.diff.status === "loading"
            ? "loading…"
            : viewer.diff.status === "error" ? "failed to load diff" : "no changes in this turn"
        color: viewer.diff.status === "error" ? Theme.colors.error : Theme.colors.dim
    }
    ScrollView {
        id: body
        objectName: "diffBody"
        visible: viewer.diff.status === "ready"
        flexGrow: 1
        Repeater {
            model: viewer.diff.files
            delegate: Item {
                flexDirection: "column"
                flexShrink: 0
                marginBottom: 1
                Item {
                    flexDirection: "row"
                    height: 1
                    Text { text: modelData.path; color: Theme.colors.text; font.bold: true }
                    Text {
                        visible: modelData.filetype.length > 0
                        text: "  · " + modelData.filetype
                        color: Theme.colors.dim
                    }
                }
                Diff {
                    objectName: "diffFile"
                    text: modelData.body
                    filetype: modelData.filetype
                    view: viewer.diff.view
                    showLineNumbers: true
                }
            }
        }
    }
}
